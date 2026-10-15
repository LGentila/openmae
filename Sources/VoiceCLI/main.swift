// voice-cli — measures the voice engine without any user interface, and manages its models.
//
//   voice-cli conversation [options] <phrase.wav>...    one turn per recording; latency of each stage
//   voice-cli interruption [options] <question.wav> <interruption.wav>
//                                                       talks over the assistant; time to silence it
//   voice-cli endurance --minutes N [options] <phrase.wav>...
//                                                       loops a conversation; memory after every turn
//   voice-cli voice-onset [--voices a,b] [--temperatures 0.7,0.5] [--repeats 3]
//                                                       silence the voice produces before speaking
// Options:
//   --llm <repo-or-folder>   language model (default: the one chosen for this Mac's tier)
//   --tts gpu|cpu            where the voice runs (default gpu)
//   --no-speculative         disable speculative start (for comparison)
//   --silence-ms <n>         end-of-turn silence (default 500)
//   --history-budget <n>     history size in tokens before the oldest exchanges are dropped
//   --out <folder>           where reports and audio go (default ./measurements)
//
// The recordings are played into the engine in real time, as a microphone would, and the assistant's
// voice is "played" in real time by a silent simulated speaker, so timings match the real app
// (minus the ~10–20 ms of the audio device itself).

import FluidAudio
import Foundation
import VoiceCore
import VoiceEngineApple

struct Options {
    var command = ""
    var llm: String?
    var ttsOnCPU = false
    var speculative = true
    var silenceMs = 500.0
    var minutes = 10.0
    var historyBudget: Int?
    var voices = ["estelle"]
    var temperatures: [Float] = [0.7]
    var repeats = 3
    var out = URL(fileURLWithPath: "measurements")
    var files: [URL] = []

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        guard let command = it.next() else { return nil }
        o.command = command
        while let a = it.next() {
            switch a {
            case "--llm": o.llm = it.next()
            case "--tts": o.ttsOnCPU = it.next() == "cpu"
            case "--no-speculative": o.speculative = false
            case "--silence-ms": o.silenceMs = Double(it.next() ?? "") ?? o.silenceMs
            case "--minutes": o.minutes = Double(it.next() ?? "") ?? o.minutes
            case "--history-budget": o.historyBudget = Int(it.next() ?? "")
            case "--out": o.out = URL(fileURLWithPath: it.next() ?? "measurements")
            case "--voices": o.voices = (it.next() ?? "").split(separator: ",").map(String.init)
            case "--temperatures": o.temperatures = (it.next() ?? "").split(separator: ",").compactMap { Float($0) }
            case "--repeats": o.repeats = Int(it.next() ?? "") ?? o.repeats
            default: o.files.append(URL(fileURLWithPath: a))
            }
        }
        return o
    }
}

/// Collects what the pipeline reports.
actor EventLog {
    var diagnostics: MLXChatModel?
    func attach(_ model: MLXChatModel) { diagnostics = model }
    var turns: [TurnMetrics] = []
    var bargeIns: [(stopMs: Double, detectionMs: Double)] = []
    var state = PipelineState.listening
    var failures: [String] = []

    func record(_ event: PipelineEvent) async {
        switch event {
        case .state(let s):
            state = s
            if s == .speaking, let model = diagnostics {
                let p = await model.lastPrefill
                print("  · model: \(p.reused) tokens reused, \(p.computed) computed in \(fmt(p.ms))")
            }
        case .userTranscript(let text, let language):
            print("  🗣  [\(language.rawValue)] \(text)")
        case .assistantPiece(let piece):
            print("  🔊 \(piece)")
        case .turnFinished(let m):
            turns.append(m)
            if m.interrupted {
                print("  ✋ interrupted after: “\(m.assistantText)”")
            } else {
                print("  ⏱  end of speech → first sound: \(fmt(m.latencyMs))"
                      + "  [silence \(fmt(m.endOfTurnMs)) · transcription \(fmt(m.transcriptionMs))"
                      + " · first word \(fmt(m.firstTokenMs)) · first piece \(fmt(m.firstPieceMs))"
                      + " · voice \(fmt(m.synthesisFirstAudioMs))]"
                      + (m.speculative ? " (prepared speculatively)" : ""))
            }
        case .bargeIn(let stopMs, let detectionMs):
            bargeIns.append((stopMs, detectionMs))
            print("  ✋ interruption: voice cut \(fmt(stopMs)) after the start of speech"
                  + " (detection: \(fmt(detectionMs)))")
        case .failure(let message):
            failures.append(message)
            print("  ⚠️  \(message)")
        }
    }

    var completedTurns: Int { turns.filter { !$0.interrupted }.count }
}

func fmt(_ ms: Double?) -> String { ms.map { String(format: "%.0f ms", $0) } ?? "—" }

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: - Engine

struct Engine {
    let pipeline: VoicePipeline
    let speaker: SimulatedSpeaker
    let log: EventLog
    let model: MLXChatModel
}

func buildEngine(_ o: Options) async throws -> Engine {
    let hw = HardwareProfile.current
    let tier = HardwareTier.recommended(for: hw)
    print("Mac: \(hw.chipName), \(Int(hw.memoryGiB.rounded())) GB → tier “\(tier.rawValue)”"
          + (tier.isTested ? "" : " (UNTESTED)"))
    guard let llmURL = ModelLocator.languageModel(o.llm) else { throw CLIError("language model not found") }
    guard let vadURL = ModelLocator.voiceActivity() else { throw CLIError("silero_vad.mlmodelc not found") }

    let clock = ContinuousClock()
    var t = clock.now
    let detector = try SileroSpeechDetector(modelURL: vadURL)
    let transcriber = try await ParakeetTranscriber.load()
    print("loaded: voice detection + transcription in \(clock.now - t)")
    t = clock.now
    let model = try await MLXChatModel.load(directory: llmURL)
    print("loaded: \(llmURL.path.components(separatedBy: "models--").last ?? llmURL.lastPathComponent) in \(clock.now - t)")
    t = clock.now
    let synthesizer = PocketSpeechSynthesizer(computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine)
    try await synthesizer.preload([.french, .english])
    print("loaded: voice (\(o.ttsOnCPU ? "CPU" : "GPU")) in \(clock.now - t)")

    var config = PipelineConfig()
    config.speculativeStart = o.speculative
    config.turn.endOfTurnSilenceMs = o.silenceMs
    if let budget = o.historyBudget {
        config.historyTokenBudget = budget
        config.historyTrimTarget = budget * 2 / 3
    }
    let speaker = SimulatedSpeaker()
    let pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model,
                                 synthesizer: synthesizer, output: speaker, config: config)
    let log = EventLog()
    await log.attach(model)
    Task { for await event in pipeline.events { await log.record(event) } }
    try await pipeline.start()
    print(String(format: "memory after loading: %.2f GB\n", ProcessMemory.footprintGB))
    return Engine(pipeline: pipeline, speaker: speaker, log: log, model: model)
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Commands

func waitForAnswer(_ e: Engine, mic: SimulatedMicrophone, after count: Int) async {
    await mic.silence(until: {
        let done = await e.log.completedTurns > count
        let idle = await e.log.state == .listening
        return done && idle
    }, timeout: 60)
}

func runConversation(_ o: Options, _ e: Engine) async throws {
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    for (i, file) in o.files.enumerated() {
        print("■ turn \(i + 1) — \(file.lastPathComponent)")
        let before = await e.log.completedTurns
        await mic.say(try WAV.read16kMono(file))
        await waitForAnswer(e, mic: mic, after: before)
        await mic.silence(0.5)
        let audio = await e.speaker.takeRecording()
        try WAV.write(audio, sampleRate: await e.speaker.sampleRate,
                      to: o.out.appendingPathComponent("answer-\(i + 1).wav"))
    }
    let turns = await e.log.turns.filter { !$0.interrupted }
    let latencies = turns.compactMap(\.latencyMs)
    print("\n=== Summary: \(turns.count) turns ===")
    print("end of speech → first sound: median \(fmt(median(latencies)))"
          + "  min \(fmt(latencies.min()))  max \(fmt(latencies.max()))")
    for (label, values) in [("waiting for silence", turns.compactMap(\.endOfTurnMs)),
                            ("transcription", turns.compactMap(\.transcriptionMs)),
                            ("model's first word", turns.compactMap(\.firstTokenMs)),
                            ("first piece of text", turns.compactMap(\.firstPieceMs)),
                            ("voice's first sound", turns.compactMap(\.synthesisFirstAudioMs))]
    {
        print("  \(label): median \(fmt(median(values)))")
    }
    print(String(format: "memory: %.2f GB · cache rebuilds: %d",
                 ProcessMemory.footprintGB, await e.model.cacheRebuilds))
    try save(turns, name: "conversation", options: o)
}

func runInterruption(_ o: Options, _ e: Engine) async throws {
    guard o.files.count == 2 else { throw CLIError("interruption expects 2 files: question, interruption") }
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    let question = try WAV.read16kMono(o.files[0])
    let interruption = try WAV.read16kMono(o.files[1])
    for round in 1...3 {
        print("■ attempt \(round)")
        let before = await e.log.completedTurns
        await mic.say(question)
        await mic.silence(until: { await e.log.state == .speaking }, timeout: 30)
        await mic.silence(1.5)  // let the assistant talk for a moment
        await mic.say(interruption)
        await waitForAnswer(e, mic: mic, after: before)
        await mic.silence(0.5)
        _ = await e.speaker.takeRecording()
    }
    let stops = await e.log.bargeIns.map(\.stopMs)
    print("\n=== Summary: \(stops.count) interruptions ===")
    print("voice cut after the start of speech: median \(fmt(median(stops)))  max \(fmt(stops.max()))")
    try save(await e.log.turns, name: "interruption", options: o)
}

func runEndurance(_ o: Options, _ e: Engine) async throws {
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    let phrases = try o.files.map(WAV.read16kMono)
    let clock = ContinuousClock()
    let end = clock.now + .seconds(o.minutes * 60)
    var samples: [(minute: Double, gb: Double)] = []
    let start = clock.now
    var i = 0
    print("turn;minute;memory_GB;latency_ms")
    while clock.now < end {
        let before = await e.log.completedTurns
        await mic.say(phrases[i % phrases.count])
        await waitForAnswer(e, mic: mic, after: before)
        await mic.silence(0.5)
        _ = await e.speaker.takeRecording()
        let minute = Double((clock.now - start).components.seconds) / 60
        let gb = ProcessMemory.footprintGB
        samples.append((minute, gb))
        print(String(format: "%d;%.1f;%.3f;%@", i + 1, minute, gb, fmt(await e.log.turns.last?.latencyMs)))
        i += 1
    }
    if let first = samples.first, let last = samples.last {
        print(String(format: "\n=== %d turns in %.0f min · memory %.2f → %.2f GB ===",
                     samples.count, last.minute, first.gb, last.gb))
    }
    try save(await e.log.turns, name: "endurance", options: o)
}

func save(_ turns: [TurnMetrics], name: String, options: Options) throws {
    try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = options.out.appendingPathComponent("\(name)-\(stamp).json")
    try encoder.encode(turns).write(to: url)
    print("report: \(url.path)")
}

/// Pocket TTS often opens with near-silence before the first word (seen in the app: up to 2 s). This
/// measures it per voice and temperature, on typical first sentences, without the language model.
func runVoiceOnset(_ o: Options) async throws {
    let sentences = [
        "Le ciel est bleu à cause de la lumière.", "Bonjour, je vais t'aider avec plaisir.",
        "Tu pourrais faire une randonnée en forêt.", "Oui, ça marche parfaitement sans four.",
        "Tu voulais cuisiner des courgettes ce soir.",
    ]
    let manager = PocketTtsManager(defaultVoice: o.voices[0], language: .french24L, directory: nil,
                                   computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine)
    try await manager.initialize()
    let clock = ContinuousClock()
    print("voice;temperature;leading_silence_median_ms;leading_silence_max_ms;first_audible_median_ms;mute")
    for voice in o.voices {
        _ = try await speak("Bonjour.", manager: manager, voice: voice, temperature: 0.7, clock: clock)  // load + warm up
        for temperature in o.temperatures {
            var silences: [Double] = []
            var firstAudible: [Double] = []
            var mute = 0
            for _ in 0..<o.repeats {
                for sentence in sentences {
                    let r = try await speak(sentence, manager: manager, voice: voice, temperature: temperature,
                                            clock: clock)
                    silences.append(r.leadingMs)
                    if let audible = r.firstAudibleMs { firstAudible.append(audible) } else { mute += 1 }
                }
            }
            print("\(voice);\(temperature);\(fmt(median(silences)));\(fmt(silences.max()));"
                  + "\(fmt(median(firstAudible)));\(mute)")
        }
    }
}

func speak(_ text: String, manager: PocketTtsManager, voice: String, temperature: Float, clock: ContinuousClock)
    async throws -> (leadingMs: Double, firstAudibleMs: Double?)
{
    let start = clock.now
    let session = try await manager.makeSession(voice: voice, temperature: temperature)
    session.enqueue(text)
    session.finish()
    var leading = 0
    var firstAudible: Double?
    for try await frame in session.frames where firstAudible == nil {
        let meanSquare = frame.samples.reduce(0) { $0 + $1 * $1 } / Float(max(frame.samples.count, 1))
        if 10 * log10(max(meanSquare, 1e-12)) < -45 {
            leading += frame.samples.count
        } else {
            let d = clock.now - start
            firstAudible = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
    }
    return (Double(leading) / 24, firstAudible)
}

// MARK: - Entry point

if let options = Options.parse(CommandLine.arguments), options.command == "voice-onset" {
    do { try await runVoiceOnset(options) } catch { print("ERROR: \(error)") }
    exit(0)
}
guard let options = Options.parse(CommandLine.arguments), !options.files.isEmpty else {
    print("""
        usage: voice-cli conversation|interruption|endurance [--llm <repository|folder>] [--tts gpu|cpu]
                         [--no-speculative] [--silence-ms 500] [--minutes 10] [--out folder] files.wav…
               voice-cli voice-onset [--voices a,b] [--temperatures 0.7,0.5] [--repeats 3]
        """)
    exit(2)
}
do {
    let engine = try await buildEngine(options)
    switch options.command {
    case "conversation": try await runConversation(options, engine)
    case "interruption": try await runInterruption(options, engine)
    case "endurance": try await runEndurance(options, engine)
    default: throw CLIError("unknown command: \(options.command)")
    }
} catch {
    print("ERROR: \(error)")
    exit(1)
}
