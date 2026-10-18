import Foundation
import Testing

@testable import VoiceCore

/// A voice that takes its time, as Pocket TTS does: `opening` near-silent samples before its first text (100 samples a
/// millisecond), then 500 audible samples per text.
final class PacedStream: SynthesisStream, @unchecked Sendable {
    let audio: AsyncThrowingStream<[Float], Error>
    private let texts: AsyncStream<String>.Continuation
    private let producer: Task<Void, Never>
    private let lock = NSLock()
    private var given: [String] = []
    private var stopped = false

    init(opening: Int) {
        let (audio, output) = AsyncThrowingStream.makeStream(of: [Float].self)
        let (textStream, texts) = AsyncStream.makeStream(of: String.self)
        self.audio = audio
        self.texts = texts
        producer = Task {
            var first = true
            for await _ in textStream {
                if first {
                    first = false
                    for _ in 0..<(opening / 100) where !Task.isCancelled {
                        output.yield([Float](repeating: 0.0001, count: 100))
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                if Task.isCancelled { break }
                output.yield([Float](repeating: 0.1, count: 500))
            }
            output.finish()
        }
    }

    /// The texts this voice was given.
    var received: [String] { lock.withLock { given } }
    var cancelled: Bool { lock.withLock { stopped } }

    func enqueue(_ text: String) {
        lock.withLock { given.append(text) }
        texts.yield(text)
    }

    func finish() { texts.finish() }

    func cancel() async {
        lock.withLock { stopped = true }
        producer.cancel()
        texts.finish()
        await producer.value
    }
}

/// Voices whose openings last as long as the list says, one utterance after the other (then 300 samples).
actor PacedSynthesizer: SpeechSynthesizer {
    nonisolated let outputSampleRate = 1000.0
    private var openings: [Int]
    private(set) var streams: [PacedStream] = []
    init(openings: [Int]) { self.openings = openings }

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        let stream = PacedStream(opening: openings.isEmpty ? 300 : openings.removeFirst())
        streams.append(stream)
        return stream
    }
}

@Suite("Voices racing for the first sound")
struct VoiceRaceTests {
    let audible: @Sendable ([Float]) -> Bool = { VoicePipeline.loudnessDB($0) >= -45 }

    @Test func theSoonerVoiceSaysEverythingAndTheOtherStops() async throws {
        let (slow, quick) = (PacedStream(opening: 3000), PacedStream(opening: 300))
        let race = VoiceRace([slow, quick], audible: audible)
        race.enqueue("Bonjour, je suis bien là.")
        var samples: [Float] = []
        var iterator = race.audio.makeAsyncIterator()
        samples += try #require(try await iterator.next())
        #expect(race.heard == 1)
        race.enqueue("Comment vas-tu ce matin ?")  // after the race: only the voice heard gets it
        race.finish()
        while let chunk = try await iterator.next() { samples += chunk }
        #expect(samples.count == 1000)  // its two sentences, without the near-silence before them
        #expect(samples.allSatisfy { $0 == 0.1 })
        #expect(quick.received.count == 2)
        #expect(slow.received.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(slow.cancelled)
        #expect(!quick.cancelled)
    }

    @Test func nothingIsHeardWhenEveryVoiceStaysSilent() async throws {
        let silent = { PacedStream(opening: 200) }
        let (one, two) = (silent(), silent())
        let race = VoiceRace([one, two]) { _ in false }
        race.enqueue("Bonjour, je suis bien là.")
        race.finish()
        var samples = 0
        for try await chunk in race.audio { samples += chunk.count }
        #expect(samples == 0)
        #expect(race.heard == nil)
    }

    @Test func cancellingStopsEveryVoice() async throws {
        let (one, two) = (PacedStream(opening: 100_000), PacedStream(opening: 100_000))
        let race = VoiceRace([one, two], audible: audible)
        race.enqueue("Bonjour, je suis bien là.")
        try await Task.sleep(for: .milliseconds(20))
        await race.cancel()
        for try await _ in race.audio {}
        #expect(one.cancelled && two.cancelled)
    }

    /// The first voice would say its opening sentence as near-silence for seconds; the second one speaks at once: the
    /// answer is heard from the second one, whole and once, and the first one stops.
    @Test func thePipelineSpeaksWithTheSoonerOfTwoVoices() async throws {
        var config = PipelineConfig()
        config.racingVoices = 2
        let synthesizer = PacedSynthesizer(openings: [100_000, 300])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker, config: config)
        try await pipeline.start()
        let start = ContinuousClock.now
        await pipeline.submit(text: "Bonjour")
        for _ in 0..<200 where await speaker.played < 1000 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ContinuousClock.now - start < .milliseconds(500))  // the silent voice would have taken 1 s or more
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 1000)  // "Bonjour, je suis bien là." and "Comment vas-tu ce matin ?"
        let streams = await synthesizer.streams
        #expect(streams.count == 2)
        #expect(streams[0].cancelled)
        #expect(streams[1].received.count == 2)
    }
}

@Suite("Voice started again after a long near-silence")
struct VoiceRestartTests {
    let audible: @Sendable ([Float]) -> Bool = { VoicePipeline.loudnessDB($0) >= -45 }

    /// The first voice would stay near-silent for a second; once 2000 samples of it went by, a new one starts, gets all
    /// the text given so far, and says it.
    @Test func aSilentOpeningStartsAgainWithEverything() async throws {
        let synthesizer = PacedSynthesizer(openings: [100_000, 300])
        let first = try await synthesizer.startUtterance(language: .french)
        let voice = VoiceRestart(first, patience: 2000, restarts: 2, audible: audible) {
            try await synthesizer.startUtterance(language: .french)
        }
        voice.enqueue("Bonjour, je suis bien là.")
        voice.enqueue("Comment vas-tu ce matin ?")
        voice.finish()
        var samples: [Float] = []
        for try await chunk in voice.audio { samples += chunk }
        #expect(samples.count == 1000)  // both sentences, once, without the near-silence before them
        #expect(samples.allSatisfy { $0 == 0.1 })
        let streams = await synthesizer.streams
        #expect(streams.count == 2)
        #expect(streams[0].cancelled)
        #expect(streams[1].received == ["Bonjour, je suis bien là.", "Comment vas-tu ce matin ?"])
    }

    /// Text that comes while the voice starts again is not lost, nor said twice.
    @Test func textGivenMeanwhileIsSaidOnce() async throws {
        let synthesizer = PacedSynthesizer(openings: [2500, 300])
        let first = try await synthesizer.startUtterance(language: .french)
        let voice = VoiceRestart(first, patience: 2000, restarts: 1, audible: audible) {
            try await Task.sleep(for: .milliseconds(20))  // a voice that takes a moment to start
            return try await synthesizer.startUtterance(language: .french)
        }
        voice.enqueue("Bonjour, je suis bien là.")
        for _ in 0..<100 where await synthesizer.streams.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        voice.enqueue("Comment vas-tu ce matin ?")
        voice.finish()
        var samples = 0
        for try await chunk in voice.audio { samples += chunk.count }
        #expect(samples == 1000)
        #expect(await synthesizer.streams[1].received == ["Bonjour, je suis bien là.", "Comment vas-tu ce matin ?"])
    }

    /// The voice starts again at most `restarts` times; the last one says the answer whatever its opening.
    @Test func restartsAreCounted() async throws {
        let synthesizer = PacedSynthesizer(openings: [3000, 3000, 3000])
        let first = try await synthesizer.startUtterance(language: .french)
        let voice = VoiceRestart(first, patience: 1000, restarts: 1, audible: audible) {
            try await synthesizer.startUtterance(language: .french)
        }
        voice.enqueue("Bonjour, je suis bien là.")
        voice.finish()
        var samples = 0
        for try await chunk in voice.audio { samples += chunk.count }
        #expect(samples == 500)
        #expect(await synthesizer.streams.count == 2)
    }

    @Test func cancellingStopsTheVoiceAndItsRestart() async throws {
        let synthesizer = PacedSynthesizer(openings: [100_000, 100_000, 100_000])
        let first = try await synthesizer.startUtterance(language: .french)
        let voice = VoiceRestart(first, patience: 1000, restarts: 2, audible: audible) {
            try await synthesizer.startUtterance(language: .french)
        }
        voice.enqueue("Bonjour, je suis bien là.")
        try await Task.sleep(for: .milliseconds(30))
        await voice.cancel()
        for try await _ in voice.audio {}
        try await Task.sleep(for: .milliseconds(30))
        let streams = await synthesizer.streams
        #expect(streams.allSatisfy { $0.cancelled })
        #expect(streams.count <= 3)
    }

    /// In the pipeline (1.2 s of near-silence at most, the default): an answer whose voice would open with seconds of
    /// near-silence is heard whole, from the voice started again.
    @Test func thePipelineStartsASilentVoiceAgain() async throws {
        let synthesizer = PacedSynthesizer(openings: [100_000, 300])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker)
        try await pipeline.start()
        let start = ContinuousClock.now
        await pipeline.submit(text: "Bonjour")
        for _ in 0..<200 where await speaker.played < 1000 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ContinuousClock.now - start < .milliseconds(500))  // the silent voice would have taken 1 s or more
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 1000)
        let streams = await synthesizer.streams
        #expect(streams.count == 2)
        #expect(streams[0].cancelled)
    }
}
