import Foundation
import Testing

@testable import VoiceCore

/// What becomes of an announcement (a timer that rang) that the user did not hear: said again later, or not.
@Suite("Announcements not heard", .serialized)
struct UnheardAnnouncementTests {
    static let sentence = "Ton minuteur de 10 minutes est terminé."
    static let note = "(Le minuteur a sonné.)"
    /// The chime, then the sentence, as the fake voice plays them (1 sample = 1 ms).
    static let samples = Chime.samples(sampleRate: 1000).count + 500

    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ speaker: FakeSpeaker,
              synthesizer: any SpeechSynthesizer = FakeSynthesizer()) -> VoicePipeline
    {
        VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                      synthesizer: synthesizer, output: speaker)
    }

    func announce(_ pipeline: VoicePipeline) async {
        await pipeline.announce(Self.sentence, note: Self.note, language: .french)
    }

    /// What the history holds of what was said, in order.
    func recorded(_ model: ScriptedModel) async -> [String] {
        (await model.catchUps.last ?? []).filter { $0.role == .assistant }.map(\.content)
    }

    /// The device that has the conversation never says it played it: the announcement is said twice, not more, and
    /// recorded once.
    @Test func unconfirmedSaidOnceMoreAtMost() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker(confirms: false))
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await recorded(model) == [Self.sentence] }
        try await Task.sleep(for: .milliseconds(1500))  // no third time
        #expect(await speaker.played == 2 * Self.samples)
        #expect(await log.pieces == [Self.sentence, Self.sentence])
        #expect(await recorded(model) == [Self.sentence])
        #expect(await log.finished.map(\.interrupted) == [true, false])  // the first one is shown cut off
    }

    /// The voice's output goes out of reach while the announcement is said (the iPhone that has the conversation lost
    /// its connection), and it is stopped before the output says how it ended (the Mac taking the sound back stops
    /// what was playing): said again once the output is back, and recorded once.
    @Test func stoppedWhileOutOfReachSaidAgainOnceBack() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        try await Task.sleep(for: .milliseconds(900))  // past its chime: its words would be heard
        await pipeline.setOutputReachable(false)
        await pipeline.interrupt()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await speaker.played == Self.samples)  // it waits for the output
        await pipeline.setOutputReachable(true)
        await waitFor { await recorded(model) == [Self.sentence] }
        #expect(await speaker.played == 2 * Self.samples)
        #expect(await log.pieces == [Self.sentence, Self.sentence])
        #expect(await recorded(model) == [Self.sentence])
        #expect(await log.finished.map(\.interrupted) == [true, false])
    }

    /// Out of reach for a moment while the announcement is said, but the device says it played it: not said again.
    @Test func confirmedDespiteAMomentOutOfReachNotSaidAgain() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        await pipeline.setOutputReachable(false)
        await pipeline.setOutputReachable(true)
        await waitFor { await recorded(model) == [Self.sentence] }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await speaker.played == Self.samples)
        #expect(await log.pieces == [Self.sentence])
        #expect(await log.finished.map(\.interrupted) == [false])
    }

    /// A typed turn while the chime plays: the user's turn first, then the announcement, whole.
    @Test func cutDuringItsChimeSaidAfterTheUsersTurn() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Bonjour !"]), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }  // all of it went to the speaker: the chime plays
        await pipeline.submit(text: "Salut")
        await waitFor { await log.pieces.count == 3 }
        #expect(await log.pieces == [Self.sentence, "Bonjour !", Self.sentence])
        await waitFor { await recorded(model) == ["Bonjour !", Self.sentence] }
        #expect(await recorded(model) == ["Bonjour !", Self.sentence])
        let history = try #require(await model.catchUps.last)
        #expect(history.filter { $0.role == .user }.map(\.content) == ["Salut", Self.note])
    }

    /// The voice takes a moment to start: the user's typed turn comes before the announcement made any sound. Its chime
    /// is not played into the user's turn; it is said after it.
    @Test func cancelledBeforeAnySoundSaidAfterTheUsersTurn() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Bonjour !"]), FakeSpeaker())
        let pipeline = make(model, speaker, synthesizer: SlowStartSynthesizer())
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        try await Task.sleep(for: .milliseconds(50))
        await pipeline.submit(text: "Salut")
        await waitFor { await log.pieces.count == 2 }
        #expect(await log.pieces == ["Bonjour !", Self.sentence])
        await waitFor { await recorded(model) == ["Bonjour !", Self.sentence] }
        #expect(await recorded(model) == ["Bonjour !", Self.sentence])
        await waitFor { await speaker.played >= 500 + Self.samples }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await speaker.played == 500 + Self.samples)  // the answer, then the announcement: no chime before
    }

    /// Asked to be quiet while the chime plays: the announcement is dropped.
    @Test func stopDuringItsChimeDropsIt() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        await pipeline.interrupt()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await log.pieces == [Self.sentence])
        #expect(await speaker.played == Self.samples)
        #expect(await model.catchUps.isEmpty)
    }

    /// The user speaks over the sentence, once it could be heard: it is not said again.
    @Test func interruptedAfterItsWordsNotSaidAgain() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Oui ?"]), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        try await Task.sleep(for: .milliseconds(900))  // the chime is over: the sentence plays
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await log.pieces.contains("Oui ?") }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(await log.pieces == [Self.sentence, "Oui ?"])
        #expect(await log.bargeIns == 1)
    }
}

/// `FakeSynthesizer`, slow to start an utterance (the voice setting up), and deaf to cancellation meanwhile, as the
/// real one is.
struct SlowStartSynthesizer: SpeechSynthesizer {
    let outputSampleRate = 1000.0
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .milliseconds(200) { try? await Task.sleep(for: .milliseconds(10)) }
        return FakeStream()
    }
}
