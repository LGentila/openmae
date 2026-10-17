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
    init(answer: [String] = ["Bonjour, ", "je suis bien là. ", "Comment vas-tu ce matin ?"]) {
        scripts = [answer.map { .text($0) }]
    }
    init(scripts: [[ModelOutput]]) { self.scripts = scripts }

    nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let script = await self.log(conversation)
                for output in script {
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
    func prefillBeginning(_ beginning: [ChatMessage]) async throws { prefills.append((true, beginning)) }
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
    let audio: AsyncThrowingStream<[Float], Error>
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private var started = false
    init() { (audio, continuation) = AsyncThrowingStream.makeStream() }
    func enqueue(_ text: String) {
        // Like Pocket TTS, the voice sometimes opens with a near-silent breath.
        if !started { continuation.yield([Float](repeating: 0.0001, count: 300)) }
        started = true
        continuation.yield([Float](repeating: 0.1, count: 500))
    }
    func finish() { continuation.finish() }
    func cancel() async { continuation.finish() }
}

/// Plays in (accelerated) real time: 1 sample = 1 ms, so the assistant can be interrupted.
actor FakeSpeaker: AudioOutput {
    private(set) var played = 0
    private(set) var stops = 0
    private var busyUntil = ContinuousClock.now
    func play(_ samples: [Float], sampleRate: Double) {
        played += samples.count
        busyUntil = max(busyUntil, .now) + .milliseconds(samples.count)
    }
    func waitUntilDone() async {
        while busyUntil > .now { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func stopImmediately() {
        stops += 1
        busyUntil = .now
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
        let (model, stt, speaker) = (ScriptedModel(), CountingTranscriber(), FakeSpeaker())
        let pipeline = make(model, stt, speaker)  // hands-free
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
}

actor EventRecorder {
    private(set) var pieces: [String] = []
    private(set) var states: [PipelineState] = []
    /// "user" / "assistant", in the order the interface would display them.
    private(set) var order: [String] = []
    private(set) var awake: [Bool] = []
    private(set) var wakeDecisions: [WakeDecision] = []
    private(set) var bargeIns = 0

    func record(_ event: PipelineEvent) {
        switch event {
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

    func transcribe(_ samples: [Float]) async throws -> String {
        calls += 1
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
              wakeWord: any WakeWordDetector = OKMaeWakeWord()) -> (VoicePipeline, EventRecorder)
    {
        var config = PipelineConfig()
        config.listening = .wakeWord
        config.wakeFollowUpSeconds = followUp
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: LevelTranscriber(), model: model,
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
        #expect(await log.states.starts(with: [.listening, .userSpeaking, .thinking]))
        await waitFor { await log.awake == [true] }  // after the answer: a few seconds of attention
        #expect(await log.awake == [true])
        #expect(await log.wakeDecisions.map(\.accepted) == [true])
    }

    @Test func thePhraseAloneChimesThenTheNextSentenceIsTheRequest() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 4)  // "Ok Mae."
        await waitFor { await log.awake == [true] }
        #expect(await log.awake == [true])
        #expect(await speaker.played == Chime.samples(sampleRate: 1000).count)
        #expect(await model.requests.isEmpty)
        let states = await log.states
        #expect(states.last == .listening && !states.contains(.thinking))
        await say(pipeline, 5)  // "Et demain ?"
        await waitFor { await model.requests.count == 1 }
        #expect(await model.requests.last?.last?.content == "Et demain ?")
    }

    @Test func noPhraseIsNeededForAFewSecondsAfterAnAnswer() async throws {
        let (model, speaker) = (ScriptedModel(), FakeSpeaker())
        let (pipeline, log) = make(model, speaker)
        try await pipeline.start()
        await say(pipeline, 3)
        await waitFor { await log.awake == [true] }
        await say(pipeline, 5)  // "Et demain ?", without the phrase
        await waitFor { await model.requests.count == 2 }
        #expect(await model.requests.last?.last?.content == "Et demain ?")
        let decision = try #require(await log.wakeDecisions.last)
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
