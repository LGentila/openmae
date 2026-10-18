import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// The connection of the iPhone that has the conversation drops (Wi-Fi off, a tunnel) while Maé answers, or while the
/// user speaks. Once it is back: the answer is said again from the sentence that was cut, and the history holds it once;
/// a sentence of the user's that the drop cut is not answered, Maé asks them to say it again. A LinkHost in front of the
/// real conversation logic (`VoicePipeline`, on stages without models), the iPhone's sessions over memory (the rig of
/// HeldAnnouncementTests).
@Suite("What the iPhone did not hear while its connection dropped", .serialized)
struct CutByADropTests {
    static let first = "Voici la première phrase de la réponse."
    static let second = "Voici la deuxième phrase de la réponse."
    static let third = "Voici la troisième phrase de la réponse."
    static let answer = [first, second, third].joined(separator: " ")
    /// The frames of one sentence of `ToneVoice`.
    static let sentenceFrames = ToneStream.pieceSamples / 480

    // MARK: An answer cut

    /// Wi-Fi off once the first sentence reached the iPhone, while the other two go into the dead connection. It comes
    /// back through the relay within the patience: it hears the second and the third sentences, once each, and the
    /// history holds the answer once, whole.
    @Test func anAnswerCutIsSaidAgainFromTheSentenceCut() async throws {
        let (voice, model) = (StepVoice(), Notebook(answer: Self.answer))
        let rig = try await Rig(model: model, voice: voice)
        let first = try await answerUntilTheDrop(rig, voice) { first in first.wire.cut() }
        #expect(rig.engine.said.isEmpty)
        #expect(await model.recorded.isEmpty)  // not yet: it is not over
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [2 * Self.sentenceFrames])  // the second and third sentences
        await waitFor { rig.engine.said == [Self.answer] }
        #expect(rig.engine.said == [Self.answer])
        #expect(rig.engine.cutOff == [Self.answer])  // the attempt the screens showed, cut off
        await waitFor { await model.recorded == [Self.answer] }
        #expect(await model.recorded == [Self.answer])  // once, whole
        #expect(first.phone.framesHeard == Self.sentenceFrames)
        #expect(rig.engine.reachability == [false, true])
        #expect(rig.engine.localPlayed == 0)
        #expect(await model.requests == 1)  // said again, not asked again
        await rig.end()
    }

    /// The same when the Mac sees the session close (the iPhone could say so): the iPhone is out of reach at once. The
    /// second and third sentences went out just before, when what is sent may still be on its way: they are said again.
    @Test func anAnswerCutWhenTheSessionClosesIsSaidAgainToo() async throws {
        let (voice, model) = (StepVoice(), Notebook(answer: Self.answer))
        let rig = try await Rig(model: model, voice: voice)
        _ = try await answerUntilTheDrop(rig, voice, releaseFirst: true) { first in first.wire.close() }
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [2 * Self.sentenceFrames])
        await waitFor { await model.recorded == [Self.answer] }
        #expect(await model.recorded == [Self.answer])
        #expect(rig.engine.said == [Self.answer])
        await rig.end()
    }

    /// It comes back after the patience: the rest of an old answer is not said, and the history keeps what was heard of
    /// it, cut off.
    @Test func anAnswerCutIsDroppedWhenTheIPhoneComesBackTooLate() async throws {
        var config = PipelineConfig()
        config.outOfReachPatienceSeconds = 0.5
        let (voice, model) = (StepVoice(), Notebook(answer: Self.answer))
        let rig = try await Rig(model: model, voice: voice, config: config)
        _ = try await answerUntilTheDrop(rig, voice) { first in first.wire.cut() }
        await waitFor { await model.recorded == [Self.first + " […]"] }
        #expect(await model.recorded == [Self.first + " […]"])
        let second = await rig.connect(path: .relay)
        await waitFor { rig.engine.reachability == [false, true] }
        try await Task.sleep(for: .milliseconds(500))
        #expect(second.phone.framesHeard == 0)
        #expect(rig.engine.said.isEmpty)
        #expect(await model.recorded == [Self.first + " […]"])
        await rig.end()
    }

    /// It does not come back: at the end of the grace period the Mac takes the sound back, but the rest of the answer
    /// is not said there (only the iPhone heard its beginning).
    @Test func theRestIsNotSaidOnTheMac() async throws {
        let (voice, model) = (StepVoice(), Notebook(answer: Self.answer))
        let rig = try await Rig(gracePeriod: .milliseconds(800), model: model, voice: voice)
        _ = try await answerUntilTheDrop(rig, voice, releaseFirst: true) { first in first.wire.close() }
        await waitFor { rig.engine.localRoutes == 1 }
        await waitFor { await model.recorded == [Self.first + " […]"] }
        #expect(await model.recorded == [Self.first + " […]"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.engine.localPlayed == 0)
        #expect(rig.engine.said.isEmpty)
        await rig.end()
    }

    /// The user's typed question, its answer's first sentence reaching the iPhone, then the drop (`drop`): the rest of
    /// the voice goes into the dead connection (`releaseFirst`: before the drop rather than after it, for a drop that
    /// the Mac sees at once), and the Mac sees that the iPhone is out of reach.
    private func answerUntilTheDrop(_ rig: Rig, _ voice: StepVoice, releaseFirst: Bool = false,
                                    drop: (Connection) -> Void) async throws -> Connection
    {
        let first = await rig.connect()
        first.phone.hold()  // it is still saying the answer when the drop comes: it does not say it played it
        await rig.takeTheConversation()
        await rig.engine.pipeline.submit(text: "Raconte-moi quelque chose.")
        await waitFor { first.phone.framesHeard == Self.sentenceFrames }  // the first sentence reached it
        try await Task.sleep(for: .milliseconds(500))  // well before the drop
        if releaseFirst {
            voice.release()
            try await Task.sleep(for: .milliseconds(50))
            #expect(first.phone.framesHeard == 3 * Self.sentenceFrames)
        }
        drop(first)
        if !releaseFirst { voice.release() }  // the rest goes into the dead connection
        await waitFor { rig.engine.reachability == [false] }
        await waitFor { rig.engine.cutOff == [Self.answer] }
        #expect(rig.engine.cutOff == [Self.answer])
        return first
    }

    // MARK: A sentence of the user's cut

    /// The user is speaking when the iPhone's Wi-Fi goes off. Once it is back, the sentence is not answered (the model
    /// never gets it): Maé asks the user to say it again.
    @Test func aSentenceCutIsNotAnsweredTheUserIsAskedToRepeatIt() async throws {
        let model = Notebook(answer: "Il est midi.")
        let rig = try await Rig(transcriber: Hears("Quelle heure est-il ?"), model: model)
        let first = try await speakUntilTheDrop(rig) { first in first.wire.cut() }
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(second.phone.played.map(\.frames) == [Self.sentenceFrames])
        #expect(rig.engine.pieces == [OutOfReachPhrases.sentenceCut(.french)])
        try await Task.sleep(for: .milliseconds(500))
        #expect(await model.requests == 0)  // the cut sentence never went to the model
        #expect(rig.engine.said.isEmpty)
        #expect(await model.recorded.isEmpty)  // nor into the history, nor the request to repeat it
        #expect(first.phone.framesHeard == 0)
        await rig.end()
    }

    /// The same when the Mac sees the session close: the sentence is not ended as if the user had stopped talking.
    @Test func aSentenceCutWhenTheSessionClosesIsNotAnsweredEither() async throws {
        let model = Notebook(answer: "Il est midi.")
        let rig = try await Rig(transcriber: Hears("Quelle heure est-il ?"), model: model)
        _ = try await speakUntilTheDrop(rig) { first in first.wire.close() }
        let second = await rig.connect(path: .relay)
        await waitFor { second.phone.played.count == 1 }
        #expect(rig.engine.pieces == [OutOfReachPhrases.sentenceCut(.french)])
        try await Task.sleep(for: .milliseconds(500))
        #expect(await model.requests == 0)
        #expect(rig.engine.said.isEmpty)
        await rig.end()
    }

    /// The user holds the button ("Hold") when the drop comes, and lets it go once the iPhone is back: that late
    /// release ends nothing, Maé asks for the sentence again.
    @Test func aSentenceCutWhileTheButtonIsHeldIsAskedAgain() async throws {
        let model = Notebook(answer: "Il est midi.")
        let rig = try await Rig(transcriber: Hears("Quelle heure est-il ?"), model: model)
        let first = await rig.connect()
        await rig.takeTheConversation()
        first.phone.session.send(.command(.talkKey(pressed: true)))
        rig.engine.iPhoneUserSpeaks(true)
        await waitFor { rig.engine.states.last == .userSpeaking }
        try await Task.sleep(for: .milliseconds(300))
        first.wire.cut()
        await waitFor { rig.engine.reachability == [false] }
        rig.engine.iPhoneUserSpeaks(false)
        let second = await rig.connect(path: .relay)
        second.phone.session.send(.command(.talkKey(pressed: false)))
        await waitFor { second.phone.played.count == 1 }
        #expect(rig.engine.pieces == [OutOfReachPhrases.sentenceCut(.french)])
        try await Task.sleep(for: .milliseconds(500))
        #expect(await model.requests == 0)
        #expect(rig.engine.said.isEmpty)
        await rig.end()
    }

    /// The iPhone moves from the relay to the local network (at a silence, as far as it knows) just as the user starts
    /// speaking: a new session while the old one was still heard. That is no drop: the sentence goes on and is answered.
    @Test func aChangeOfWayIsNotADrop() async throws {
        let model = Notebook(answer: "Il est midi.")
        let rig = try await Rig(transcriber: Hears("Quelle heure est-il ?"), model: model)
        _ = await rig.connect(path: .relay)
        await rig.takeTheConversation()
        try await Task.sleep(for: .milliseconds(200))
        rig.engine.iPhoneUserSpeaks(true)
        await waitFor { rig.engine.states.last == .userSpeaking }
        let direct = await rig.connect(path: .direct)
        try await Task.sleep(for: .milliseconds(300))
        rig.engine.iPhoneUserSpeaks(false)
        await waitFor { rig.engine.said == ["Il est midi."] }
        #expect(rig.engine.said == ["Il est midi."])
        #expect(rig.engine.reachability.isEmpty)
        #expect(direct.phone.played.map(\.frames) == [Self.sentenceFrames])
        #expect(await model.requests == 1)
        await rig.end()
    }

    /// The user speaks into the iPhone, then the drop (`drop`); the Mac sees it out of reach while the user still talks.
    private func speakUntilTheDrop(_ rig: Rig, drop: (Connection) -> Void) async throws -> Connection {
        let first = await rig.connect()
        await rig.takeTheConversation()
        rig.engine.iPhoneUserSpeaks(true)
        await waitFor { rig.engine.states.last == .userSpeaking }
        try await Task.sleep(for: .milliseconds(300))
        drop(first)
        await waitFor { rig.engine.reachability == [false] }
        rig.engine.iPhoneUserSpeaks(false)
        await waitFor { rig.engine.states.last == .listening }
        #expect(rig.engine.states.last == .listening)
        return first
    }
}

// MARK: - Stages

/// Answers every request with the same text, counts the requests, and keeps the history as it was last recorded
/// (`catchUp`).
private actor Notebook: LanguageModel {
    nonisolated let answer: String
    private var history: [ChatMessage] = []
    private(set) var requests = 0

    init(answer: String) { self.answer = answer }

    /// What the history holds of what Maé said, in order.
    var recorded: [String] { history.filter { $0.role == .assistant }.map(\.content) }

    nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { [answer] continuation in
            Task {
                await self.count()
                continuation.yield(.text(answer))
                continuation.finish()
            }
        }
    }

    private func count() { requests += 1 }
    func catchUp(with conversation: [ChatMessage]) async { history = conversation }
    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// Hears the same sentence in whatever it is given.
private struct Hears: Transcriber {
    let sentence: String
    init(_ sentence: String) { self.sentence = sentence }
    func transcribe(_ samples: [Float]) async throws -> String { sentence }
}

/// `ToneVoice`, whose first utterance says its first text at once and holds the others until `release()`: an answer
/// whose voice is still on its way when the connection drops. The next utterances speak at once.
private final class StepVoice: SpeechSynthesizer, @unchecked Sendable {
    let outputSampleRate = LinkAudio.voiceRate
    private let lock = NSLock()
    private var first: StepStream?

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        lock.withLock {
            guard first == nil else { return ToneStream() }
            let stream = StepStream()
            first = stream
            return stream
        }
    }

    func release() { lock.withLock { first }?.release() }
}

private final class StepStream: SynthesisStream, @unchecked Sendable {
    private let tone = ToneStream()
    private let lock = NSLock()
    private var given = 0
    /// What came after the first text, until released; nil once released.
    private var held: [String]? = []
    private var finishing = false

    var audio: AsyncThrowingStream<VoiceAudio, Error> { tone.audio }

    func enqueue(_ text: String) {
        let passes: Bool = lock.withLock {
            given += 1
            guard given > 1, held != nil else { return true }
            held?.append(text)
            return false
        }
        if passes { tone.enqueue(text) }
    }

    func finish() {
        let passes: Bool = lock.withLock {
            finishing = true
            return held == nil
        }
        if passes { tone.finish() }
    }

    func cancel() async { await tone.cancel() }

    func release() {
        let (texts, finishing): ([String], Bool) = lock.withLock {
            defer { held = nil }
            return (held ?? [], self.finishing)
        }
        texts.forEach(tone.enqueue)
        if finishing { tone.finish() }
    }
}
