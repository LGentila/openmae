import Foundation
import Testing

@testable import VoiceCore

/// A new conversation (the interface's « New conversation », the actions or the web search switched on or off) while
/// Maé thinks or speaks: the turn stops, and the state goes back to rest. Each one is reported, whoever asked for it, for
/// the interfaces to clear their transcript: after everything of the earlier conversation, before anything of the new.
@Suite("New conversation during a turn", .serialized)
struct NewConversationTests {
    static let sentence = "Ton minuteur de 10 minutes est terminé."
    static let note = "(Le minuteur a sonné.)"
    /// The chime, then the sentence, as the fake voice plays them (1 sample = 1 ms).
    static let announcementSamples = Chime.samples(sampleRate: 1000).count + 500

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ speaker: FakeSpeaker, synthesizer: any SpeechSynthesizer = FakeSynthesizer(),
              tools: ToolRunner? = nil) -> (VoicePipeline, EventRecorder)
    {
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: synthesizer, output: speaker, tools: tools)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        return (pipeline, log)
    }

    /// The states reported since the `count` first ones.
    func states(_ log: EventRecorder, after count: Int) async -> [PipelineState] {
        Array(await log.states.dropFirst(count))
    }

    /// An answer is playing: Maé speaks, and a new conversation starts.
    func answerPlaying(_ pipeline: VoicePipeline, _ speaker: FakeSpeaker, _ log: EventRecorder) async throws {
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        await waitFor { await speaker.played > 0 }
        await waitFor { await log.states.last == .speaking }
        #expect(await log.states.last == .speaking)
    }

    /// « New conversation » while an answer plays: its sound stops, it is not recorded, and `.listening` follows.
    @Test func newConversationWhileSpeaking() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await answerPlaying(pipeline, speaker, log)
        let before = await log.states.count
        try await pipeline.resetConversation()
        await waitFor { await log.states.count > before }
        #expect(await states(log, after: before) == [.listening])
        #expect(await speaker.stops >= 1)
        #expect(await speaker.remainingMs == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await states(log, after: before) == [.listening])  // and it stays there
        #expect(await model.catchUps.isEmpty)  // the stopped answer is not recorded
        // The interfaces are told, once, after the last piece of the stopped answer and before the state at rest.
        let pieces = await log.pieces.count
        #expect(pieces > 0)
        #expect(await log.clears == [EventRecorder.Moment(pieces: pieces, states: before)])
    }

    /// The same while the model is still thinking (nothing written, nothing said yet).
    @Test func newConversationWhileThinking() async throws {
        let (model, speaker) = (ScriptedModel(pauseAfter: 0), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        await waitFor { await model.requests.count == 1 }
        await waitFor { await log.states.last == .thinking }
        #expect(await log.states.last == .thinking)
        let before = await log.states.count
        try await pipeline.resetConversation()
        await waitFor { await log.states.count > before }
        #expect(await states(log, after: before) == [.listening])
        #expect(await speaker.played == 0)
        #expect(await log.clears == [EventRecorder.Moment(pieces: 0, states: before)])
    }

    /// The actions switched on, then off, while an answer plays: the same, each time.
    @Test func toolsChangedWhileSpeaking() async throws {
        for runner in [ToolRunner(providers: [TimerTools()]), nil] {
            let (model, speaker) = (ScriptedModel(), FakeSpeaker())
            let tools = runner == nil ? ToolRunner(providers: [TimerTools()]) : nil
            let (pipeline, log) = make(model, speaker, tools: tools)
            try await answerPlaying(pipeline, speaker, log)
            let before = await log.states.count
            try await pipeline.setTools(runner)
            await waitFor { await log.states.count > before }
            #expect(await states(log, after: before) == [.listening], "actions \(runner == nil ? "off" : "on")")
            #expect(await speaker.stops >= 1)
            #expect(await (model.tools.isEmpty) == (runner == nil))
            #expect(await model.prefills.last?.beginning == true)  // the new beginning, computed after
            // The interfaces are told, once, after the last piece of the stopped answer and before the state at rest.
            try await Task.sleep(for: .milliseconds(200))
            let pieces = await log.pieces.count
            #expect(pieces > 0)
            #expect(await log.clears == [EventRecorder.Moment(pieces: pieces, states: before)])
            await pipeline.stop()
        }
    }

    /// Every new conversation is reported (`conversationCleared`), at rest too, whoever asked for it: an interface's
    /// « New conversation » (an iPhone's: the Mac's screen clears on it), a change of tools. Not a change of the tools'
    /// list, after which the conversation goes on.
    @Test func everyNewConversationIsReported() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker, tools: ToolRunner(providers: [TimerTools()]))
        try await pipeline.start()
        await waitFor { await log.states == [.listening] }
        try await pipeline.toolsChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.clears.isEmpty)
        try await pipeline.resetConversation()
        await waitFor { await log.clears.count == 1 }
        #expect(await log.clears.count == 1)
        try await pipeline.setTools(nil)  // the actions switched off
        try await pipeline.setTools(ToolRunner(providers: [WebSearchTools()], actions: false))  // the search alone
        await waitFor { await log.clears.count == 3 }
        #expect(await log.clears.count == 3)
        #expect(await log.states == [.listening])  // at rest all along
        await pipeline.stop()
    }

    /// The user speaks right after « New conversation », while the pipeline still sets the new one up (the model
    /// computes its beginning): the report comes before anything of their turn. An interface that clears its transcript
    /// on it (the Mac app does, after clearing it at the click already) keeps the whole turn on screen.
    @Test func aTurnRightAfterANewConversationComesAfterItsReport() async throws {
        let (model, speaker) = (ScriptedModel(beginningTakes: .milliseconds(800)), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await answerPlaying(pipeline, speaker, log)
        let reset = Task { try await pipeline.resetConversation() }
        // The new conversation's beginning is being computed (the start's was the first): the user speaks meanwhile.
        await waitFor { await model.beginningsAsked == 2 }
        #expect(await model.prefills.filter(\.beginning).count == 1)
        let (speech, silence) = ([Float](repeating: 0.5, count: 512), [Float](repeating: 0, count: 512))
        for chunk in Array(repeating: speech, count: 10) + Array(repeating: silence, count: 20) {
            await pipeline.push(chunk)
        }
        try await reset.value
        await waitFor { await model.catchUps.count == 1 }  // the new turn, answered and recorded
        await waitFor { await log.states.last == .listening }
        let timeline = await log.timeline
        let cleared = try #require(timeline.firstIndex(of: "cleared"))
        #expect(timeline.filter { $0 == "cleared" }.count == 1)
        // Before it: the earlier exchange, stopped while Maé spoke. After it: the state at rest, then the whole turn.
        #expect(timeline[..<cleared].contains("user Bonjour"))
        #expect(timeline[..<cleared].contains("state speaking"))
        let after = Array(timeline[(cleared + 1)...])
        #expect(after.prefix(2) == ["state listening", "state userSpeaking"])
        #expect(after.filter { $0.hasPrefix("user ") }.count == 1)
        #expect(after.filter { $0.hasPrefix("piece ") } == ["piece Bonjour, je suis bien là.",
                                                            "piece Comment vas-tu ce matin ?"])
        await pipeline.stop()
    }

    /// No turn: a new conversation reports no state (Maé was at rest already).
    @Test func newConversationAtRestReportsNothing() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await waitFor { await log.states == [.listening] }
        try await pipeline.resetConversation()
        try await pipeline.setTools(ToolRunner(providers: [TimerTools()]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.states == [.listening])
    }

    /// An announcement (a timer that rang) waits for the voice, slow to start: a new conversation stops it before any
    /// of its sound. It is said right after, in the new conversation, whose history then holds only it.
    @Test func announcementWithoutSoundSaidInTheNewConversation() async throws {
        let (model, speaker) = (ScriptedModel(answer: ["Bonjour !"]), FakeSpeaker())
        let (pipeline, log) = make(model, speaker, synthesizer: SlowStartSynthesizer())
        try await pipeline.start()
        await pipeline.submit(text: "Salut")  // the conversation that ends
        await waitFor { await model.catchUps.count == 1 }
        await waitFor { await speaker.remainingMs == 0 }
        await pipeline.announce(Self.sentence, note: Self.note, language: .french)
        try await Task.sleep(for: .milliseconds(50))  // the voice gets ready: nothing played yet
        let played = await speaker.played
        await waitFor { await log.states.last == .thinking }  // the recorder reads the events on its own task
        #expect(await log.states.last == .thinking)
        try await pipeline.resetConversation()
        await waitFor { await model.catchUps.count == 2 }
        await waitFor { await log.pieces.count >= 2 }
        #expect(await log.pieces == ["Bonjour !", Self.sentence])
        #expect(await log.clears.map(\.pieces) == [1])  // reported between the two: the sentence is the new one's
        #expect(await speaker.played == played + Self.announcementSamples)  // its chime, then its sentence, once
        let history = try #require(await model.catchUps.last)
        #expect(history.filter { $0.role == .user }.map(\.content) == [Self.note])
        #expect(history.filter { $0.role == .assistant }.map(\.content) == [Self.sentence])
        await waitFor { await log.states.last == .listening }
        #expect(await log.states.last == .listening)
    }
}
