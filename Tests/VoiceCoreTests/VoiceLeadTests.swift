import Foundation
import Testing

@testable import VoiceCore

@Suite("The model waits for the voice after the first sound")
struct VoiceLeadTests {
    let start = ContinuousClock.now
    func at(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }
    func rule(minimum: Int? = 500, openings: Bool = true) -> VoiceLead {
        VoiceLead(minimum: minimum.map { .milliseconds($0) }, duringOpenings: openings, sampleRate: 1000)
    }

    @Test func theSpeakersPlayWhatTheyGetInRealTime() {
        var lead = rule()
        #expect(lead.lead(at: at(0)) == .zero)
        lead.played(300, at: at(0))
        lead.played(300, at: at(100))  // after the first: over at 600 ms
        #expect(lead.lead(at: at(100)) == .milliseconds(500))
        #expect(lead.lead(at: at(700)) == .zero)
        lead.played(200, at: at(700))  // they ran dry meanwhile: it plays at once
        #expect(lead.lead(at: at(750)) == .milliseconds(150))
    }

    /// A later sentence that opens with near-silence: the model waits from its first chunk until it is heard, whatever
    /// the lead, and even when no text follows it (the voice has that sentence to say).
    @Test func theModelWaitsWhileASentenceOpensWithNearSilence() {
        var lead = rule()
        lead.played(2000, at: at(0))  // two seconds ready: the lead is no reason to wait
        var r = lead.update(text: 0, audible: true, texts: 2, at: at(10))
        #expect(!r.wait)
        r = lead.update(text: 1, audible: false, texts: 2, at: at(20))
        #expect(r.wait && r.renew)  // a sentence that starts: said again, the model's pause may have run out
        r = lead.update(text: 1, audible: false, texts: 2, at: at(30))
        #expect(r.wait && !r.renew)
        r = lead.update(text: 1, audible: true, texts: 2, at: at(40))
        #expect(!r.wait)
        r = lead.update(text: 1, audible: false, texts: 2, at: at(50))  // a pause inside the sentence: not an opening
        #expect(!r.wait)
    }

    /// The speakers have little left to play: the model waits as long as the voice has another text after the one it
    /// says, and goes on once they have enough.
    @Test func theModelWaitsWhileTheSpeakersHaveLittleLeft() {
        var lead = rule()
        lead.played(80, at: at(0))
        var r = lead.update(text: 0, audible: true, texts: 1, at: at(0))
        #expect(!r.wait)  // no text after this one: waiting could leave the voice without any
        r = lead.update(text: 0, audible: true, texts: 2, at: at(10))
        #expect(r.wait && !r.renew)  // 70 ms left, and another text follows
        for i in 1...6 { lead.played(80, at: at(10 + 20 * i)) }  // six more frames of 80 ms, one every 20 ms
        r = lead.update(text: 0, audible: true, texts: 2, at: at(130))
        #expect(lead.lead(at: at(130)) == .milliseconds(430))  // 560 ms of audio from 0 ms
        #expect(r.wait)
        lead.played(80, at: at(140))
        lead.played(80, at: at(140))  // 720 ms of audio in all
        r = lead.update(text: 0, audible: true, texts: 2, at: at(150))
        #expect(lead.lead(at: at(150)) == .milliseconds(570))
        #expect(!r.wait)
    }

    @Test func theModelGoesOnOnceTheSpeakersHaveEnough() {
        var lead = rule()
        lead.played(400, at: at(0))
        var r = lead.update(text: 0, audible: true, texts: 3, at: at(0))
        #expect(r.wait && r.renew)  // 400 ms ready, another text follows; the sentence is heard
        lead.played(400, at: at(100))
        r = lead.update(text: 0, audible: true, texts: 3, at: at(100))
        #expect(!r.wait)  // 700 ms left
        r = lead.update(text: 0, audible: true, texts: 3, at: at(350))
        #expect(r.wait && !r.renew)  // 450 ms left
        r = lead.update(text: 1, audible: true, texts: 3, at: at(360))
        #expect(r.wait && r.renew)  // a new sentence, heard at once, 440 ms left: said again
    }

    @Test func theRulesCanBeTurnedOff() {
        var openingsOnly = rule(minimum: nil)
        openingsOnly.played(80, at: at(0))
        #expect(!openingsOnly.update(text: 0, audible: true, texts: 3, at: at(0)).wait)  // the lead does not count
        #expect(openingsOnly.update(text: 1, audible: false, texts: 3, at: at(10)).wait)
        var leadOnly = rule(openings: false)
        leadOnly.played(2000, at: at(0))
        #expect(!leadOnly.update(text: 1, audible: false, texts: 3, at: at(0)).wait)  // openings do not count
        let off = rule(minimum: nil, openings: false)
        #expect(!off.isOn)
    }

    /// A voice that cannot tell which text it says never has the model wait: nothing tells whether it has text left.
    @Test func aVoiceWithoutTextNumbersNeverHasTheModelWait() {
        var lead = rule()
        lead.played(80, at: at(0))
        #expect(!lead.update(text: nil, audible: false, texts: 3, at: at(0)).wait)
        #expect(!lead.update(text: nil, audible: true, texts: 3, at: at(10)).wait)
    }
}

/// A scripted language model that writes its pieces after the delays given, and records when the pipeline has it wait
/// for the voice (`YieldsToVoice`), and when it wrote each piece.
final class WaitingModel: LanguageModel, YieldsToVoice, @unchecked Sendable {
    private let pieces: [(delay: Duration, text: String)]
    private let lock = NSLock()
    private var holds: [(held: Bool, at: ContinuousClock.Instant)] = []
    private var written: [ContinuousClock.Instant] = []

    init(_ pieces: [(delay: Duration, text: String)]) { self.pieces = pieces }
    convenience init(_ texts: [String]) { self.init(texts.map { (.milliseconds(5), $0) }) }

    func holdGeneration(_ held: Bool) { lock.withLock { holds.append((held, .now)) } }
    /// Whether the model was held or let go, in order, and when.
    var held: [(held: Bool, at: ContinuousClock.Instant)] { lock.withLock { holds } }
    /// When each piece was written.
    var writes: [ContinuousClock.Instant] { lock.withLock { written } }

    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for piece in pieces {
                    try? await Task.sleep(for: piece.delay)
                    if Task.isCancelled { break }
                    lock.withLock { written.append(.now) }
                    continuation.yield(.text(piece.text))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// A voice that says each text as `chunks` audible chunks of 100 samples (100 ms at 1000 Hz), one every `pace`.
final class SteadyStream: SynthesisStream, @unchecked Sendable {
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let texts: AsyncStream<String>.Continuation
    private let producer: Task<Void, Never>

    init(chunks: Int, pace: Duration) {
        let (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
        let (textStream, texts) = AsyncStream.makeStream(of: String.self)
        self.audio = audio
        self.texts = texts
        producer = Task {
            var number = 0
            for await _ in textStream {
                for _ in 0..<chunks where !Task.isCancelled {
                    try? await Task.sleep(for: pace)
                    output.yield(VoiceAudio([Float](repeating: 0.1, count: 100), text: number))
                }
                number += 1
            }
            output.finish()
        }
    }

    func enqueue(_ text: String) { texts.yield(text) }
    func finish() { texts.finish() }
    func cancel() async {
        producer.cancel()
        texts.finish()
        await producer.value
    }
}

struct SteadySynthesizer: SpeechSynthesizer {
    let outputSampleRate = 1000.0
    let chunks: Int
    let pace: Duration
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        SteadyStream(chunks: chunks, pace: pace)
    }
}

@Suite("The model waits for the voice, in the pipeline", .serialized)
struct VoiceLeadPipelineTests {
    let answer = ["Bonjour, ", "je suis bien là. ", "Comment vas-tu ce matin ?"]

    func run(_ model: WaitingModel, _ synthesizer: any SpeechSynthesizer, config: PipelineConfig = .init(),
             until played: Int) async throws -> FakeSpeaker
    {
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(), model: model,
                                     synthesizer: synthesizer, output: speaker, config: config)
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        for _ in 0..<600 where await speaker.played < played { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<600 where await speaker.remainingMs > 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        return speaker
    }

    /// The answer's second sentence opens with three seconds of near-silence: the model waits from the start of that
    /// opening until the sentence is heard. Before the first sound, as before: it waits from the first piece until then.
    /// (The lead's rule is off here, so that only the opening counts.)
    @Test func theModelWaitsWhileALaterSentenceOpensWithNearSilence() async throws {
        var config = PipelineConfig()
        config.voiceLeadSeconds = nil
        let model = WaitingModel(answer)
        let synthesizer = SentenceSynthesizer([{ ($0.contains("Comment") ? 3000 : 0, false) }])
        let speaker = try await run(model, synthesizer, config: config, until: 1000)
        #expect(await speaker.played >= 1000)  // both sentences
        let held = model.held.map(\.held)
        #expect(Array(held.prefix(4)) == [true, false, true, false])  // first piece, first sound; the opening
        #expect(held.last == false)
        #expect(held.dropFirst(4).allSatisfy { !$0 })
    }

    /// Without the rule, the model is held as before only: from the first piece to the first sound.
    @Test func withoutTheRuleTheModelWaitsOnlyForTheFirstSound() async throws {
        var config = PipelineConfig()
        config.voiceLeadSeconds = nil
        config.modelWaitsDuringOpenings = false
        let model = WaitingModel(answer)
        let synthesizer = SentenceSynthesizer([{ ($0.contains("Comment") ? 3000 : 0, false) }])
        let speaker = try await run(model, synthesizer, config: config, until: 1000)
        #expect(await speaker.played >= 1000)
        let held = model.held.map(\.held)
        #expect(Array(held.prefix(2)) == [true, false])
        #expect(held.dropFirst(2).allSatisfy { !$0 })
    }

    /// A voice that produces its audio faster than the speakers play it, a sentence ahead of what they play: the model
    /// waits while they have under half a second left, then goes on once they have more.
    @Test func theModelWaitsWhileTheSpeakersHaveLittleLeft() async throws {
        let model = WaitingModel(["Bonjour, je suis bien là. ", "La mer est très salée, tu sais. ",
                                  "Les rivières y portent du sel. ", "Voilà pour aujourd'hui."])
        // Four chunks of 100 ms a sentence, one every 20 ms: the voice gets ahead 80 ms a chunk.
        let speaker = try await run(model, SteadySynthesizer(chunks: 4, pace: .milliseconds(20)), until: 1600)
        #expect(await speaker.played == 1600)  // the four sentences
        let held = model.held
        // First piece, first sound; then the speakers have under 500 ms while the next sentences are written.
        #expect(held.count >= 4)
        #expect(Array(held.prefix(2).map(\.held)) == [true, false])
        let afterFirstSound = held.dropFirst(2)
        let waits = try #require(afterFirstSound.first { $0.held })
        let goesOn = try #require(afterFirstSound.first { !$0.held && $0.at > waits.at })
        // 80 ms of lead a chunk: from under 500 ms to 500 ms takes a few chunks, not seconds.
        #expect(goesOn.at - waits.at < .milliseconds(400))
        #expect(model.held.last?.held == false)
    }

    /// The answer's second sentence is said as near-silence while the model writes the third one a second later: the
    /// model waits for that sentence's opening, but the voice, done with it, has nothing more to say. It goes on half
    /// a second later, without waiting until the third sentence comes; the sentence said as near-silence is said again.
    @Test func theModelGoesOnWhenTheVoiceHasNothingLeftToSay() async throws {
        let model = WaitingModel([(.milliseconds(5), "Bonjour, je suis bien là. "),
                                  (.milliseconds(5), "Comment vas-tu ce matin, toi ? "),
                                  (.milliseconds(1000), "Il fait très beau aujourd'hui.")])
        // The first utterance says the second sentence as near-silence; the one started again says it.
        let synthesizer = SentenceSynthesizer([{ (0, $0.contains("Comment")) }])
        let speaker = try await run(model, synthesizer, until: 1500)
        #expect(await speaker.played >= 1500)  // the three sentences heard
        let held = model.held
        #expect(Array(held.prefix(2).map(\.held)) == [true, false])
        let waits = try #require(held.dropFirst(2).first { $0.held })
        let goesOn = try #require(held.first { !$0.held && $0.at > waits.at })
        let third = try #require(model.writes.last)
        #expect(goesOn.at - waits.at >= .milliseconds(400))  // the voice was still busy until then
        #expect(goesOn.at - waits.at < .milliseconds(800))
        #expect(goesOn.at < third)  // let go before the model's third sentence
        #expect(await synthesizer.streams.count == 2)
    }
}
