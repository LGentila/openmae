import Foundation
import Testing

@testable import VoiceCore

/// The voice's output goes out of reach (the iPhone that has the conversation lost its connection) while Maé answers or
/// while the user speaks: what becomes of the answer, of the user's sentence, and of the history.
@Suite("What the device out of reach did not hear", .serialized)
struct OutOfReachTests {
    static let sentences = ["Voici la première phrase de la réponse.", "Voici la deuxième phrase de la réponse.",
                            "Voici la troisième phrase de la réponse."]
    static let answer = sentences.joined(separator: " ")

    let speech = [Float](repeating: 0.5, count: 512)
    let silence = [Float](repeating: 0, count: 512)

    func push(_ pipeline: VoicePipeline, _ pattern: String) async {
        for c in pattern { await pipeline.push(c == "1" ? speech : silence) }
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// What the history holds of what Maé said, in order.
    func recorded(_ model: ScriptedModel) async -> [String] {
        (await model.catchUps.last ?? []).filter { $0.role == .assistant }.map(\.content)
    }

    func make(_ model: ScriptedModel, _ speaker: FakeSpeaker, _ voice: any SpeechSynthesizer = FakeSynthesizer(),
              stt: CountingTranscriber = CountingTranscriber(), config: PipelineConfig = .init())
        -> (VoicePipeline, EventRecorder)
    {
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: stt, model: model, synthesizer: voice,
                                     output: speaker, config: config)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        return (pipeline, log)
    }

    /// The first sentence reached the device, the second and third went out after: once it is back they are said
    /// again, and the history holds the answer once, whole.
    @Test func anAnswerIsSaidAgainFromTheFirstSentenceNotHeard() async throws {
        let (model, speaker, voice) = (ScriptedModel(answer: Self.sentences.map { $0 + " " }), FakeSpeaker(), HeldVoice())
        let (pipeline, log) = make(model, speaker, voice)
        try await pipeline.start()
        await pipeline.submit(text: "Raconte-moi quelque chose.")
        await waitFor { await speaker.played == 500 }
        let reached = ContinuousClock.now  // what went out before this reached the device
        voice.release()
        await waitFor { await speaker.played == 1500 }
        await pipeline.setOutputReachable(false, reachedUntil: reached)
        await waitFor { await log.finished.count == 1 }
        #expect(await log.finished.map(\.interrupted) == [true])  // the attempt shown, cut off
        #expect(await model.catchUps.isEmpty)  // nothing recorded while it waits
        await pipeline.setOutputReachable(true)
        await waitFor { await recorded(model) == [Self.answer] }
        #expect(await recorded(model) == [Self.answer])
        #expect(await speaker.played == 2500)  // the second and third sentences, again
        await waitFor { await log.finished.count >= 2 }  // the recorder reads the events on its own task
        #expect(await log.pieces == Self.sentences + Self.sentences.suffix(2))
        #expect(await log.finished.map(\.interrupted) == [true, false])
        #expect(await model.requests.count == 1)
    }

    /// All of the answer went out before the device was last heard: it plays it from what it has, nothing is said again.
    @Test func anAnswerThatWentOutWholeIsNotSaidAgain() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        await waitFor { await speaker.played == 1000 }
        try await Task.sleep(for: .milliseconds(50))
        await pipeline.setOutputReachable(false, reachedUntil: .now)
        await pipeline.setOutputReachable(true)
        await waitFor { await recorded(model) == ["Bonjour, je suis bien là. Comment vas-tu ce matin ?"] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await speaker.played == 1000)
        #expect(await log.finished.map(\.interrupted) == [false])
    }

    /// Back too late: nothing is said again, and the history keeps what was heard, cut off.
    @Test func anAnswerIsGivenUpAfterThePatience() async throws {
        var config = PipelineConfig()
        config.outOfReachPatienceSeconds = 0.2
        let (model, speaker, voice) = (ScriptedModel(answer: Self.sentences.map { $0 + " " }), FakeSpeaker(), HeldVoice())
        let (pipeline, _) = make(model, speaker, voice, config: config)
        try await pipeline.start()
        await pipeline.submit(text: "Raconte-moi quelque chose.")
        await waitFor { await speaker.played == 500 }
        let reached = ContinuousClock.now
        voice.release()
        await waitFor { await speaker.played == 1500 }
        await pipeline.setOutputReachable(false, reachedUntil: reached)
        await waitFor { await recorded(model) == [Self.sentences[0]] }
        #expect(await recorded(model) == [Self.sentences[0]])
        await pipeline.setOutputReachable(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await speaker.played == 1500)
        // Cut off: a note says so, before the next message.
        await pipeline.submit(text: "Et alors ?")
        await waitFor { await model.requests.count == 2 }
        #expect(await model.requests.last?.suffix(2) == [Conversation.cutOffMessage, ChatMessage(.user, "Et alors ?")])
    }

    /// The voice was still on its first sentence (the rest not out yet) when the device was last heard: that sentence may
    /// not have been heard whole, the answer is said again from it.
    @Test func anAnswerStillOnItsFirstSentenceIsSaidAgainWhole() async throws {
        let (model, speaker, voice) = (ScriptedModel(answer: Self.sentences.map { $0 + " " }), FakeSpeaker(), HeldVoice())
        let (pipeline, _) = make(model, speaker, voice)
        try await pipeline.start()
        await pipeline.submit(text: "Raconte-moi quelque chose.")
        await waitFor { await speaker.played == 500 }
        await pipeline.setOutputReachable(false, reachedUntil: .now)
        voice.release()  // too late: its voice stopped
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 500)
        await pipeline.setOutputReachable(true)
        await waitFor { await recorded(model) == [Self.answer] }
        #expect(await speaker.played == 2000)  // the three sentences
    }

    /// The conversation goes on before the device is back (a typed turn): the cut answer goes into the history as it
    /// was heard, before the new turn.
    @Test func theConversationGoesOnWithoutIt() async throws {
        let (model, speaker, voice) = (ScriptedModel(answer: Self.sentences.map { $0 + " " }), FakeSpeaker(), HeldVoice())
        let (pipeline, log) = make(model, speaker, voice)
        try await pipeline.start()
        await pipeline.submit(text: "Raconte-moi quelque chose.")
        await waitFor { await speaker.played == 500 }
        let reached = ContinuousClock.now
        voice.release()
        await waitFor { await speaker.played == 1500 }
        await pipeline.setOutputReachable(false, reachedUntil: reached)
        await waitFor { await log.finished.count == 1 }
        await pipeline.voiceOutputChanged()  // the Mac takes the sound back
        await pipeline.setOutputReachable(true)
        await waitFor { await recorded(model) == [Self.sentences[0]] }
        #expect(await recorded(model) == [Self.sentences[0]])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await speaker.played == 1500)  // not said on the other device
        await pipeline.submit(text: "Autre chose.")
        await waitFor { await model.requests.count == 2 }
        let request = try #require(await model.requests.last)
        #expect(request.map(\.role) == [.system, .user, .assistant, .system, .user])
        #expect(request[2].content == Self.sentences[0])  // what was heard, cut off: a note says so
        #expect(request[3] == Conversation.cutOffMessage)
        #expect(request[4].content == "Autre chose.")
    }

    /// The user is speaking when the device goes out of reach: the sentence is not answered (nor transcribed), what the
    /// microphone still gives meanwhile is not listened to, and once the device is back Maé asks for the sentence again.
    /// The user's next sentence is answered as usual.
    @Test func aSentenceCutIsNotAnsweredTheUserIsAskedToSayItAgain() async throws {
        let (model, speaker, stt) = (ScriptedModel(), FakeSpeaker(), CountingTranscriber())
        let (pipeline, log) = make(model, speaker, stt: stt)
        try await pipeline.start()
        await push(pipeline, "11111111")
        await waitFor { await log.states.last == .userSpeaking }
        await pipeline.setOutputReachable(false)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))  // not listened to
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stt.calls.isEmpty)
        #expect(await speaker.played == 0)
        await pipeline.setOutputReachable(true)
        await waitFor { await speaker.played == 500 }
        await waitFor { await !log.pieces.isEmpty }  // the recorder reads the events on its own task
        #expect(await log.pieces == [OutOfReachPhrases.sentenceCut(.french)])
        #expect(await model.requests.isEmpty)
        await waitFor { await log.states.last == .listening }
        await push(pipeline, "1111111111" + String(repeating: "0", count: 20))  // said again
        await waitFor { await model.requests.count == 1 }
        #expect(await stt.calls.count == 1)
        let request = try #require(await model.requests.last)
        #expect(request.map(\.role) == [.system, .user])  // the request to repeat is not in the history
    }

    /// Nobody was speaking: nothing is asked when the device is back.
    @Test func nothingIsAskedWhenNobodySpoke() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await pipeline.setOutputReachable(false)
        await pipeline.setOutputReachable(true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await speaker.played == 0)
        #expect(await log.pieces.isEmpty)
    }

    @Test func thePhraseFollowsTheTypography() {
        #expect(OutOfReachPhrases.sentenceCut(.french) == "Ta phrase a été coupée, tu peux répéter\u{00A0}?")
        #expect(OutOfReachPhrases.sentenceCut(.french).split(separator: " ").count >= 5)
        #expect(OutOfReachPhrases.sentenceCut(.english) == "Your sentence was cut off. Can you say it again?")
    }
}

/// `FakeSynthesizer`, whose first utterance says its first text at once and holds the others until `release()`: an
/// answer whose voice is still on its way. The next utterances speak at once.
final class HeldVoice: SpeechSynthesizer, @unchecked Sendable {
    let outputSampleRate = 1000.0
    private let lock = NSLock()
    private var first: HeldStream?

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        lock.withLock {
            guard first == nil else { return FakeStream() }
            let stream = HeldStream()
            first = stream
            return stream
        }
    }

    func release() { lock.withLock { first }?.release() }
}

final class HeldStream: SynthesisStream, @unchecked Sendable {
    private let voice = FakeStream()
    private let lock = NSLock()
    private var given = 0
    /// What came after the first text, until released; nil once released.
    private var held: [String]? = []
    private var finishing = false

    var audio: AsyncThrowingStream<VoiceAudio, Error> { voice.audio }

    func enqueue(_ text: String) {
        let passes: Bool = lock.withLock {
            given += 1
            guard given > 1, held != nil else { return true }
            held?.append(text)
            return false
        }
        if passes { voice.enqueue(text) }
    }

    func finish() {
        let passes: Bool = lock.withLock {
            finishing = true
            return held == nil
        }
        if passes { voice.finish() }
    }

    func cancel() async { await voice.cancel() }

    func release() {
        let (texts, finishing): ([String], Bool) = lock.withLock {
            defer { held = nil }
            return (held ?? [], self.finishing)
        }
        texts.forEach(voice.enqueue)
        if finishing { voice.finish() }
    }
}
