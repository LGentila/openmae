// voice-cli voice-gaps — long answers (five sentences asked) to typed questions, through the whole pipeline as in the
// app: the language model writes while the voice speaks, and each sentence of the voice opens with a near-silent breath
// of random length. For each sentence after an answer's first one, the silence heard before it: from the end of the last
// audible sound before it to its first audible sound, on a speaker that plays in real time; and whether it was heard at
// all.
//
//   voice-cli voice-gaps [--repeats 1] [--questions n] [--no-sentence-restart] [--sentence-restart-after s] [options]
//
// --questions n: the first n questions only. A new conversation starts every 10 questions.
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
        /// When the voice produced it.
        var at = ContinuousClock.now
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var frames: [Frame] = []
    private var texts: [String] = []
    private var utterances = 0

    func wrap(_ voice: PocketSpeechSynthesizer) -> any SpeechSynthesizer { GapSynthesizer(voice: voice, log: self) }

    func started() { lock.withLock { utterances += 1 } }
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

    var outputSampleRate: Double { voice.outputSampleRate }

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        log.started()
        return GapStream(try await voice.startUtterance(language: language), log: log)
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

    init(_ voice: any SynthesisStream, log: GapVoice) {
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
                                                    audible: 10 * log10(max(meanSquare, 1e-12)) >= threshold))
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
}

/// Matches what the speaker played with the frames the voice produced (the pipeline plays them in order, and leaves
/// some near-silent ones out), then times each text: the silence heard before each one after the first.
func hear(_ plays: [SimulatedSpeaker.Played], frames: [GapVoice.Frame], texts: [String], sampleRate: Double)
    -> (gaps: [Double], openings: [Double], leads: [Double], waits: [Double], lost: [String])
{
    var cursor = 0
    var firstSound: [String: ContinuousClock.Instant] = [:]
    var lastSoundEnd: [String: ContinuousClock.Instant] = [:]
    var opening: [String: Double] = [:]
    var firstFrame: [String: Int] = [:]
    for play in plays {
        guard let index = frames[cursor...].firstIndex(where: { $0.samples == play.samples }) else { continue }
        cursor = index + 1
        guard frames[index].audible else { continue }
        let text = frames[index].text
        if firstSound[text] == nil {
            firstSound[text] = play.start
            firstFrame[text] = index
            // The near-silent frames of that text just before it, in the utterance heard.
            let quiet = frames[..<index].reversed().prefix { $0.text == text && !$0.audible }
            opening[text] = Double(quiet.map(\.samples.count).reduce(0, +)) / sampleRate
        }
        lastSoundEnd[text] = play.start + .seconds(Double(play.samples.count) / sampleRate)
    }
    var gaps: [Double] = []
    var openings: [Double] = []
    var leads: [Double] = []
    var waits: [Double] = []
    var lost: [String] = []
    var previous: (text: String, end: ContinuousClock.Instant)?
    for text in texts {
        guard let start = firstSound[text], let index = firstFrame[text] else {
            lost.append(text)
            continue
        }
        if let previous {
            gaps.append((start - previous.end).seconds)
            openings.append(opening[text] ?? 0)
            // When the voice was done with the text before (its last frame before this one's first audible frame).
            let done = frames[..<index].last { $0.text == previous.text }?.at ?? frames[index].at
            leads.append((previous.end - done).seconds)
            waits.append((frames[index].at - done).seconds)
        }
        if let end = lastSoundEnd[text] { previous = (text, end) }
    }
    return (gaps, openings, leads, waits, lost)
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
            let answer = HeardAnswer(question: question, texts: produced.texts.count, gaps: heard.gaps,
                                     openings: heard.openings, leads: heard.leads, waits: heard.waits,
                                     lost: heard.lost, utterances: produced.utterances, latencyMs: metrics.latencyMs,
                                     firstAudioMs: metrics.synthesisFirstAudioMs)
            answers.append(answer)
            let gaps = heard.gaps.indices.map { i in
                String(format: "%.2f [%.2f %.2f %.2f]%@", heard.gaps[i], heard.openings[i], heard.leads[i],
                       heard.waits[i], heard.gaps[i] >= 1 ? " (!)" : "")
            }
            print("  \(answer.texts) texts, \(answer.utterances) utterance(s); silence before each later one [its"
                  + " near-silent opening, what was left to hear of the one before, the voice's time to it] (s): "
                  + gaps.joined(separator: ", ") + (heard.lost.isEmpty ? "" : "; NOT HEARD: \(heard.lost)"))
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
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("voice-gaps-\(stamp).json")
    try encoder.encode(answers).write(to: url)
    print("report: \(url.path)")
}
