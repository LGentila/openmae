import Foundation
import Testing

@testable import VoiceCore

/// What becomes of an announcement (a timer that rang) that the user did not hear, or not all of it: said again later,
/// or kept in the history cut off.
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
              synthesizer: any SpeechSynthesizer = FakeSynthesizer(), config: PipelineConfig = .init()) -> VoicePipeline
    {
        VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                      synthesizer: synthesizer, output: speaker, config: config)
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
        await waitFor { await log.finished.count >= 2 }  // the recorder reads the events on its own task
        #expect(await log.pieces == [Self.sentence, Self.sentence])
        #expect(await recorded(model) == [Self.sentence])
        #expect(await log.finished.map(\.interrupted) == [true, false])
    }

    /// Said without the device saying it played it, the announcement's voice had been produced to its end: it is said
    /// again from that recording, the voice not started again (its new near-silent opening could leave a gap after the
    /// chime).
    @Test func unconfirmedSaidAgainFromItsRecording() async throws {
        let (model, speaker, voice) = (ScriptedModel(), FakeSpeaker(confirms: false), CountingSynthesizer())
        let pipeline = make(model, speaker, synthesizer: voice)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await recorded(model) == [Self.sentence] }
        #expect(await speaker.played == 2 * Self.samples)  // the chime and the same words, twice
        #expect(voice.started == 1)
        await waitFor { await log.pieces.count >= 2 }  // the recorder reads the events on its own task
        #expect(await log.pieces == [Self.sentence, Self.sentence])
    }

    /// The home station that says the announcement drops during it (the iPad unplugged during the chime): it is said
    /// again at once where the conversation is, from the voice the station was given, which the voice had produced to
    /// its end.
    @Test func droppedStationSaidAgainHereFromItsRecording() async throws {
        let (model, speaker, voice) = (ScriptedModel(), FakeSpeaker(), CountingSynthesizer())
        let station = FakeSpeaker(confirms: false)
        let pipeline = make(model, speaker, synthesizer: voice)
        try await pipeline.start()
        await pipeline.announceThrough(station)
        await announce(pipeline)
        await waitFor { await station.played == Self.samples }  // all of it went to the station: the chime plays
        await pipeline.announceThrough(nil)
        await waitFor { await recorded(model) == [Self.sentence] }
        #expect(await station.played == Self.samples)
        #expect(await speaker.played == Self.samples)
        #expect(voice.started == 1)
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
        #expect(await model.catchUps.isEmpty)  // none of its words was heard: not in the history
        #expect(await log.finished.map(\.interrupted) == [true])  // the interfaces showed it: cut off
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

    /// The user speaks over the sentence once it could be heard (« Attends, lequel ? »): the model's next request, and
    /// the history after it, hold the note and the sentence cut off, then the note of the cut, before the user's message,
    /// so it knows the timer rang; the interfaces show the sentence cut off.
    @Test func spokenOverAfterItsWordsKeptCutOff() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Oui ?"]), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        try await Task.sleep(for: .milliseconds(900))  // the chime is over: the sentence plays
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await recorded(model) == [Self.sentence, "Oui ?"] }
        await waitFor { await log.finished.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        let requests = await model.requests
        #expect(!requests.isEmpty)
        for request in requests {  // the user's turn (and any answer prepared during a pause)
            #expect(request.map(\.role) == [.system, .user, .assistant, .system, .user])
            #expect(request.dropFirst().prefix(3).map(\.content) == [Self.note, Self.sentence, Conversation.cutOffNote])
        }
        let history = try #require(await model.catchUps.last)
        #expect(history.map(\.role) == [.system, .user, .assistant, .system, .user, .assistant])
        #expect(history.dropFirst().prefix(3).map(\.content) == [Self.note, Self.sentence, Conversation.cutOffNote])
        let finished = await log.finished
        #expect(finished.map(\.interrupted) == [true, false])  // the announcement, cut off; then the user's turn
        #expect(finished.first?.assistantText == Self.sentence)
        #expect(finished.first?.userText == "")
        #expect(await log.pieces == [Self.sentence, "Oui ?"])
        #expect(await log.bargeIns == 1)
    }

    /// A typed turn once the sentence could be heard: the request holds the note and the sentence cut off, the note of the
    /// cut, then the typed words.
    @Test func typedTurnAfterItsWordsKeepsItCutOff() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Celui de 10 minutes."]), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        try await Task.sleep(for: .milliseconds(900))
        await pipeline.submit(text: "Lequel ?")
        await waitFor { await recorded(model) == [Self.sentence, "Celui de 10 minutes."] }
        let request = try #require(await model.requests.last)
        #expect(request.dropFirst().map(\.content) == [Self.note, Self.sentence, Conversation.cutOffNote, "Lequel ?"])
        await waitFor { await log.finished.count == 2 }  // the recorder reads the events on its own task
        #expect(await log.pieces == [Self.sentence, "Celui de 10 minutes."])
        #expect(await log.finished.map(\.interrupted) == [true, false])
    }

    /// The same on a tier that keeps the note after the user's words (E4B, E2B): nothing follows the sentence cut off,
    /// and the typed words say it.
    @Test func typedTurnAfterItsWordsSaysTheCutAfterTheUsersWords() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Celui de 10 minutes."]), FakeSpeaker())
        var config = PipelineConfig()
        config.cutOffPlacement = .afterUserWords
        let pipeline = make(model, speaker, config: config)
        try await pipeline.start()
        await announce(pipeline)
        await waitFor { await speaker.played == Self.samples }
        try await Task.sleep(for: .milliseconds(900))
        await pipeline.submit(text: "Lequel ?")
        await waitFor { await recorded(model) == [Self.sentence, "Celui de 10 minutes."] }
        let request = try #require(await model.requests.last)
        #expect(request.dropFirst().map(\.content) == [Self.note, Self.sentence, "Lequel ?\n" + Conversation.cutOffNote])
    }

    /// Asked to be quiet once the sentence could be heard (the stop button, « OK Maé, stop »): not said again, and the
    /// history keeps it cut off, in its language.
    @Test func stopAfterItsWordsKeptCutOff() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let pipeline = make(model, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        let sentence = "Your timer is done."
        await pipeline.announce(sentence, note: Self.note, language: .english)
        await waitFor { await speaker.played == Self.samples }
        try await Task.sleep(for: .milliseconds(900))
        await pipeline.interrupt()
        await waitFor { await recorded(model) == [sentence] }
        try await Task.sleep(for: .milliseconds(1500))  // not said again
        #expect(await speaker.played == Self.samples)
        #expect(await log.pieces == [sentence])
        let history = try #require(await model.catchUps.last)
        #expect(history.dropFirst().map(\.content) == [Self.note, sentence, Conversation.cutOffNote])
        let finished = await log.finished
        #expect(finished.map(\.interrupted) == [true])
        #expect(finished.first?.assistantText == sentence)
        #expect(finished.first?.language == .english)
        // Cut off: a note says so, before the next message.
        await pipeline.submit(text: "Merci")
        await waitFor { await model.requests.count == 1 }
        #expect(await model.requests.last?.suffix(2) == [Conversation.cutOffMessage, ChatMessage(.user, "Merci")])
    }
}

/// `FakeSynthesizer`, counting the utterances it starts.
final class CountingSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    let outputSampleRate = 1000.0
    private let lock = NSLock()
    private var count = 0
    var started: Int { lock.withLock { count } }
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        lock.withLock { count += 1 }
        return FakeStream()
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
