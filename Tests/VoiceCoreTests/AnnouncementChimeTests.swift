import Foundation
import Testing

@testable import VoiceCore

/// An announcement's chime waits for the voice's first sound (`chimeWaitsForVoiceSeconds` at most), and its words
/// follow the chime.
@Suite("Announcement chime", .serialized)
struct AnnouncementChimeTests {
    static let sentence = "Ton minuteur de 10 minutes est terminé."
    static let note = "(Le minuteur a sonné.)"
    /// The chime, as the fake voice's rate makes it (1 sample = 1 ms).
    static let chime = Chime.samples(sampleRate: 1000).count

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ voice: LateVoice, _ speaker: ClockedSpeaker, model: ScriptedModel = ScriptedModel(),
              config: PipelineConfig = .init()) -> VoicePipeline
    {
        VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                      synthesizer: voice, output: speaker, config: config)
    }

    func announce(_ pipeline: VoicePipeline) async {
        await pipeline.announce(Self.sentence, note: Self.note, language: .french)
    }

    /// The voice is audible 50 ms after the announcement: the chime then, and the words right after it.
    @Test func theChimeWaitsForTheVoicesFirstSound() async throws {
        let (voice, speaker) = (LateVoice(), ClockedSpeaker())
        let pipeline = make(voice, speaker)
        try await pipeline.start()
        let start = ContinuousClock.now
        await announce(pipeline)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await speaker.sounds.isEmpty)  // no chime while the voice opens with near-silence
        let audible = ContinuousClock.now
        voice.speak()
        await waitFor { await speaker.sounds.count == 2 }
        let sounds = await speaker.sounds
        #expect(sounds.map(\.samples) == [Self.chime, 500])
        guard sounds.count == 2 else { return }
        #expect(sounds[0].start - start >= .milliseconds(50))
        #expect(sounds[0].start - audible < .milliseconds(150))  // as soon as the voice is audible, not 0.3 s after
        #expect(sounds[1].start == sounds[0].start + .milliseconds(Self.chime))  // the words right after the chime
    }

    /// The voice stays near-silent: the chime does not wait more than 0.3 s; the words come once the voice has them.
    @Test func theChimeWaitsAtMostItsPatience() async throws {
        let (voice, speaker) = (LateVoice(), ClockedSpeaker())
        let pipeline = make(voice, speaker)
        try await pipeline.start()
        let start = ContinuousClock.now
        await announce(pipeline)
        await waitFor { await speaker.sounds.count == 1 }
        let chime = try #require(await speaker.sounds.first)
        #expect(chime.samples == Self.chime)
        #expect(chime.start - start >= .milliseconds(300))
        #expect(chime.start - start < .milliseconds(900))
        voice.speak()
        await waitFor { await speaker.sounds.count == 2 }
        #expect(await speaker.sounds.map(\.samples) == [Self.chime, 500])
    }

    /// Without the wait, the chime plays at once, the voice still near-silent.
    @Test func withoutTheWaitTheChimePlaysAtOnce() async throws {
        var config = PipelineConfig()
        config.chimeWaitsForVoiceSeconds = 0
        let (voice, speaker) = (LateVoice(), ClockedSpeaker())
        let pipeline = make(voice, speaker, config: config)
        try await pipeline.start()
        let start = ContinuousClock.now
        await announce(pipeline)
        await waitFor { await speaker.sounds.count == 1 }
        let chime = try #require(await speaker.sounds.first)
        #expect(chime.samples == Self.chime)
        #expect(chime.start - start < .milliseconds(200))
        voice.speak()
        await waitFor { await speaker.sounds.count == 2 }
        #expect(await speaker.sounds.map(\.samples) == [Self.chime, 500])
    }

    /// The user's typed turn comes while the chime waits: no chime then; the user's turn, then the announcement, whole
    /// (its chime, then its words), recorded once.
    @Test func stoppedWhileTheChimeWaitsSaidAfterTheUsersTurn() async throws {
        let model = ScriptedModel(answer: ["Bonjour !"])
        let (voice, speaker) = (LateVoice(), ClockedSpeaker())
        let pipeline = make(voice, speaker, model: model)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        try await Task.sleep(for: .milliseconds(100))
        await pipeline.submit(text: "Salut")
        await waitFor { await speaker.sounds.count == 3 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await speaker.sounds.map(\.samples) == [500, Self.chime, 500])  // the answer, the chime, the words
        await waitFor { (await model.catchUps.last ?? []).filter { $0.role == .assistant }.count == 2 }
        let history = try #require(await model.catchUps.last)
        #expect(history.filter { $0.role == .assistant }.map(\.content) == ["Bonjour !", Self.sentence])
        #expect(history.filter { $0.role == .user }.map(\.content) == ["Salut", Self.note])
        #expect(voice.utterances.first?.cancelled == true)  // the announcement's first voice, stopped
    }
}

/// A voice whose first utterance stays near-silent until the test makes it audible (`speak()`): then it says what it
/// was given. The next utterances speak at once. Each opens with a near-silent breath (300 samples), then 500 audible
/// samples per text.
final class LateVoice: SpeechSynthesizer, @unchecked Sendable {
    let outputSampleRate = 1000.0
    private let lock = NSLock()
    private var streams: [LateStream] = []

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        let stream = LateStream()
        let first = lock.withLock {
            streams.append(stream)
            return streams.count == 1
        }
        if !first { stream.speak() }
        return stream
    }

    /// The utterances it started, in order.
    var utterances: [LateStream] { lock.withLock { streams } }

    /// The first utterance is audible from now on.
    func speak() { utterances.first?.speak() }
}

final class LateStream: SynthesisStream, @unchecked Sendable {
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let output: AsyncThrowingStream<VoiceAudio, Error>.Continuation
    private let lock = NSLock()
    // Guarded by `lock`.
    private var texts = 0
    /// The texts given while it stays near-silent; nil once it speaks.
    private var waiting: [Int]? = []
    private var finished = false
    private var stopped = false

    init() { (audio, output) = AsyncThrowingStream.makeStream() }

    var cancelled: Bool { lock.withLock { stopped } }

    func enqueue(_ text: String) {
        lock.withLock {
            defer { texts += 1 }
            if waiting != nil { waiting?.append(texts) } else { say(texts) }
        }
    }

    func finish() {
        lock.withLock {
            finished = true
            if waiting == nil { output.finish() }
        }
    }

    func cancel() async {
        lock.withLock { stopped = true }
        output.finish()
    }

    func speak() {
        lock.withLock {
            guard let texts = waiting else { return }
            waiting = nil
            texts.forEach(say)
            if finished { output.finish() }
        }
    }

    /// With `lock` held.
    private func say(_ text: Int) {
        if text == 0 { output.yield(VoiceAudio([Float](repeating: 0.0001, count: 300), text: 0)) }
        output.yield(VoiceAudio([Float](repeating: 0.1, count: 500), text: text))
    }
}

/// Plays in (accelerated) real time as `FakeSpeaker` does (1 sample = 1 ms), and keeps when each sound starts to be
/// heard.
actor ClockedSpeaker: AudioOutput {
    struct Sound {
        var start: ContinuousClock.Instant
        var samples: Int
    }

    private(set) var sounds: [Sound] = []
    private var busyUntil = ContinuousClock.now

    func play(_ samples: [Float], sampleRate: Double) {
        let start = max(busyUntil, .now)
        sounds.append(Sound(start: start, samples: samples.count))
        busyUntil = start + .milliseconds(samples.count)
    }

    func waitUntilDone() async -> PlaybackEnd {
        while busyUntil > .now { try? await Task.sleep(for: .milliseconds(5)) }
        return .confirmed
    }

    func stopImmediately() async { busyUntil = .now }
}
