// voice-cli — measures the voice engine without any user interface, and manages its models.
//
//   voice-cli conversation [options] <phrase.wav>...    one turn per recording; latency of each stage
//   voice-cli interruption [options] <question.wav> <interruption.wav>
//                                                       talks over the assistant; time to silence it
//   voice-cli endurance --minutes N [--new-conversation-every N] [options] <phrase.wav>...
//                                                       loops a conversation; memory after every turn
//   voice-cli voice-onset [--voices a,b] [--temperatures 0.7,0.5] [--repeats 3] [--parallel 1] [--with-llm]
//                                                       silence the voice produces before speaking
//   voice-cli actions-bench [--now 2026-10-15T18:42] [--corpus file.json] [--web] [--searxng <address>]
//                                                       does the model pick the right action, or search? (text
//                                                       only, nothing carried out; see ActionsBench.swift)
//   voice-cli dialogue-bench [--repeats 10] [--corpus file.json]
//                                                       the model in short conversations, turn after turn, as the
//                                                       app has them (text only; see DialogueBench.swift)
//   voice-cli cache-check [--scenario name] [--agents]  how much of each request the model finds in its memory,
//                                                       in the app's sequences of requests (text only; see
//                                                       CacheCheck.swift)
//   voice-cli delegate --instruction "…"               hands a task to Claude Code as the app does (no model;
//                                                       see Delegate.swift)
//   voice-cli web-search --searxng <address> keywords…  one search as the app makes it (see WebSearch.swift)
//   voice-cli download | verify | catalog               the models (see ModelCommands.swift)
//   voice-cli link-client [--pair "<link>"] [--relay-only | --direct-only] <phrase.wav>...
//                                                       a fake iPhone: latency through the link (LinkClient.swift)
//   voice-cli inbound --relay <home relay> [--name Essai] [--seconds 600]
//                                                       received information through a home relay, printed instead
//                                                       of said (no model; see InboundListen.swift)
// Options:
//   --tier <name>            minimum, standard, comfort or max (default: this Mac's tier)
//   --llm <folder>           another language model folder (default: the tier's)
//   --tts gpu|cpu            where the voice runs (default gpu)
//   --no-speculative         disable speculative start (for comparison)
//   --silence-ms <n>         end-of-turn silence (default 500)
//   --history-budget <n>     history size in tokens before the oldest exchanges are dropped
//   --actions                the actions in the model's instructions, as in the app (none is carried out)
//   --racing-voices <n>      voices starting each answer at once, the first audible one says it (default 1)
//   --no-voice-restart       never start the voice again after a long near-silent opening (the app does, after 1.2 s)
//   --voice-restart-after <s> seconds of near-silent opening before the voice starts again (default 1.2)
//   --wake-word              only sentences that start with « OK Maé » are answered, as in the app's wake-word mode
//   --follow-up <s>          with --wake-word: seconds Maé listens to any voice after an answer (default 8)
//   --no-partials            the user's words are not transcribed while they speak (the app shows them; for comparison)
//   --talk-key               conversation: the talk key is held while each phrase is said, released after it
//   --release-after <s>      with --talk-key: seconds between the end of the recording and the release (default 0.25)
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
    var tier: String?
    var all = false
    var llm: String?
    var ttsOnCPU = false
    var speculative = true
    var silenceMs = 500.0
    var minutes = 10.0
    var newConversationEvery: Int?
    var historyBudget: Int?
    var actions = false
    var wakeWord = false
    var followUp: Double?
    /// The user's words are not transcribed while they speak (`PipelineConfig.partialTranscriptSeconds`).
    var noPartials = false
    /// conversation: the talk key held while each phrase is said (as ⌥ Space in the app), released this long after it.
    var talkKey = false
    var releaseAfter = 0.25
    var voices = ["estelle"]
    var temperatures: [Float] = [0.7]
    /// voice-onset: 3 by default; dialogue-bench: 10.
    var repeats: Int?
    /// voice-onset: voices speaking each sentence at once (the first audible one counts).
    var parallel = 1
    /// voice-onset: the language model loaded too, writing an answer while the voice opens, as in a turn.
    var withLLM = false
    /// voice-onset --with-llm: the voice's session made before the language model writes, as the pipeline does.
    var earlySession = false
    /// Voices racing for each answer's first sound (`PipelineConfig.racingVoices`).
    var racingVoices: Int?
    /// The voice is never started again after a long near-silent opening (`PipelineConfig.voiceRestartAfterSeconds`).
    var noVoiceRestart = false
    /// Seconds of near-silent opening before the voice starts again (default: the app's).
    var voiceRestartAfter: Double?
    var now: String?
    var corpus: String?
    var showPrompt = false
    var watchCalls = false
    var compareBeginnings = false
    var addendum: String?
    var examples: String?
    var web = false
    /// dialogue-bench: Claude Code's tools offered too (cache-check reads its own --agents).
    var agents = false
    var searxng: String?
    var searxngUser: String?
    var record: String?
    var out = URL(fileURLWithPath: "measurements")
    var files: [URL] = []

    static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        guard let command = it.next() else { return nil }
        o.command = command
        while let a = it.next() {
            switch a {
            case "--tier": o.tier = it.next()
            case "--all": o.all = true
            case "--llm": o.llm = it.next()
            case "--tts": o.ttsOnCPU = it.next() == "cpu"
            case "--no-speculative": o.speculative = false
            case "--silence-ms": o.silenceMs = Double(it.next() ?? "") ?? o.silenceMs
            case "--minutes": o.minutes = Double(it.next() ?? "") ?? o.minutes
            case "--new-conversation-every": o.newConversationEvery = Int(it.next() ?? "")
            case "--history-budget": o.historyBudget = Int(it.next() ?? "")
            case "--actions": o.actions = true
            case "--wake-word": o.wakeWord = true
            case "--follow-up": o.followUp = Double(it.next() ?? "")
            case "--no-partials": o.noPartials = true
            case "--talk-key": o.talkKey = true
            case "--release-after": o.releaseAfter = Double(it.next() ?? "") ?? o.releaseAfter
            case "--out": o.out = URL(fileURLWithPath: it.next() ?? "measurements")
            case "--voices": o.voices = (it.next() ?? "").split(separator: ",").map(String.init)
            case "--temperatures": o.temperatures = (it.next() ?? "").split(separator: ",").compactMap { Float($0) }
            case "--repeats": o.repeats = Int(it.next() ?? "")
            case "--parallel": o.parallel = max(1, Int(it.next() ?? "") ?? 1)
            case "--with-llm": o.withLLM = true
            case "--early-session": o.earlySession = true
            case "--racing-voices": o.racingVoices = Int(it.next() ?? "")
            case "--no-voice-restart": o.noVoiceRestart = true
            case "--voice-restart-after": o.voiceRestartAfter = Double(it.next() ?? "")
            case "--now": o.now = it.next()
            case "--corpus": o.corpus = it.next()
            case "--show-prompt": o.showPrompt = true
            case "--watch-calls": o.watchCalls = true
            case "--compare-beginnings": o.compareBeginnings = true
            case "--addendum": o.addendum = it.next()
            case "--examples": o.examples = it.next()
            case "--web": o.web = true
            case "--agents": o.agents = true
            case "--searxng": o.searxng = it.next()
            case "--searxng-user": o.searxngUser = it.next()
            case "--record": o.record = it.next()
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
    /// The user's words shown while they spoke, in all.
    var partials = 0

    func record(_ event: PipelineEvent) async {
        switch event {
        case .state(let s):
            state = s
            if s == .speaking, let model = diagnostics {
                let p = await model.lastPrefill
                print("  · model: \(p.reused) tokens reused, \(p.computed) computed in \(fmt(p.ms))")
            }
        case .partialTranscript(let text):
            partials += 1
            print("  …  \(text)")
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
                      + (m.speculative ? " (prepared speculatively)" : "")
                      + String(format: " · memory %.2f GB", ProcessMemory.footprintGB))
            }
        case .bargeIn(let stopMs, let detectionMs):
            bargeIns.append((stopMs, detectionMs))
            print("  ✋ interruption: voice cut \(fmt(stopMs)) after the start of speech"
                  + " (detection: \(fmt(detectionMs)))")
        case .awake(let awake):
            print(awake ? "  👂 awake: any voice starts a turn" : "  💤 asleep: waiting for the wake phrase")
        case .wakeDecision(let decision):
            print("  🔎 \(decision.moment.rawValue), \(decision.accepted ? "for Maé" : "ignored"): \(decision.heard)")
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
    let tier = try tierOption(o)
    print("Mac: \(hw.chipName), \(Int(hw.memoryGiB.rounded())) GB → tier “\(tier.rawValue)”"
          + (tier.isTested ? "" : " (UNTESTED)"))
    let store = ModelStore()
    let packs = ModelCatalog.packs(for: tier).filter { o.llm == nil || $0.role != .languageModel }
    guard let languageModel = ModelCatalog.languageModel(for: tier), store.isComplete(packs) else {
        throw CLIError("models missing or incomplete: run “voice-cli download"
                       + (o.tier.map { " --tier \($0)" } ?? "") + "” first")
    }
    let llmURL = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(languageModel)
    guard let vadURL = ModelLocator.voiceActivity() else { throw CLIError("silero_vad.mlmodelc not found") }

    let clock = ContinuousClock()
    var t = clock.now
    let detector = try SileroSpeechDetector(modelURL: vadURL)
    let transcriber = try await ParakeetTranscriber.load(directory: store.folder(ModelCatalog.speechRecognition))
    print("loaded: voice detection + transcription in \(clock.now - t)")
    t = clock.now
    let model = try await MLXChatModel.load(directory: llmURL)
    print("loaded: \(llmURL.lastPathComponent) in \(clock.now - t)")
    t = clock.now
    let synthesizer = PocketSpeechSynthesizer(
        computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine, store: store)
    try await synthesizer.preload([.french, .english])
    print("loaded: voice (\(o.ttsOnCPU ? "CPU" : "GPU")) in \(clock.now - t)")

    var config = PipelineConfig()
    config.speculativeStart = o.speculative
    config.turn.endOfTurnSilenceMs = o.silenceMs
    if let budget = o.historyBudget {
        config.historyTokenBudget = budget
        config.historyTrimTarget = budget * 2 / 3
    }
    config.actionExamples = ActionCatalog.showsExamples(on: tier)
    if let voices = o.racingVoices { config.racingVoices = max(1, voices) }
    if let seconds = o.voiceRestartAfter { config.voiceRestartAfterSeconds = seconds }
    if o.noVoiceRestart { config.voiceRestartAfterSeconds = nil }
    if o.wakeWord { config.listening = .wakeWord }
    if let followUp = o.followUp { config.wakeFollowUpSeconds = followUp }
    if o.noPartials { config.partialTranscriptSeconds = nil }
    let speaker = SimulatedSpeaker()
    let pipeline = VoicePipeline(detector: detector, transcriber: transcriber, model: model,
                                 synthesizer: synthesizer, output: speaker,
                                 tools: o.actions ? ToolRunner(providers: [DryActions()]) : nil, config: config)
    let log = EventLog()
    await log.attach(model)
    Task { for await event in pipeline.events { await log.record(event) } }
    try await pipeline.start()
    print(String(format: "memory after loading: %.2f GB\n", ProcessMemory.footprintGB))
    return Engine(pipeline: pipeline, speaker: speaker, log: log, model: model)
}

/// `--actions`: the app's actions as the model sees them (the same tools and instructions, the date line in the user's
/// messages), none carried out: a call is declined.
private struct DryActions: ToolProvider {
    let identifier = "dry-actions"
    func tools() async -> [ToolSpec] { ActionCatalog.calendarTools + [ActionCatalog.timer] }
    func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        throw ToolRefusal(forModel: "Action non effectuée (essai).", spoken: ActionPhrases.declined(context.language),
                          retryable: false)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Commands

func waitForAnswer(_ e: Engine, mic: SimulatedMicrophone, after count: Int, timeout: Double = 60) async {
    await mic.silence(until: {
        let done = await e.log.completedTurns > count
        let idle = await e.log.state == .listening
        return done && idle
    }, timeout: timeout)
}

func runConversation(_ o: Options, _ e: Engine) async throws {
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    for (i, file) in o.files.enumerated() {
        print("■ turn \(i + 1) — \(file.lastPathComponent)")
        let before = await e.log.completedTurns
        if o.talkKey {
            await e.pipeline.setTalkKey(pressed: true)
            await mic.say(try WAV.read16kMono(file))
            await mic.silence(o.releaseAfter)
            await e.pipeline.setTalkKey(pressed: false)
        } else {
            await mic.say(try WAV.read16kMono(file))
        }
        // With the wake word, a sentence without the phrase gets no answer: no need to wait a minute for one.
        await waitForAnswer(e, mic: mic, after: before, timeout: o.wakeWord ? 20 : 60)
        if await e.log.completedTurns == before { print("  (no answer)") }
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
    print("the user's words shown while they spoke: \(await e.log.partials)")
    print(String(format: "memory: %.2f GB · cache rebuilds: %d · back to a snapshot: %d",
                 ProcessMemory.footprintGB, await e.model.cacheRebuilds, await e.model.snapshotRestores))
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
        await waitForAnswer(e, mic: mic, after: before, timeout: o.wakeWord ? 20 : 60)  // « OK Maé, stop »: no answer
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
    var samples: [(minute: Double, gb: Double, gpuGB: Double)] = []
    var newConversations: [Double] = []
    let start = clock.now
    var i = 0
    print("turn;minute;memory_GB;GPU_GB;latency_ms")
    while clock.now < end {
        if let every = o.newConversationEvery, i > 0, i % every == 0 {
            // As "Nouvelle conversation" in the app; the next answer would wait for it.
            let reset = clock.now
            try await e.pipeline.resetConversation()
            let d = clock.now - reset
            newConversations.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            print("new conversation;\(fmt(newConversations.last))")
        }
        let before = await e.log.completedTurns
        await mic.say(phrases[i % phrases.count])
        await waitForAnswer(e, mic: mic, after: before)
        await mic.silence(0.5)
        _ = await e.speaker.takeRecording()
        let minute = Double((clock.now - start).components.seconds) / 60
        let gb = ProcessMemory.footprintGB
        let gpuGB = MLXChatModel.activeMemoryGB
        samples.append((minute, gb, gpuGB))
        print(String(format: "%d;%.1f;%.3f;%.3f;%@", i + 1, minute, gb, gpuGB, fmt(await e.log.turns.last?.latencyMs)))
        i += 1
    }
    if let first = samples.first, let last = samples.last {
        print(String(format: "\n=== %d turns in %.0f min · memory %.2f → %.2f GB · GPU memory in use %.2f → %.2f GB"
                     + " (max %.2f) ===", samples.count, last.minute, first.gb, last.gb, first.gpuGB, last.gpuGB,
                     samples.map(\.gpuGB).max() ?? 0))
    }
    if !newConversations.isEmpty {
        print("new conversations: \(newConversations.count), median \(fmt(median(newConversations)))"
              + ", max \(fmt(newConversations.max()))")
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
/// measures it per voice and temperature, on typical first sentences, without the language model (`--with-llm`: with it
/// writing an answer meanwhile).
func runVoiceOnset(_ o: Options) async throws {
    // First sentences of answers, as Gemma 4 26B writes them in `voice-cli conversation`.
    let sentences = [
        "Le ciel est bleu à cause de la lumière.", "Bonjour, je vais t'aider avec plaisir.",
        "Tu pourrais faire une randonnée en forêt.", "Oui, ça marche parfaitement sans four.",
        "Tu voulais cuisiner des courgettes ce soir.", "Salut, je peux t'aider avec plaisir.",
        "C'est une question vraiment fascinante.", "Tu voulais cuisiner des courgettes.",
        "Oui, ça fonctionne très bien sans four.", "Tu veux cuisiner des courgettes.",
    ]
    // Only "estelle" is downloaded with the app: other voices are fetched by FluidAudio into its own cache.
    let directory = o.voices == ["estelle"] ? ModelStore().voiceBaseFolder : nil
    let manager = PocketTtsManager(defaultVoice: o.voices[0], language: .french24L, directory: directory,
                                   computeUnits: o.ttsOnCPU ? .uniform(.cpuOnly) : .avoidNeuralEngine)
    try await manager.initialize()
    var llm: MLXChatModel?
    if o.withLLM {
        guard let languageModel = ModelCatalog.languageModel(for: try tierOption(o)) else {
            throw CLIError("no language model for this tier")
        }
        let url = o.llm.map { URL(fileURLWithPath: $0) } ?? ModelStore().folder(languageModel)
        llm = try await MLXChatModel.load(directory: url)
        print("loaded: \(url.lastPathComponent)")
    }
    let clock = ContinuousClock()
    print("voice;temperature;leading_silence_median_ms;leading_silence_p90_ms;leading_silence_max_ms;"
          + "first_audible_median_ms;first_audible_p90_ms;first_audible_max_ms;within_600_ms;mute")
    for voice in o.voices {
        _ = try await speak("Bonjour.", manager: manager, voice: voice, temperature: 0.7, clock: clock)  // load + warm up
        for temperature in o.temperatures {
            var silences: [Double] = []
            var firstAudible: [Double] = []
            var mute = 0
            for _ in 0..<(o.repeats ?? 3) {
                for sentence in sentences {
                    let early = !o.earlySession ? nil
                        : try await manager.makeSession(voice: voice, temperature: temperature)
                    let writing = if let llm { await writeFirstSentence(llm) } else { Task<Void, Never> {} }
                    let all = try await withThrowingTaskGroup(of: (leadingMs: Double, firstAudibleMs: Double?).self) {
                        group in
                        for runner in 0..<o.parallel {
                            group.addTask {
                                try await speak(sentence, manager: manager, voice: voice, temperature: temperature,
                                                clock: clock, session: runner == 0 ? early : nil)
                            }
                        }
                        var all: [(leadingMs: Double, firstAudibleMs: Double?)] = []
                        for try await r in group { all.append(r) }
                        return all
                    }
                    llm?.holdGeneration(false)
                    writing.cancel()
                    await writing.value
                    // Several voices at once: the first audible one counts.
                    let r = all.min { ($0.firstAudibleMs ?? .infinity) < ($1.firstAudibleMs ?? .infinity) }!
                    silences.append(r.leadingMs)
                    if let audible = r.firstAudibleMs { firstAudible.append(audible) } else { mute += 1 }
                    let each = all.map { "\(fmt($0.firstAudibleMs)) after \(fmt($0.leadingMs))" }
                    let others = all.count > 1 ? " [" + each.joined(separator: ", ") + "]" : ""
                    print("  \(fmt(r.firstAudibleMs)) (near-silence \(fmt(r.leadingMs)))\(others): \(sentence)")
                }
            }
            print(String(format: "  memory: %.2f GB", ProcessMemory.footprintGB))
            let within = firstAudible.filter { $0 <= 600 }.count
            print("\(voice);\(temperature);\(fmt(median(silences)));\(fmt(percentile(silences, 0.9)));"
                  + "\(fmt(silences.max()));\(fmt(median(firstAudible)));\(fmt(percentile(firstAudible, 0.9)));"
                  + "\(fmt(firstAudible.max()));\(within)/\(silences.count);\(mute)")
        }
    }
}

/// `voice-onset --with-llm`: the language model writes a long answer and pauses once its first sentence is written, as
/// in a turn while the voice opens (`YieldsToVoice`: 1.5 s at most). Returns the task writing, once paused.
func writeFirstSentence(_ model: MLXChatModel) async -> Task<Void, Never> {
    let (paused, signal) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        var text = ""
        var paused = false
        do {
            let request = [ChatMessage(.user, "Raconte-moi une longue histoire de pirates.")]
            for try await output in model.reply(to: request) {
                guard case .text(let piece) = output, !paused else { continue }
                text += piece
                if text.contains(". ") || text.contains("! ") {
                    paused = true
                    model.holdGeneration(true)
                    signal.yield()
                }
            }
        } catch {}
        signal.finish()
    }
    for await _ in paused { break }
    return task
}

/// The value below which `fraction` of the values lie (nearest rank).
func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s[min(s.count - 1, max(0, Int((fraction * Double(s.count)).rounded(.up)) - 1))]
}

/// Speaks `text` until its first audible frame (then stops): the near-silence before it, and the time it took.
func speak(_ text: String, manager: PocketTtsManager, voice: String, temperature: Float, clock: ContinuousClock,
           session ready: PocketTtsSession? = nil) async throws -> (leadingMs: Double, firstAudibleMs: Double?)
{
    let start = clock.now
    let session = if let ready { ready } else { try await manager.makeSession(voice: voice, temperature: temperature) }
    session.enqueue(text)
    session.finish()
    var leading = 0
    var firstAudible: Double?
    for try await frame in session.frames {
        let meanSquare = frame.samples.reduce(0) { $0 + $1 * $1 } / Float(max(frame.samples.count, 1))
        if 10 * log10(max(meanSquare, 1e-12)) < -45 {
            leading += frame.samples.count
        } else {
            let d = clock.now - start
            firstAudible = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            break
        }
    }
    await session.cancel()
    return (Double(leading) / 24, firstAudible)
}

// MARK: - Entry point

if let options = Options.parse(CommandLine.arguments),
   ["voice-onset", "download", "verify", "catalog", "actions-bench", "dialogue-bench", "cache-check", "link-client",
    "delegate", "web-search", "inbound"].contains(options.command)
{
    do {
        switch options.command {
        case "download": try await runDownload(options)
        case "verify": try runVerify(options)
        case "catalog": try await runCatalog(options)
        case "actions-bench": try await runActionsBench(options)
        case "dialogue-bench": try await runDialogueBench(options)
        case "cache-check": try await runCacheCheck(options, arguments: CommandLine.arguments)
        case "link-client": try await runLinkClient()
        case "delegate": try await runDelegate(CommandLine.arguments)
        case "web-search": try await runWebSearch(CommandLine.arguments)
        case "inbound": try await runInbound(CommandLine.arguments)
        default: try await runVoiceOnset(options)
        }
    } catch {
        print("\nERROR: \(error)")
        exit(1)
    }
    exit(0)
}
guard let options = Options.parse(CommandLine.arguments), !options.files.isEmpty else {
    print("""
        usage: voice-cli conversation|interruption|endurance [--tier tier] [--llm folder] [--tts gpu|cpu] [--actions]
                         [--no-speculative] [--silence-ms 500] [--minutes 10] [--new-conversation-every n]
                         [--out folder] files.wav…
               voice-cli download [--tier minimum|standard|comfort|max]
               voice-cli verify [--tier tier | --all]
               voice-cli voice-onset [--voices a,b] [--temperatures 0.7,0.5] [--repeats 3] [--parallel 1]
                                     [--with-llm]
               voice-cli actions-bench [--tier tier] [--llm folder] [--now 2026-10-15T18:42] [--corpus file.json]
                                       [--web] [--searxng <address> [--searxng-user name]] [--record file.json]
                                       [--compare-beginnings]
               voice-cli dialogue-bench [--tier tier] [--llm folder] [--now 2026-10-15T18:42] [--corpus file.json]
                                        [--repeats 10] [--agents] [--web] [--examples app|none|file] [--addendum file]
                                        [--watch-calls]
               voice-cli cache-check [--tier tier] [--llm folder] [--scenario name] [--agents]
               voice-cli web-search --searxng <address> [--searxng-user name] [--language fr|en] keywords…
               voice-cli link-client [--pair "<link>"] [--relay-only | --direct-only] [--out folder] files.wav…
               voice-cli delegate --check | --instruction "…" [--title "…"] [--folder dir] [--mode acceptEdits|auto]
                                  [--follow-up "…"] [--stop-after seconds]
               voice-cli inbound --relay <home relay> [--name Essai] [--seconds 600]
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
