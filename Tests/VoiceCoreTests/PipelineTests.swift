import Foundation
import Testing

@testable import VoiceCore

// Fake engine stages: the pipeline's logic is tested without any model.

/// "Speech" = any sample louder than 0.05.
struct LoudnessDetector: SpeechDetector {
    let chunkSize = 512
    func speechProbability(_ chunk: [Float]) async throws -> Float { chunk.contains { abs($0) > 0.05 } ? 0.9 : 0 }
    func reset() async {}
}

/// Transcript = number of seconds of audio received, e.g. "deux secondes environ" — enough to tell
/// whether it got the whole utterance.
actor CountingTranscriber: Transcriber {
    private(set) var calls: [Int] = []
    func transcribe(_ samples: [Float]) async throws -> String {
        calls.append(samples.count)
        return "phrase de \(samples.count) échantillons"
    }
}

actor ScriptedModel: LanguageModel {
    private(set) var requests: [[ChatMessage]] = []
    private(set) var tools: [ToolSpec] = []
    /// What to answer, request after request (the last one is repeated).
    private var scripts: [[ModelOutput]]
    /// After this many outputs the model stops writing until it is cancelled, then ends its stream without an error,
    /// as the real one does: an answer in the middle of a sentence.
    private let pauseAfter: Int?
    /// How long computing a beginning to keep takes (`prefillBeginning`): a new prompt, after the tools changed.
    private let beginningTakes: Duration
    init(answer: [String] = ["Bonjour, ", "je suis bien là. ", "Comment vas-tu ce matin ?"], pauseAfter: Int? = nil,
         beginningTakes: Duration = .zero)
    {
        scripts = [answer.map { .text($0) }]
        self.pauseAfter = pauseAfter
        self.beginningTakes = beginningTakes
    }
    init(scripts: [[ModelOutput]]) {
        self.scripts = scripts
        pauseAfter = nil
        beginningTakes = .zero
    }

    nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let script = await self.log(conversation)
                for (i, output) in script.enumerated() {
                    if i == self.pauseAfter {
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                    if Task.isCancelled { break }
                    continuation.yield(output)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func log(_ c: [ChatMessage]) -> [ModelOutput] {
        requests.append(c)
        return scripts.count > 1 ? scripts.removeFirst() : scripts[0]
    }
    func useTools(_ tools: [ToolSpec]) { self.tools = tools }
    func toolCallText(_ call: ToolCall) async -> String? { "[\(call.name)]" }
    /// What was computed ahead, in order: conversations (`prefill`) and beginnings to keep (`prefillBeginning`).
    private(set) var prefills: [(beginning: Bool, messages: [ChatMessage])] = []
    func prefill(_ conversation: [ChatMessage]) async throws { prefills.append((false, conversation)) }
    /// How many beginnings it was asked to compute, finished or not.
    private(set) var beginningsAsked = 0
    func prefillBeginning(_ beginning: [ChatMessage]) async throws {
        beginningsAsked += 1
        if beginningTakes > .zero { try await Task.sleep(for: beginningTakes) }
        prefills.append((true, beginning))
    }
    /// The histories the pipeline asked the model to catch up with, in order.
    private(set) var catchUps: [[ChatMessage]] = []
    /// Whether background work was allowed (`allowBackgroundWork`) when each of them came.
    private(set) var backgroundAllowedAtCatchUps: [Bool] = []
    private var backgroundAllowed = true
    func catchUp(with conversation: [ChatMessage]) async {
        catchUps.append(conversation)
        backgroundAllowedAtCatchUps.append(backgroundAllowed)
    }
    func allowBackgroundWork(_ allowed: Bool) async { backgroundAllowed = allowed }
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
    private(set) var shortenings = 0
    func prepareShortenedHistory(_ conversation: [ChatMessage]) async throws {
        shortenings += 1
        try await Task.sleep(for: .milliseconds(50))  // "background" preparation
    }
}

/// Every text piece becomes 0.5 s of audio.
struct FakeSynthesizer: SpeechSynthesizer {
    let outputSampleRate = 1000.0
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream { FakeStream() }
}

final class FakeStream: SynthesisStream, @unchecked Sendable {
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let continuation: AsyncThrowingStream<VoiceAudio, Error>.Continuation
    private var started = false
    private var texts = 0
    init() { (audio, continuation) = AsyncThrowingStream.makeStream() }
    func enqueue(_ text: String) {
        // Like Pocket TTS, the voice sometimes opens with a near-silent breath.
        if !started { continuation.yield(VoiceAudio([Float](repeating: 0.0001, count: 300), text: texts)) }
        started = true
        continuation.yield(VoiceAudio([Float](repeating: 0.1, count: 500), text: texts))
        texts += 1
    }
    func finish() { continuation.finish() }
    func cancel() async { continuation.finish() }
}

/// Plays in (accelerated) real time: 1 sample = 1 ms, so the assistant can be interrupted.
actor FakeSpeaker: AudioOutput {
    private(set) var played = 0
    private(set) var stops = 0
    private var busyUntil = ContinuousClock.now
    /// How long a stop takes to return once the sound is cut (a device, the iPhone's link): whoever waits for the end
    /// of the playback is released meanwhile, as with the real outputs.
    private let stopDelay: Duration
    /// Whether it says it played what it was given: false for a device whose connection keeps dropping.
    private let confirms: Bool
    init(stopDelay: Duration = .zero, confirms: Bool = true) {
        self.stopDelay = stopDelay
        self.confirms = confirms
    }
    func play(_ samples: [Float], sampleRate: Double) {
        played += samples.count
        busyUntil = max(busyUntil, .now) + .milliseconds(samples.count)
    }
    func waitUntilDone() async -> PlaybackEnd {
        while busyUntil > .now { try? await Task.sleep(for: .milliseconds(5)) }
        return confirms ? .confirmed : .unconfirmed
    }
    func stopImmediately() async {
        stops += 1
        busyUntil = .now
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
    }
    /// How long the assistant would still be talking.
    var remainingMs: Double {
        let d = busyUntil - .now
        return d < .zero ? 0 : Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

@Suite("Pipeline", .serialized)
struct PipelineTests {
    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ stt: CountingTranscriber, _ speaker: FakeSpeaker,
              tools: ToolRunner? = nil, config: PipelineConfig = .init()) -> VoicePipeline
    {
        VoicePipeline(detector: LoudnessDetector(), transcriber: stt, model: model, synthesizer: FakeSynthesizer(),
                      output: speaker, tools: tools, config: config)
    }

    @Test func longHistoryIsShortened() async throws {
        var config = PipelineConfig()
        config.historyTokenBudget = 45  // the fake model counts 10 tokens per message
        config.historyTrimTarget = 30
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker, config: config)
        try await pipeline.start()
        for turn in 1...4 {
            await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
            await waitFor { await speaker.played >= turn * 1000 }
            await waitFor { await speaker.remainingMs == 0 }  // let the answer finish, or it is an interruption
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(await model.shortenings >= 1)
        // Without shortening the 4th request would hold system + 3 exchanges + user = 8 messages.
        let last = try #require(await model.requests.last)
        #expect(last.count < 8)
        #expect(last.first?.role == .system)
    }

    @Test func answersOnceTheTurnIsOver() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played >= 1000 }
        // Two pieces: "Bonjour, je suis bien là." (too short to cut at the comma) and "Comment vas-tu ce matin ?".
        // The near-silent opening of the voice is skipped.
        #expect(await speaker.played == 1000)
        #expect(await model.requests.last?.last?.role == .user)
    }

    /// The model keeps the beginning every conversation starts with: it gets it at start, again when the tools change
    /// (then the conversation so far), and a new conversation asks for it again, which the model serves from memory.
    @Test func newConversationStartsFromTheKeptBeginning() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker, tools: ToolRunner(providers: [TimerTools()]))
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        await waitFor { await speaker.played >= 1000 }
        await waitFor { await speaker.remainingMs == 0 }
        try await Task.sleep(for: .milliseconds(150))
        try await pipeline.toolsChanged()
        try await pipeline.resetConversation()
        let prefills = await model.prefills
        #expect(prefills.map { $0.beginning } == [true, true, false, true])
        let beginning = try #require(prefills.first?.messages)
        #expect(beginning.map(\.role) == [.system])
        #expect(prefills.map { $0.messages.count } == [1, 1, 3, 1])  // the conversation so far: + the turn, its answer
        #expect(prefills[3].messages == beginning)
    }

    /// An answer in paragraphs goes into the history with the line breaks the model wrote between them; the interface
    /// gets the same pieces as the voice, without them.
    @Test func historyKeepsTheParagraphs() async throws {
        let answer = ["Bien sûr, voici une petite histoire.", "\n\nIl était une fois un chat très curieux. ",
                      "Il aimait regarder les étoiles."]
        let (model, stt, speaker) = (ScriptedModel(answer: answer), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await pipeline.submit(text: "Raconte-moi une histoire.")
        await waitFor { await speaker.played >= 1500 }
        await waitFor { await speaker.remainingMs == 0 }
        try await Task.sleep(for: .milliseconds(150))
        await pipeline.submit(text: "Merci.")
        await waitFor { await model.requests.count == 2 }
        let request = try #require(await model.requests.last)
        #expect(request.dropLast().last?.content == "Bien sûr, voici une petite histoire.\n\n"
            + "Il était une fois un chat très curieux. Il aimait regarder les étoiles.")
        #expect(await log.pieces.prefix(3) == ["Bien sûr, voici une petite histoire.",
                                              "Il était une fois un chat très curieux.", "Il aimait regarder les étoiles."])
        #expect(await model.catchUps.first == Array(request.dropLast()))  // once the answer was recorded
    }

    /// What the model never wrote (an announcement once said) it computes in the background, only while nobody speaks:
    /// each recorded exchange reaches it once it knows whether someone does. Here an announcement waits for the end of
    /// an answer: the answer's exchange reaches the model as the announcement starts (no background work then), the
    /// announcement's own once it is over and nobody speaks.
    @Test func modelCatchesUpOnceItKnowsWhetherSomeoneSpeaks() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        await waitFor { await speaker.played > 0 }
        await pipeline.announce("Ton minuteur de 10 minutes est terminé.", note: "(Le minuteur a sonné.)",
                                language: .french)
        await waitFor { await model.catchUps.count == 2 }  // the answer (1 s), then the chime and the announcement
        let histories = await model.catchUps
        #expect(histories.map { $0.filter { $0.role == .user }.count } == [1, 2])
        #expect(histories.last?.last?.content == "Ton minuteur de 10 minutes est terminé.")
        #expect(await model.backgroundAllowedAtCatchUps == [false, true])
    }

    @Test func speculativeAnswerIsDroppedWhenTheUserGoesOn() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        try await pipeline.start()
        // Speech, a 256 ms pause (speculative start), more speech, then the real end of turn.
        await push(pipeline, "1111111111" + "00000000")
        try await Task.sleep(for: .milliseconds(100))  // let the speculative answer get going
        #expect(await speaker.played == 0)  // nothing is played before the end of the turn
        await push(pipeline, "11111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played >= 1000 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 1000)  // only the final answer was spoken
        let lastCall = try #require(await stt.calls.last)
        #expect(lastCall > 15 * 512)  // the final transcription covers the whole utterance
    }

    @Test func userCanInterruptTheAssistant() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let (model, stt, speaker) = (ScriptedModel(answer: long), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let bargeIns = Task { () -> Int in
            var n = 0
            for await event in pipeline.events {
                if case .bargeIn = event { n += 1; break }
            }
            return n
        }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        await push(pipeline, "11111111")  // the user talks over the assistant (≥ 224 ms, loud)
        #expect(await bargeIns.value == 1)
        #expect(await speaker.stops >= 1)
        #expect(await speaker.remainingMs < 50)  // ~10 s of answer were left: the voice was cut
        // While the user speaks, the model catches up with the history, which keeps the answer as it went to the voice,
        // without any mark of the cut in its words, then a note of its own: background work is not allowed then (the
        // user speaks), so the model computes that history at once (`MLXChatModel.catchUp`).
        await waitFor { await !model.catchUps.isEmpty }
        let history = try #require(await model.catchUps.last)
        #expect(history.last == Conversation.cutOffMessage)
        let answer = history.dropLast().last
        #expect(answer?.role == .assistant && answer?.content.hasPrefix("Phrase numéro 1 de la réponse.") == true)
        #expect(answer?.content.contains("[…]") == false)
        #expect(await model.backgroundAllowedAtCatchUps.last == false)
    }

    /// The model has written the whole answer, the voice is still saying it, and the user talks over it. Stopping the
    /// voice takes a moment, during which the answer's own wait for the end of the playback returns: the answer must
    /// not be taken for one said to its end. The exchange goes into the history once, cut off, and only the
    /// interrupted turn is reported.
    @Test func bargeInAtTheEndOfAnAnswerRecordsTheExchangeOnce() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let (model, stt, speaker) = (ScriptedModel(answer: long), CountingTranscriber(),
                                     FakeSpeaker(stopDelay: .milliseconds(40)))
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        try await Task.sleep(for: .milliseconds(300))  // the model has written everything, the voice queued it all
        #expect(await speaker.remainingMs > 5000)
        await push(pipeline, "11111111" + String(repeating: "0", count: 20))  // the user talks over it, then stops
        await waitFor { await model.requests.count == 2 }
        let request = try #require(await model.requests.last)
        #expect(request.map(\.role) == [.system, .user, .assistant, .system, .user])
        // The whole answer, as the model wrote it; a note of its own says it was cut off.
        #expect(request[2].content == long.joined().trimmingCharacters(in: .whitespaces))
        #expect(request[3] == Conversation.cutOffMessage)
        #expect(!request[4].content.contains(Conversation.cutOffNote))
        try await Task.sleep(for: .milliseconds(100))
        let reported = await log.finished.map(\.interrupted)
        #expect(reported == [true])
    }

    /// The user talks over the answer while the model is in the middle of a sentence: the model stops, and what it
    /// had written of that sentence is neither said nor kept; the history holds what went to the voice, cut off.
    @Test func bargeInWhileTheModelWritesKeepsWhatWentToTheVoice() async throws {
        let answer = ["Voici la première phrase de la réponse. ", "Et voici la deuxième qui ", "ne finit jamais."]
        let (model, stt, speaker) = (ScriptedModel(answer: answer, pauseAfter: 2), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        try await Task.sleep(for: .milliseconds(50))  // the model is stuck in the middle of the second sentence
        await push(pipeline, "11111111")  // the user talks over the first one
        await waitFor { await !model.catchUps.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await speaker.played == 500)  // the first sentence only
        let history = try #require(await model.catchUps.last)
        #expect(history.suffix(2).map(\.role) == [.assistant, .system])
        #expect(history.dropLast().last?.content == "Voici la première phrase de la réponse.")
        #expect(history.last == Conversation.cutOffMessage)
    }

    /// After an answer cut off, a note of its own tells the model (`Conversation.cutOffMessage`), before the user's next
    /// message, which stays their words; the answer itself holds no mark of the cut, which the model copied into its own
    /// answers. Nothing of the kind follows an answer heard to its end.
    @Test func aNoteFollowsAnAnswerCutOff() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let model = ScriptedModel(scripts: [long.map { .text($0) }, [.text("Oui, je t'écoute avec plaisir.")]])
        let (stt, speaker) = (CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        await push(pipeline, "11111111" + String(repeating: "0", count: 20))  // the user talks over it, then stops
        await waitFor { await model.requests.count == 2 }
        let request = try #require(await model.requests.last)
        #expect(request.map(\.role) == [.system, .user, .assistant, .system, .user])
        #expect(request[2].content.hasPrefix("Phrase numéro 1 de la réponse."))
        #expect(!request[2].content.contains("[…]"))
        #expect(request[3] == Conversation.cutOffMessage)
        #expect(request[4].content.hasPrefix("phrase de "))  // the user's words alone
        #expect(!request[4].content.contains(Conversation.cutOffNote))
        // The model had the note before the user's message: it caught up with it while they spoke.
        #expect(await model.catchUps.first == Array(request.dropLast()))
        await waitFor { await log.finished.count == 2 }  // the answer cut off, then this one, heard to its end
        #expect(await log.finished.map(\.interrupted) == [true, false])
        await pipeline.submit(text: "Merci.")
        await waitFor { await model.requests.count == 3 }
        let next = try #require(await model.requests.last)
        #expect(Array(next.prefix(5)) == request)  // kept as the model read it
        #expect(next.map(\.role) == [.system, .user, .assistant, .system, .user, .assistant, .user])  // no note
        #expect(next.last?.content == "Merci.")
    }

    /// On a tier that keeps the note after the user's words (E4B, E2B: `Conversation.cutOffPlacement(on:)`): nothing
    /// follows the answer cut off, and the user's next message says it, after their words; it stays in the history so.
    /// The message after an answer heard to its end says nothing of the kind.
    @Test func afterTheUsersWordsTheMessageAfterAnAnswerCutOffSaysSo() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let model = ScriptedModel(scripts: [long.map { .text($0) }, [.text("Oui, je t'écoute avec plaisir.")]])
        let (stt, speaker) = (CountingTranscriber(), FakeSpeaker())
        var config = PipelineConfig()
        config.cutOffPlacement = .afterUserWords
        let pipeline = make(model, stt, speaker, config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        await push(pipeline, "11111111" + String(repeating: "0", count: 20))  // the user talks over it, then stops
        await waitFor { await model.requests.count == 2 }
        let request = try #require(await model.requests.last)
        #expect(request.map(\.role) == [.system, .user, .assistant, .user])
        #expect(request[2].content.hasPrefix("Phrase numéro 1 de la réponse."))
        #expect(!request[2].content.contains("[…]"))
        #expect(request[3].content.hasPrefix("phrase de "))  // the user's words first
        #expect(request[3].content.hasSuffix("\n" + Conversation.cutOffNote))
        // While the user spoke, the model caught up with the answer cut off, the last message of the history.
        await waitFor { await !model.catchUps.isEmpty }
        #expect(await model.catchUps.first == Array(request.dropLast()))
        await waitFor { await log.finished.count == 2 }  // the answer cut off, then this one, heard to its end
        #expect(await log.finished.map(\.interrupted) == [true, false])
        await pipeline.submit(text: "Merci.")
        await waitFor { await model.requests.count == 3 }
        let next = try #require(await model.requests.last)
        #expect(Array(next.prefix(4)) == request)  // kept as the model read it
        #expect(next.last?.content == "Merci.")  // no note
    }

    @Test func quietEchoDoesNotInterruptTheAssistant() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let (model, stt, speaker) = (ScriptedModel(answer: long), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        // What echo cancellation leaves of the assistant's voice: speech-like, but very quiet (≈ −54 dB).
        let echo = [Float](repeating: 0, count: 511) + [0.06]
        for _ in 0..<12 { await pipeline.push(echo) }
        try await Task.sleep(for: .milliseconds(200))  // the whole answer is queued by now
        #expect(await speaker.stops == 0)
        #expect(await speaker.remainingMs > 1000)
    }

    @Test func speculativeAnswerStaysHiddenUntilTheTurnIsOver() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + "00000000")  // pause: the answer is prepared speculatively
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.pieces.isEmpty)  // the interface must not show an answer that may be dropped
        await push(pipeline, String(repeating: "0", count: 12))  // the turn is really over
        await waitFor { await speaker.played >= 1000 }
        await waitFor { await log.pieces.count >= 2 }  // the recorder reads the events on its own task
        #expect(await log.pieces.count == 2)
        #expect(await log.order.first == "user")  // the user's words come before the answer
    }

    @Test func stopCommandSilencesTheAssistant() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let (model, stt, speaker) = (ScriptedModel(answer: long), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))
        await waitFor { await speaker.played > 0 }
        await pipeline.interrupt()
        #expect(await speaker.remainingMs < 50)
        await waitFor { await log.states.last == .listening }
        #expect(await log.states.last == .listening)
    }

    @Test func talkKeyDecidesTheTurnInHandsFreeMode() async throws {
        var config = PipelineConfig()
        config.partialTranscriptSeconds = nil  // only the turn's transcription (the words shown: PartialTranscriptTests)
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker, config: config)  // hands-free
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await pipeline.setTalkKey(pressed: true)  // the global shortcut
        await waitFor { await log.states.last == .userSpeaking }
        #expect(await log.states.last == .userSpeaking)
        // Speech, then a silence that would end a hands-free turn, then more speech: the key keeps the turn open.
        await push(pipeline, "1111111111" + String(repeating: "0", count: 30) + "11111")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stt.calls.isEmpty)
        #expect(await speaker.played == 0)
        await pipeline.setTalkKey(pressed: false)
        await waitFor { await speaker.played >= 1000 }
        #expect(await speaker.played == 1000)
        #expect(await stt.calls == [45 * 512])  // everything heard while the key was down, once
        await waitFor { await log.states.last == .listening }
        #expect(await log.states.last == .listening)
    }

    @Test func talkKeyReleasedWithoutSoundGoesBackToRest() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await pipeline.setTalkKey(pressed: true)
        await pipeline.setTalkKey(pressed: false)  // pressed twice at once: no audio came in between
        await waitFor { await log.states.last == .listening }
        #expect(await log.states.last == .listening)
        #expect(await stt.calls.isEmpty)
    }

    @Test func pushToTalkDropsASentenceHalfHeardHandsFree() async throws {
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        await push(pipeline, "11111111")  // the user starts a sentence…
        await waitFor { await log.states.last == .userSpeaking }
        await pipeline.setListening(.pushToTalk)  // …and the window is closed: only the talk key counts now
        await waitFor { await log.states.last == .listening }
        #expect(await log.states.last == .listening)
        await push(pipeline, String(repeating: "0", count: 30) + "1111111111" + String(repeating: "0", count: 30))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await stt.calls.isEmpty)
        #expect(await speaker.played == 0)
    }

    /// The models are kept warm as soon as the pipeline starts, not only once a first turn is over: until then, the
    /// first request after loading found them pushed out of memory.
    @Test func modelsAreKeptWarmFromTheStart() async throws {
        var config = PipelineConfig()
        config.keepWarmSeconds = 0.05
        let model = WarmCountingModel()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: FakeSpeaker(), config: config)
        try await pipeline.start()
        await waitFor { await model.warmPasses >= 2 }
        #expect(await model.warmPasses >= 2)
        await pipeline.stop()
    }

    /// The models are woken up (`KeepsWarm.wakeUp`) when the pipeline starts, then as soon as someone starts to speak,
    /// before any request: what macOS pushed out of memory comes back while they speak.
    @Test func modelsWakeUpWhenSpeechStarts() async throws {
        let model = WarmCountingModel()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: FakeSynthesizer(), output: FakeSpeaker())
        try await pipeline.start()
        await waitFor { await model.wakeUps >= 1 }
        await push(pipeline, "0000")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await model.wakeUps == 1)
        await push(pipeline, "1111111111")
        await waitFor { await model.wakeUps >= 2 }
        #expect(await model.wakeUps == 2)
        #expect(await model.requests == 0)  // still speaking: no request yet
        await pipeline.stop()
    }
}

/// A model that only counts the pipeline's keep-warm passes, wake-ups and requests.
actor WarmCountingModel: LanguageModel, KeepsWarm {
    private(set) var warmPasses = 0
    private(set) var wakeUps = 0
    private(set) var requests = 0
    nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        Task { await self.countRequest() }
        return AsyncThrowingStream { $0.finish() }
    }
    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { 0 }
    func keepWarm() async { warmPasses += 1 }
    nonisolated func wakeUp() { Task { await self.countWakeUp() } }
    private func countWakeUp() { wakeUps += 1 }
    private func countRequest() { requests += 1 }
}

actor EventRecorder {
    private(set) var pieces: [String] = []
    private(set) var states: [PipelineState] = []
    /// "user" / "assistant", in the order the interface would display them.
    private(set) var order: [String] = []
    private(set) var awake: [Bool] = []
    private(set) var wakeDecisions: [WakeDecision] = []
    private(set) var bargeIns = 0
    /// The turns reported over, completed or interrupted.
    private(set) var finished: [TurnMetrics] = []
    /// Each new conversation reported (`conversationCleared`): how many pieces and states had come before it.
    private(set) var clears: [Moment] = []
    struct Moment: Equatable {
        var pieces: Int
        var states: Int
    }
    /// What an interface's transcript is made of, in order, written short: "state listening", "user Bonjour",
    /// "piece Bonjour !", and "cleared" for each new conversation reported.
    private(set) var timeline: [String] = []

    func record(_ event: PipelineEvent) {
        switch event {
        case .state(let state): timeline.append("state \(state.rawValue)")
        case .userTranscript(let text, _): timeline.append("user \(text)")
        case .assistantPiece(let piece): timeline.append("piece \(piece)")
        case .conversationCleared: timeline.append("cleared")
        default: break
        }
        switch event {
        case .conversationCleared: clears.append(Moment(pieces: pieces.count, states: states.count))
        case .turnFinished(let metrics): finished.append(metrics)
        case .assistantPiece(let piece):
            pieces.append(piece)
            order.append("assistant")
        case .userTranscript: order.append("user")
        case .state(let state): states.append(state)
        case .awake(let isAwake): awake.append(isAwake)
        case .wakeDecision(let decision): wakeDecisions.append(decision)
        case .bargeIn: bargeIns += 1
        default: break
        }
    }
}

// MARK: - Wake word

/// Each test sentence is "said" at its own loudness: the transcript is the sentences heard, in order.
actor LevelTranscriber: Transcriber {
    static let sentences: [Int: String] = [
        2: "Le gouvernement a présenté hier son projet de loi.",  // the TV
        3: "Ok Mae, quelle heure est-il ?",
        4: "Ok Mae.",
        5: "Et demain ?",
        6: "Ok Mae, stop.",
        7: "Dis-moi l'heure.",
        8: "Cookie May",  // « OK Maé » alone, misheard
        9: "Quelle heure est-il ?",
    ]
    private(set) var calls = 0
    /// How long each transcription after the first takes: a speech recognition that lags behind the microphone.
    private let laterCallsTake: Duration
    init(laterCallsTake: Duration = .zero) { self.laterCallsTake = laterCallsTake }

    func transcribe(_ samples: [Float]) async throws -> String {
        calls += 1
        if calls > 1, laterCallsTake > .zero { try await Task.sleep(for: laterCallsTake) }
        var levels: [Int] = []
        for sample in samples where abs(sample) > 0.05 {
            let level = Int((abs(sample) * 10).rounded())
            if levels.last != level { levels.append(level) }
        }
        // With what follows, the phrase is heard right.
        if levels == [8, 9] { return "Ok Mae, quelle heure est-il ?" }
        return levels.compactMap { Self.sentences[$0] }.joined(separator: " ")
    }
}

/// A detector that hears « OK Maé » in the sound itself: in any chunk at the loudness of sentence 7.
struct HearingWakeWord: WakeWordDetector {
    func hears(_ chunk: [Float]) async -> Bool { chunk.contains { abs(abs($0) - 0.7) < 0.01 } }
    func request(in transcript: String) -> String? { OKMaeWakeWord().request(in: transcript) }
}

@Suite("Wake-word pipeline", .serialized)
struct WakeWordPipelineTests {
    let silence = [Float](repeating: 0, count: 512)

    /// Sentence `level` for 10 chunks (320 ms), then the silence that ends the turn.
    func say(_ pipeline: VoicePipeline, _ level: Int, silenceAfter: Int = 24) async {
        let speech = [Float](repeating: Float(level) / 10, count: 512)
        for _ in 0..<10 { await pipeline.push(speech) }
        for _ in 0..<silenceAfter { await pipeline.push(silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func make(_ model: ScriptedModel, _ speaker: FakeSpeaker, followUp: Double = 8,
              wakeWord: any WakeWordDetector = OKMaeWakeWord(),
              transcriber: LevelTranscriber = LevelTranscriber()) -> (VoicePipeline, EventRecorder)
    {
        var config = PipelineConfig()
        config.listening = .wakeWord
        config.wakeFollowUpSeconds = followUp
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: transcriber, model: model,
                                     synthesizer: FakeSynthesizer(), output: speaker, wakeWord: wakeWord, config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        return (pipeline, log)
    }

    @Test func speechWithoutThePhraseChangesNothing() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 2)  // the TV
        await waitFor { await !log.wakeDecisions.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.states == [.listening])  // the screen stayed at rest
        #expect(await model.requests.isEmpty)
        #expect(await speaker.played == 0)
        let decision = try #require(await log.wakeDecisions.first)
        #expect(!decision.accepted && decision.moment == .asleep && decision.heard.hasPrefix("Le gouvernement"))
    }

    @Test func thePhraseWakesMaeAndIsNotPartOfTheRequest() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 3, silenceAfter: 8)  // "Ok Mae, quelle heure est-il ?", then a pause: it is checked
        await waitFor { await log.states.last == .userSpeaking }
        #expect(await log.states == [.listening, .userSpeaking])  // Maé shows she heard, before the end of the turn
        for _ in 0..<16 { await pipeline.push(silence) }
        await waitFor { await speaker.played >= 1000 }
        #expect(await model.requests.last?.last?.content == "Quelle heure est-il ?")
        await waitFor { await log.awake == [true] }  // after the answer: a few seconds of attention
        #expect(await log.awake == [true])
        // The recorder reads the events on its own task, in order: the states of the answer are in by now.
        #expect(await log.states.starts(with: [.listening, .userSpeaking, .thinking]))
        #expect(await log.wakeDecisions.map(\.accepted) == [true])
    }

    @Test func thePhraseAloneChimesThenTheNextSentenceIsTheRequest() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 4)  // "Ok Mae."
        await waitFor { await log.awake == [true] }
        #expect(await log.awake == [true])
        // The chime plays from a task of its own, and the state at rest comes after the awake event.
        let chime = Chime.samples(sampleRate: 1000).count
        await waitFor { await speaker.played == chime }
        #expect(await speaker.played == chime)
        await waitFor { await log.states.last == .listening }
        #expect(await model.requests.isEmpty)
        let states = await log.states
        #expect(states.last == .listening && !states.contains(.thinking))
        await say(pipeline, 5)  // "Et demain ?"
        await waitFor { await model.requests.count == 1 }
        #expect(await model.requests.last?.last?.content == "Et demain ?")
    }

    /// The check reads the phrase alone (or « OK Maé, stop ») at the pause, and the sentence ends before the speech
    /// recognition would have read it again: Maé knows from the check that it asks for no answer, and the end of the
    /// sentence shows no "thinking".
    @Test(arguments: [4, 6]) func aSentenceThatAsksForNoAnswerShowsNoThinking(level: Int) async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker, transcriber: LevelTranscriber(laterCallsTake: .milliseconds(300)))
        try await pipeline.start()
        await say(pipeline, level, silenceAfter: 8)  // a pause: the sentence is checked
        await waitFor { await log.states.last == .userSpeaking }
        for _ in 0..<16 { await pipeline.push(silence) }  // the end of the sentence, at once
        await waitFor { await log.states.last == .listening }
        let states = await log.states
        #expect(states == [.listening, .userSpeaking, .listening])
        #expect(await log.awake == (level == 4 ? [true] : []))  // the phrase alone wakes her, « stop » does not
        #expect(await model.requests.isEmpty)
    }

    @Test func noPhraseIsNeededForAFewSecondsAfterAnAnswer() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker, followUp: 30)  // the few seconds do not run out on a busy Mac
        try await pipeline.start()
        await say(pipeline, 3)
        await waitFor { await log.awake == [true] }
        await say(pipeline, 5)  // "Et demain ?", without the phrase
        await waitFor { await model.requests.count == 2 }
        #expect(await model.requests.last?.last?.content == "Et demain ?")
        // The decision reaches the recorder through the events, on its own task.
        await waitFor { await log.wakeDecisions.count >= 2 }
        let decisions = await log.wakeDecisions
        #expect(decisions.count == 2)
        let decision = try #require(decisions.last)
        #expect(decision.moment == .awake && decision.accepted && decision.heard == "Et demain ?")
    }

    @Test func maeFallsAsleepAfterTheFewSeconds() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker, followUp: 0.3)
        try await pipeline.start()
        await say(pipeline, 3)
        await waitFor { await log.awake == [true, false] }
        #expect(await log.awake == [true, false])
        await say(pipeline, 5)  // "Et demain ?": the phrase is needed again
        await waitFor { await log.wakeDecisions.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await model.requests.count == 1)
        #expect(await log.wakeDecisions.last?.accepted == false)
    }

    @Test func onlyThePhraseInterruptsMae() async throws {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let (model, speaker) = (ScriptedModel(answer: long), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 3)
        await waitFor { await speaker.played > 0 }
        await say(pipeline, 2)  // the TV talks over her
        await waitFor { await log.wakeDecisions.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await speaker.stops == 0)
        #expect(await speaker.remainingMs > 1000)
        #expect(await log.wakeDecisions.last.map { !$0.accepted && $0.moment == .busy } == true)
        await say(pipeline, 6)  // "Ok Mae, stop."
        await waitFor { await speaker.stops > 0 }
        await waitFor { await log.states.last == .listening }
        #expect(await speaker.remainingMs < 50)
        #expect(await log.bargeIns == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await model.requests.count == 1)  // "stop" only silences her
    }

    @Test func theTalkKeyNeedsNoPhrase() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, _) = make(model, speaker)
        try await pipeline.start()
        await pipeline.setTalkKey(pressed: true)
        await say(pipeline, 5, silenceAfter: 4)
        await pipeline.setTalkKey(pressed: false)
        await waitFor { await model.requests.count == 1 }
        #expect(await model.requests.last?.last?.content == "Et demain ?")
    }

    @Test func aPhraseMisheardAtThePauseIsCheckedAgainWithTheRest() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 8, silenceAfter: 8)  // « OK Maé », a pause: heard as "Cookie May"
        await waitFor { await log.wakeDecisions.count == 1 }
        await say(pipeline, 9)  // "quelle heure est-il ?": the whole sentence is read again
        await waitFor { await model.requests.count == 1 }
        #expect(await model.requests.last?.last?.content == "Quelle heure est-il ?")
    }

    @Test func aDetectorThatHearsThePhraseWakesMae() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, _) = make(model, speaker, wakeWord: HearingWakeWord())
        try await pipeline.start()
        await say(pipeline, 7)  // "Dis-moi l'heure.": heard in the sound, not written
        await waitFor { await model.requests.count == 1 }
        #expect(await model.requests.last?.last?.content == "Dis-moi l'heure.")
    }
}
