// voice-cli voice-gaps — long answers (five sentences asked) to typed questions, through the whole pipeline as in the
// app: the language model writes while the voice speaks, and each sentence of the voice opens with a near-silent breath
// of random length. For each sentence after an answer's first one, the silence heard before it: from the end of the last
// audible sound before it to its first audible sound, on a speaker that plays in real time; and whether it was heard at
// all.
//
//   voice-cli voice-gaps [--repeats 1] [--questions n] [--no-voice-lead] [--voice-lead s] [--no-wait-openings]
//                        [--no-sentence-restart] [--sentence-restart-after s] [--slower-voice f] [options]
//
// --questions n: the first n questions only. A new conversation starts every 10 questions.
// --slower-voice f: as if the voice and the language model were that fraction slower than speech (0.1: 10 %), as on a
// Mac whose GPU is slower for a while: the voice tells the pipeline its sample rate is that fraction higher, so the
// simulated speaker plays it that much faster than real time, while the voice and the model run as usual (the model's
// waits act on the real voice). Durations of audio are then in seconds as heard.
//
// Also, for each answer: its total time (from the question to the end of its last sound), the time nothing played in it
// (that total minus the audio played: the wait for the first sound, and the speaker running dry), the speaker running
// dry in the middle of a sentence, the language model's pauses for the voice (`VoiceLead`), and the voice's time per
// 80 ms frame by time since the question (0–2 s, …, 8 s and later).
//
// A sentence is a text given to the voice (the first one may stop at a comma: `SentenceChunker`). Audible: an 80 ms
// frame of the voice at least as loud as the pipeline's threshold (`PipelineConfig.leadingSilenceThresholdDB`).

import Foundation
import VoiceCore
import VoiceEngineApple

/// What the voice produced, frame by frame, with the text each frame says: every utterance of the answer, those started
/// again included.
final class GapVoice: @unchecked Sendable {
    struct Frame {
        var text: String
        var samples: [Float]
        var audible: Bool
        /// The utterance that produced it (a sentence may be started again in another one).
        var utterance: Int
        /// When the voice produced it.
        var at = ContinuousClock.now
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var frames: [Frame] = []
    private var texts: [String] = []
    private var utterances = 0

    /// `slower`: see `--slower-voice`.
    func wrap(_ voice: PocketSpeechSynthesizer, slower: Double = 0) -> any SpeechSynthesizer {
        GapSynthesizer(voice: voice, log: self, rateScale: 1 + slower)
    }

    /// A new utterance starts: its number in this answer.
    func started() -> Int {
        lock.withLock {
            utterances += 1
            return utterances
        }
    }
    func given(_ text: String) { lock.withLock { texts.append(text) } }
    func produced(_ frame: Frame) { lock.withLock { frames.append(frame) } }

    /// Everything since the last call: the frames in order, the texts in the order they were first given, and the
    /// utterances started.
    func take() -> (frames: [Frame], texts: [String], utterances: Int) {
        lock.withLock {
            defer { (frames, texts, utterances) = ([], [], 0) }
            var seen = Set<String>()
            return (frames, texts.filter { seen.insert($0).inserted }, utterances)
        }
    }
}

struct GapSynthesizer: SpeechSynthesizer, KeepsWarm {
    let voice: PocketSpeechSynthesizer
    let log: GapVoice
    /// Above 1: the speaker plays the voice that much faster than real time (`--slower-voice`).
    let rateScale: Double

    var outputSampleRate: Double { voice.outputSampleRate * rateScale }

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        let utterance = log.started()
        return GapStream(try await voice.startUtterance(language: language), utterance: utterance, log: log)
    }

    func keepWarm() async { await voice.keepWarm() }
}

/// The texts an utterance was given, by number (as `VoiceAudio.text` counts them).
final class GivenTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func add(_ text: String) { lock.withLock { texts.append(text) } }
    func text(_ number: Int) -> String? { lock.withLock { texts.indices.contains(number) ? texts[number] : nil } }
}

struct GapStream: SynthesisStream {
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let voice: any SynthesisStream
    private let texts = GivenTexts()
    private let log: GapVoice

    init(_ voice: any SynthesisStream, utterance: Int, log: GapVoice) {
        self.voice = voice
        self.log = log
        let texts = self.texts
        let threshold = PipelineConfig().leadingSilenceThresholdDB ?? -45
        audio = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in voice.audio {
                        let meanSquare = chunk.samples.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.samples.count, 1))
                        log.produced(GapVoice.Frame(text: chunk.text.flatMap(texts.text) ?? "", samples: chunk.samples,
                                                    audible: 10 * log10(max(meanSquare, 1e-12)) >= threshold,
                                                    utterance: utterance))
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func enqueue(_ text: String) {
        texts.add(text)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { log.given(text) }
        voice.enqueue(text)
    }

    func finish() { voice.finish() }
    func cancel() async { await voice.cancel() }
}

/// One answer, as heard.
struct HeardAnswer: Codable {
    var question: String
    /// When it was asked (ISO 8601, UTC).
    var askedAt: String?
    var texts: Int
    /// Seconds of silence heard before each text after the first one heard, in order.
    var gaps: [Double]
    /// For each of those texts, the near-silence its heard utterance opened it with (seconds of the voice's audio).
    var openings: [Double]
    /// For each of those texts, how much of the text before it was still to be heard when the voice was done with that
    /// text (seconds), and how long the voice took from then to the first audible frame of this one (seconds).
    var leads: [Double]
    var waits: [Double]
    /// Texts given to the voice and never heard.
    var lost: [String]
    var utterances: Int
    var latencyMs: Double?
    var firstAudioMs: Double?
    /// From the question to the end of the answer's last audible sound (seconds).
    var totalSeconds: Double?
    /// Audio the speaker played until then, near-silence included (seconds).
    var playedSeconds: Double
    /// Each time the speaker ran dry in the middle of a sentence, after its first audible sound (seconds).
    var stalls: [Double]
    /// The language model's pauses for the voice in this answer, and their length in all (seconds).
    var modelPauses: Int
    var modelPausedSeconds: Double
    /// The voice's pace: the median time between two frames of the same text (milliseconds; 80 ms of audio a frame).
    var voicePaceMs: Double?
    /// The times between two frames of the same text (milliseconds), by when the later one came after the question:
    /// one list per `paceBins` interval.
    var voicePaces: [[Double]]?
}

/// The intervals of time since the question the voice's pace is told by (seconds; the last one has no end).
let paceBins: [Double] = [0, 2, 4, 6, 8]

/// "0–2 s", …, "8+ s".
func paceBinName(_ i: Int) -> String {
    "\(Int(paceBins[i]))" + (i + 1 < paceBins.count ? "–\(Int(paceBins[i + 1]))" : "+") + " s"
}

/// The voice's pace in `frames`: the median time between two frames of the same text in the same utterance (it produces
/// a text's frames one after the other), in milliseconds.
func voicePace(_ frames: [GapVoice.Frame]) -> Double? {
    var last: [Int: GapVoice.Frame] = [:]
    var intervals: [Double] = []
    for frame in frames {
        if let before = last[frame.utterance], before.text == frame.text, !frame.text.isEmpty {
            intervals.append((frame.at - before.at).seconds * 1000)
        }
        last[frame.utterance] = frame
    }
    return median(intervals)
}

/// The times between two frames of the same text in the same utterance (milliseconds), by when the later one came after
/// `asked`, one list per `paceBins` interval.
func voicePaces(_ frames: [GapVoice.Frame], since asked: ContinuousClock.Instant) -> [[Double]] {
    var last: [Int: GapVoice.Frame] = [:]
    var paces = [[Double]](repeating: [], count: paceBins.count)
    for frame in frames {
        if let before = last[frame.utterance], before.text == frame.text, !frame.text.isEmpty {
            let since = (frame.at - asked).seconds
            paces[paceBins.lastIndex { since >= $0 } ?? 0].append((frame.at - before.at).seconds * 1000)
        }
        last[frame.utterance] = frame
    }
    return paces
}

/// What the speaker played of an answer, sentence by sentence (`hear`).
struct Heard {
    /// For each text after the first one heard: the silence heard before it, its near-silent opening, what was left to
    /// hear of the text before when the voice was done with it, and the voice's time from then to its first audible frame.
    var gaps: [Double] = []
    var openings: [Double] = []
    var leads: [Double] = []
    var waits: [Double] = []
    /// Texts given to the voice and never heard.
    var lost: [String] = []
    /// The end of the last audible sound.
    var end: ContinuousClock.Instant?
    /// Audio played until then, near-silence included (seconds).
    var played = 0.0
    /// The speaker ran dry in the middle of a sentence, after its first audible sound: how long, each time (seconds).
    var stalls: [Double] = []
}

/// Matches what the speaker played with the frames the voice produced (the pipeline plays them in order, and leaves
/// some near-silent ones out), then times each text: the silence heard before each one after the first.
func hear(_ plays: [SimulatedSpeaker.Played], frames: [GapVoice.Frame], texts: [String], sampleRate: Double) -> Heard {
    var heard = Heard()
    var cursor = 0
    var firstSound: [String: ContinuousClock.Instant] = [:]
    var lastSoundEnd: [String: ContinuousClock.Instant] = [:]
    var opening: [String: Double] = [:]
    var firstFrame: [String: Int] = [:]
    /// The play before, and the text it said.
    var before: (text: String, end: ContinuousClock.Instant)?
    /// Audio played so far.
    var played = 0.0
    for play in plays {
        let length = Double(play.samples.count) / sampleRate
        played += length
        guard let index = frames[cursor...].firstIndex(where: { $0.samples == play.samples }) else { continue }
        cursor = index + 1
        let text = frames[index].text
        if let before, before.text == text, firstSound[text] != nil {
            let dry = (play.start - before.end).seconds
            if dry > 0.001 { heard.stalls.append(dry) }
        }
        before = (text, play.start + .seconds(length))
        guard frames[index].audible else { continue }
        if firstSound[text] == nil {
            firstSound[text] = play.start
            firstFrame[text] = index
            // The near-silent frames of that text just before it, in the utterance heard.
            let quiet = frames[..<index].reversed().prefix { $0.text == text && !$0.audible }
            opening[text] = Double(quiet.map(\.samples.count).reduce(0, +)) / sampleRate
        }
        lastSoundEnd[text] = play.start + .seconds(length)
        heard.end = lastSoundEnd[text]
        heard.played = played
    }
    var previous: (text: String, end: ContinuousClock.Instant)?
    for text in texts {
        guard let start = firstSound[text], let index = firstFrame[text] else {
            heard.lost.append(text)
            continue
        }
        if let previous {
            heard.gaps.append((start - previous.end).seconds)
            heard.openings.append(opening[text] ?? 0)
            // When the voice was done with the text before (its last frame before this one's first audible frame).
            let done = frames[..<index].last { $0.text == previous.text }?.at ?? frames[index].at
            heard.leads.append((previous.end - done).seconds)
            heard.waits.append((frames[index].at - done).seconds)
        }
        if let end = lastSoundEnd[text] { previous = (text, end) }
    }
    return heard
}

func runVoiceGaps(_ o: Options, _ e: Engine, voice: GapVoice) async throws {
    let questions = [
        "Explique-moi en cinq phrases pourquoi la mer est salée.",
        "En cinq phrases, explique-moi comment se forment les nuages.",
        "Raconte-moi en cinq phrases l'histoire de la tour Eiffel.",
        "En cinq phrases, explique-moi pourquoi le ciel est bleu.",
        "Explique-moi en cinq phrases comment se forme un arc-en-ciel.",
        "En cinq phrases, donne-moi des conseils pour bien dormir.",
        "Explique-moi en cinq phrases comment les abeilles fabriquent le miel.",
        "En cinq phrases, explique-moi pourquoi les feuilles changent de couleur en automne.",
        "Raconte-moi en cinq phrases une petite histoire de pirates.",
        "En cinq phrases, explique-moi comment fonctionne un volcan.",
        "Explique-moi en cinq phrases pourquoi il y a des saisons.",
        "En cinq phrases, donne-moi des idées pour cuisiner des courgettes.",
        "Explique-moi en cinq phrases comment marche un moteur électrique.",
        "En cinq phrases, raconte-moi la vie de Marie Curie.",
        "Explique-moi en cinq phrases pourquoi la Lune change de forme.",
        "En cinq phrases, explique-moi comment les oiseaux migrateurs trouvent leur chemin.",
        "Explique-moi en cinq phrases comment se forme la neige.",
        "En cinq phrases, explique-moi à quoi sert la photosynthèse.",
        "Raconte-moi en cinq phrases l'histoire du chocolat.",
        "En cinq phrases, explique-moi pourquoi on a le hoquet.",
        "Explique-moi en cinq phrases comment fonctionne internet.",
        "En cinq phrases, explique-moi comment se forment les marées.",
        "Explique-moi en cinq phrases pourquoi les chats ronronnent.",
        "En cinq phrases, donne-moi des idées de sortie pour un dimanche pluvieux.",
        "Explique-moi en cinq phrases comment on fabrique le pain.",
        "En cinq phrases, explique-moi ce qu'est un trou noir.",
        "Explique-moi en cinq phrases comment poussent les arbres.",
        "En cinq phrases, explique-moi pourquoi il faut boire de l'eau.",
        "Raconte-moi en cinq phrases l'histoire des Jeux olympiques.",
        "En cinq phrases, explique-moi comment fonctionne un réfrigérateur.",
    ]
    if let slower = o.slowerVoice, slower > 0 {
        print(String(format: "simulated: the voice and the model %.0f %% slower than speech (the speaker plays the"
                     + " voice %.0f %% faster than real time)\n", slower * 100, slower * 100))
    }
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    var answers: [HeardAnswer] = []
    var asked = 0
    for round in 1...(o.repeats ?? 1) {
        for question in questions.prefix(o.questions ?? questions.count) {
            asked += 1
            if asked > 1, (asked - 1) % 10 == 0 { try await e.pipeline.resetConversation() }
            print("■ \(round).\(asked) — \(question)")
            await mic.silence(1)
            _ = voice.take()
            _ = await e.speaker.takePlays()
            let before = await e.log.completedTurns
            let pausesBefore = await e.model.voicePauses
            let asked = ContinuousClock.now
            let askedAt = ISO8601DateFormatter().string(from: Date())
            await e.pipeline.submit(text: question)
            await waitForAnswer(e, mic: mic, after: before, timeout: 90)
            await mic.silence(0.3)
            let produced = voice.take()
            let plays = await e.speaker.takePlays()
            guard await e.log.completedTurns > before, let metrics = await e.log.turns.last else {
                print("  (no answer)")
                continue
            }
            let heard = hear(plays, frames: produced.frames, texts: produced.texts,
                             sampleRate: await e.speaker.sampleRate)
            let pauses = await e.model.voicePauses
            let answer = HeardAnswer(question: question, askedAt: askedAt, texts: produced.texts.count,
                                     gaps: heard.gaps,
                                     openings: heard.openings, leads: heard.leads, waits: heard.waits,
                                     lost: heard.lost, utterances: produced.utterances, latencyMs: metrics.latencyMs,
                                     firstAudioMs: metrics.synthesisFirstAudioMs,
                                     totalSeconds: heard.end.map { ($0 - asked).seconds },
                                     playedSeconds: heard.played, stalls: heard.stalls,
                                     modelPauses: pauses.count - pausesBefore.count,
                                     modelPausedSeconds: pauses.seconds - pausesBefore.seconds,
                                     voicePaceMs: voicePace(produced.frames),
                                     voicePaces: voicePaces(produced.frames, since: asked))
            answers.append(answer)
            let gaps = heard.gaps.indices.map { i in
                String(format: "%.2f [%.2f %.2f %.2f]%@", heard.gaps[i], heard.openings[i], heard.leads[i],
                       heard.waits[i], heard.gaps[i] >= 1 ? " (!)" : "")
            }
            print("  \(answer.texts) texts, \(answer.utterances) utterance(s); silence before each later one [its"
                  + " near-silent opening, what was left to hear of the one before, the voice's time to it] (s): "
                  + gaps.joined(separator: ", ") + (heard.lost.isEmpty ? "" : "; NOT HEARD: \(heard.lost)"))
            print(String(format: "  total %.2f s, nothing played %.2f s; speaker dry inside a sentence %d time(s)"
                         + " (%.2f s); model paused for the voice %d time(s) (%.2f s)",
                         answer.totalSeconds ?? 0, (answer.totalSeconds ?? 0) - answer.playedSeconds,
                         answer.stalls.count, answer.stalls.reduce(0, +), answer.modelPauses,
                         answer.modelPausedSeconds))
        }
    }
    let gaps = answers.flatMap(\.gaps)
    let lost = answers.flatMap(\.lost)
    let later = answers.map { max(0, $0.texts - 1) }.reduce(0, +)
    let under = gaps.filter { $0 < 1 }.count
    let ms = gaps.map { $0 * 1000 }
    print("\n=== Summary: \(answers.count) answers, \(later) texts after the first ===")
    print("silence heard before a later text: median \(fmt(median(ms))), 90th percentile \(fmt(percentile(ms, 0.9))),"
          + " 98th \(fmt(percentile(ms, 0.98))), max \(fmt(ms.max()))")
    let share = 100 * Double(under) / Double(max(1, gaps.count))
    print("under 1 s: \(under) of \(gaps.count)" + String(format: " (%.1f %%)", share))
    print("texts never heard: \(lost.count)" + (lost.isEmpty ? "" : " \(lost)"))
    print("utterances started again: \(answers.map { $0.utterances - 1 }.reduce(0, +))")
    let latencies = answers.compactMap(\.latencyMs)
    let firstAudio = answers.compactMap(\.firstAudioMs)
    print("first sound: latency median \(fmt(median(latencies))), max \(fmt(latencies.max()));"
          + " voice's first sound median \(fmt(median(firstAudio))), max \(fmt(firstAudio.max()))")
    let totals = answers.compactMap(\.totalSeconds).map { $0 * 1000 }
    let idle = answers.compactMap { a in a.totalSeconds.map { ($0 - a.playedSeconds) * 1000 } }
    print("answer's total time (question → end of its last sound): median \(fmt(median(totals))), max"
          + " \(fmt(totals.max())); nothing played in it: median \(fmt(median(idle))), 90th percentile"
          + " \(fmt(percentile(idle, 0.9))), max \(fmt(idle.max()))")
    let stalls = answers.flatMap(\.stalls).map { $0 * 1000 }
    print("speaker dry inside a sentence: \(stalls.count) time(s) in \(answers.filter { !$0.stalls.isEmpty }.count)"
          + " answer(s), \(fmt(stalls.reduce(0, +))) in all, longest \(fmt(stalls.max()))")
    let pauses = answers.map(\.modelPauses)
    let paces = answers.compactMap(\.voicePaceMs)
    print("voice: median \(fmt(median(paces))) per frame (median of the answers; 90th percentile"
          + " \(fmt(percentile(paces, 0.9))))")
    let byTime = paceBins.indices.map { i in answers.flatMap { $0.voicePaces?[i] ?? [] } }
    print("voice's time per frame by time since the question: " + paceBins.indices.map { i in
        "\(paceBinName(i)) \(fmt(median(byTime[i]))) (n=\(byTime[i].count))"
    }.joined(separator: ", "))
    print("model paused for the voice: \(pauses.reduce(0, +)) time(s), median per answer"
          + " \(median(pauses.map(Double.init)).map { String(format: "%.0f", $0) } ?? "—"),"
          + " \(fmt(answers.map(\.modelPausedSeconds).reduce(0, +) * 1000)) in all")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("voice-gaps-\(stamp).json")
    try encoder.encode(answers).write(to: url)
    print("report: \(url.path)")
}
