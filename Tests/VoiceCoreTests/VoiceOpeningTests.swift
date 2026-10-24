import Foundation
import Testing

@testable import VoiceCore

/// Waits until `condition` holds, for `limit` at most. A busy Mac makes every sleep and every task hop slower: the
/// tests wait for what they check, not for a set time, and the slow paths they rule out take 10 s or more.
private func waitFor(within limit: Duration = .seconds(5), _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + limit
    while !(await condition()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
}

/// A voice that takes its time, as Pocket TTS does: `opening` near-silent samples before its first text (100 samples a
/// millisecond), then 500 audible samples per text.
final class PacedStream: SynthesisStream, @unchecked Sendable {
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let texts: AsyncStream<String>.Continuation
    private let producer: Task<Void, Never>
    private let lock = NSLock()
    private var given: [String] = []
    private var stopped = false

    init(opening: Int) {
        let (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
        let (textStream, texts) = AsyncStream.makeStream(of: String.self)
        self.audio = audio
        self.texts = texts
        producer = Task {
            var first = true
            var text = 0
            for await _ in textStream {
                if first {
                    first = false
                    for _ in 0..<(opening / 100) where !Task.isCancelled {
                        output.yield(VoiceAudio([Float](repeating: 0.0001, count: 100), text: text))
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                if Task.isCancelled { break }
                output.yield(VoiceAudio([Float](repeating: 0.1, count: 500), text: text))
                text += 1
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
        let (slow, quick) = (PacedStream(opening: 100_000), PacedStream(opening: 300))
        let race = VoiceRace([slow, quick], audible: audible)
        race.enqueue("Bonjour, je suis bien là.")
        var samples: [Float] = []
        var iterator = race.audio.makeAsyncIterator()
        samples += try #require(try await iterator.next()).samples
        #expect(race.heard == 1)
        race.enqueue("Comment vas-tu ce matin ?")  // after the race: only the voice heard gets it
        race.finish()
        while let chunk = try await iterator.next() { samples += chunk.samples }
        #expect(samples.count == 1000)  // its two sentences, without the near-silence before them
        #expect(samples.allSatisfy { $0 == 0.1 })
        #expect(quick.received.count == 2)
        #expect(slow.received.count == 1)
        await waitFor { slow.cancelled }  // the race stops the other voice in a task of its own
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
        for try await chunk in race.audio { samples += chunk.samples.count }
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
        let synthesizer = PacedSynthesizer(openings: [1_000_000, 300])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker, config: config)
        try await pipeline.start()
        let start = ContinuousClock.now
        await pipeline.submit(text: "Bonjour")
        await waitFor { await speaker.played >= 1000 }
        #expect(ContinuousClock.now - start < .seconds(5))  // the silent voice would have taken 10 s or more
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 1000)  // "Bonjour, je suis bien là." and "Comment vas-tu ce matin ?"
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        await waitFor { streams[0].cancelled }  // the race stops the other voice in a task of its own
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
        var texts: [Int?] = []
        for try await chunk in voice.audio {
            samples += chunk.samples
            texts.append(chunk.text)
        }
        #expect(samples.count == 1000)  // both sentences, once, without the near-silence before them
        #expect(texts == [0, 1])  // the voice started again numbers its texts as the first one did
        #expect(samples.allSatisfy { $0 == 0.1 })
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
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
        await waitFor { await synthesizer.streams.count >= 2 }
        voice.enqueue("Comment vas-tu ce matin ?")
        voice.finish()
        var samples = 0
        for try await chunk in voice.audio { samples += chunk.samples.count }
        #expect(samples == 1000)
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[1].received == ["Bonjour, je suis bien là.", "Comment vas-tu ce matin ?"])
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
        for try await chunk in voice.audio { samples += chunk.samples.count }
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
        try await Task.sleep(for: .milliseconds(30))  // a voice starting again meanwhile shows up
        await waitFor { await synthesizer.streams.allSatisfy { $0.cancelled } }
        let streams = await synthesizer.streams
        #expect(streams.allSatisfy { $0.cancelled })
        #expect(streams.count <= 3)
    }

    /// In the pipeline (1.2 s of near-silence at most, the default): an answer whose voice would open with seconds of
    /// near-silence is heard whole, from the voice started again.
    @Test func thePipelineStartsASilentVoiceAgain() async throws {
        let synthesizer = PacedSynthesizer(openings: [1_000_000, 300])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker)
        try await pipeline.start()
        let start = ContinuousClock.now
        await pipeline.submit(text: "Bonjour")
        await waitFor { await speaker.played >= 1000 }
        #expect(ContinuousClock.now - start < .seconds(5))  // the silent voice would have taken 10 s or more
        try await Task.sleep(for: .milliseconds(100))
        #expect(await speaker.played == 1000)
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[0].cancelled)
    }
}

/// A voice that opens each text with its own near-silence, as Pocket TTS does: `script` gives, for each text, the
/// near-silent samples before it (in chunks of 100, one every `pace`), and whether the text itself is then said as
/// near-silence (500 samples either way).
final class SentenceStream: SynthesisStream, @unchecked Sendable {
    typealias Script = @Sendable (String) -> (opening: Int, silent: Bool)
    let audio: AsyncThrowingStream<VoiceAudio, Error>
    private let texts: AsyncStream<String>.Continuation
    private let producer: Task<Void, Never>
    private let lock = NSLock()
    private var given: [String] = []
    private var stopped = false

    init(script: @escaping Script, pace: Duration = .milliseconds(1)) {
        let (audio, output) = AsyncThrowingStream.makeStream(of: VoiceAudio.self)
        let (textStream, texts) = AsyncStream.makeStream(of: String.self)
        self.audio = audio
        self.texts = texts
        producer = Task {
            var number = 0
            for await text in textStream {
                let (opening, silent) = script(text)
                for _ in 0..<(opening / 100) where !Task.isCancelled {
                    output.yield(VoiceAudio([Float](repeating: 0.0001, count: 100), text: number))
                    try? await Task.sleep(for: pace)
                }
                if Task.isCancelled { break }
                output.yield(VoiceAudio([Float](repeating: silent ? 0.0001 : 0.1, count: 500), text: number))
                number += 1
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

/// One utterance after the other, each with its script (then texts said at once); `pace`: between two chunks of an
/// opening.
actor SentenceSynthesizer: SpeechSynthesizer {
    nonisolated let outputSampleRate = 1000.0
    private var scripts: [SentenceStream.Script]
    private let pace: Duration
    private(set) var streams: [SentenceStream] = []
    init(_ scripts: [SentenceStream.Script], pace: Duration = .milliseconds(1)) {
        self.scripts = scripts
        self.pace = pace
    }

    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        var script: SentenceStream.Script = { _ in (opening: 0, silent: false) }
        if !scripts.isEmpty { script = scripts.removeFirst() }
        let stream = SentenceStream(script: script, pace: pace)
        streams.append(stream)
        return stream
    }
}

@Suite("Later sentences started again after a long near-silence")
struct LaterSentenceRestartTests {
    let audible: @Sendable ([Float]) -> Bool = { VoicePipeline.loudnessDB($0) >= -45 }
    let sentences = ["Bonjour, je suis bien là.", "La mer est salée.", "Les rivières y portent du sel."]

    /// What a voice says that can be heard: the numbers of its texts, in order.
    func heard(_ voice: VoiceRestart) async throws -> [Int?] {
        var texts: [Int?] = []
        for try await chunk in voice.audio where audible(chunk.samples) { texts.append(chunk.text) }
        return texts
    }

    func restart(_ synthesizer: SentenceSynthesizer, laterRestarts: Int = 2, resumed: @escaping @Sendable () -> Void = {})
        async throws -> VoiceRestart
    {
        let first = try await synthesizer.startUtterance(language: .french)
        return VoiceRestart(first, patience: 2000, restarts: 2, laterPatience: 1000, laterRestarts: laterRestarts,
                            audible: audible, resumed: resumed) {
            try await synthesizer.startUtterance(language: .french)
        }
    }

    /// The second sentence would open with ten seconds of near-silence; once 1000 samples of it went by, a new voice
    /// says it, and the one after it: each sentence is heard once, in order, with its number, and the first one is not
    /// said again.
    @Test func aLongOpeningStartsAgainFromThatSentence() async throws {
        let middle = sentences[1]
        let synthesizer = SentenceSynthesizer([{ ($0 == middle ? 1_000_000 : 0, false) }])
        let resumed = Flag()
        let voice = try await restart(synthesizer) { resumed.set() }
        sentences.forEach(voice.enqueue)
        voice.finish()
        let start = ContinuousClock.now
        #expect(try await heard(voice) == [0, 1, 2])
        #expect(ContinuousClock.now - start < .seconds(5))  // the first voice would have taken 10 s or more
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[0].cancelled)
        #expect(streams[1].received == Array(sentences[1...]))
        #expect(resumed.isSet)  // the language model's pause for the voice ends once the sentence is heard
    }

    /// The second sentence is said as near-silence from start to end: it is said again, then the one after it.
    @Test func aSentenceSaidAsNearSilenceIsSaidAgain() async throws {
        let middle = sentences[1]
        let synthesizer = SentenceSynthesizer([{ (0, $0 == middle) }])
        let voice = try await restart(synthesizer)
        sentences.forEach(voice.enqueue)
        voice.finish()
        #expect(try await heard(voice) == [0, 1, 2])
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[1].received == Array(sentences[1...]))
    }

    /// The answer's last sentence said as near-silence is said again too.
    @Test func theLastSentenceSaidAsNearSilenceIsSaidAgain() async throws {
        let last = sentences[2]
        let synthesizer = SentenceSynthesizer([{ (0, $0 == last) }])
        let voice = try await restart(synthesizer)
        sentences.forEach(voice.enqueue)
        voice.finish()
        #expect(try await heard(voice) == [0, 1, 2])
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[1].received == [last])
    }

    /// Text that comes while a sentence starts again is not lost, nor said twice.
    @Test func textGivenMeanwhileIsSaidOnce() async throws {
        let middle = sentences[1]
        let synthesizer = SentenceSynthesizer([{ ($0 == middle ? 100_000 : 0, false) }])
        let voice = try await restart(synthesizer)
        voice.enqueue(sentences[0])
        voice.enqueue(sentences[1])
        await waitFor { await synthesizer.streams.count >= 2 }
        voice.enqueue(sentences[2])
        voice.finish()
        #expect(try await heard(voice) == [0, 1, 2])
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[1].received == Array(sentences[1...]))
    }

    /// Each sentence starts again at most `laterRestarts` times: the last voice says it whatever its opening.
    @Test func restartsAreCountedForEachSentence() async throws {
        let (middle, last) = (sentences[1], sentences[2])
        let slow: SentenceStream.Script = { ($0 == middle || $0 == last ? 3000 : 0, false) }
        let synthesizer = SentenceSynthesizer([slow, slow, slow, slow])
        let voice = try await restart(synthesizer, laterRestarts: 1)
        sentences.forEach(voice.enqueue)
        voice.finish()
        #expect(try await heard(voice) == [0, 1, 2])
        // The second sentence once, then the third one once.
        let streams = await synthesizer.streams
        try #require(streams.count == 3)
        #expect(streams[1].received == Array(sentences[1...]))
        #expect(streams[2].received == [last])
    }

    /// Before the first sound nothing changes (`VoiceRestart`'s first rule): a near-silent opening starts again with
    /// every text, after `patience`, not `laterPatience`.
    @Test func theFirstSentenceStartsAgainAsBefore() async throws {
        let first = sentences[0]
        let synthesizer = SentenceSynthesizer([{ ($0 == first ? 1500 : 0, false) }, { ($0 == first ? 100_000 : 0, false) }])
        let voice = try await restart(synthesizer)
        sentences.forEach(voice.enqueue)
        voice.finish()
        #expect(try await heard(voice) == [0, 1, 2])
        #expect(await synthesizer.streams.count == 1)  // 1500 samples: under the first sentence's patience
        let silent = SentenceSynthesizer([{ ($0 == first ? 100_000 : 0, false) }])
        let again = try await restart(silent)
        sentences.forEach(again.enqueue)
        again.finish()
        #expect(try await heard(again) == [0, 1, 2])
        let streams = await silent.streams
        try #require(streams.count == 2)
        #expect(streams[1].received == sentences)
    }

    @Test func cancellingStopsASentenceStartingAgain() async throws {
        let synthesizer = SentenceSynthesizer([{ ($0 == "Bonjour." ? 0 : 100_000, false) }, { _ in (100_000, false) }])
        let voice = try await restart(synthesizer)
        voice.enqueue("Bonjour.")
        voice.enqueue("La mer est salée.")
        await waitFor { await synthesizer.streams.count >= 2 }
        await voice.cancel()
        for try await _ in voice.audio {}
        try await Task.sleep(for: .milliseconds(30))  // a voice starting again meanwhile shows up
        await waitFor { await synthesizer.streams.allSatisfy { $0.cancelled } }
        let streams = await synthesizer.streams
        #expect(streams.allSatisfy { $0.cancelled })
        #expect(streams.count >= 2 && streams.count <= 3)
    }

    /// Without `laterPatience`, a long opening is waited for; a sentence said as near-silence is still said again.
    @Test func withoutPatienceOnlyANearSilentSentenceStartsAgain() async throws {
        let (middle, last) = (sentences[1], sentences[2])
        let synthesizer = SentenceSynthesizer([{ ($0 == middle ? 3000 : 0, $0 == last) }])
        let first = try await synthesizer.startUtterance(language: .french)
        let voice = VoiceRestart(first, patience: 2000, restarts: 2, laterRestarts: 2, audible: audible) {
            try await synthesizer.startUtterance(language: .french)
        }
        sentences.forEach(voice.enqueue)
        voice.finish()
        #expect(try await heard(voice) == [0, 1, 2])
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[1].received == [last])
    }

    /// In the pipeline, with `sentenceRestartAfterSeconds`: the answer's second sentence would open with seconds of
    /// near-silence; it is heard soon after the first one, from a voice started again with it alone.
    @Test func thePipelineStartsALaterSentenceAgain() async throws {
        var config = PipelineConfig()
        config.sentenceRestartAfterSeconds = 0.6
        let synthesizer = SentenceSynthesizer([{ ($0.contains("Comment") ? 1_000_000 : 0, false) }])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker, config: config)
        try await pipeline.start()
        let start = ContinuousClock.now
        await pipeline.submit(text: "Bonjour")
        // The first sentence (500 samples), the second one's opening until the voice starts again (500: after the first
        // sound the near-silence is played), then the second sentence from the new voice (500). Waiting for 1000 alone
        // could end before the new voice is there.
        await waitFor { await speaker.played >= 1500 }
        #expect(await speaker.played >= 1500)  // both sentences
        #expect(ContinuousClock.now - start < .seconds(5))  // the silent opening would have taken 10 s or more
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[0].cancelled)
        #expect(streams[1].received.count == 1)
        #expect(streams[1].received.first?.contains("Comment") == true)
    }

    /// In the pipeline as configured by default: the answer's second sentence, said as near-silence, is said again;
    /// a long opening is waited for.
    @Test func thePipelineSaysAgainASentenceSaidAsNearSilence() async throws {
        let synthesizer = SentenceSynthesizer([{ (0, $0.contains("Comment")) }])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker)
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        // The first sentence, the second one said as near-silence (played: it comes after the first sound), then said
        // again: 500 samples each. Waiting for 1000 alone could end before the new voice has the sentence.
        await waitFor { await speaker.played >= 1500 }
        #expect(await speaker.played >= 1500)  // both sentences heard
        let streams = await synthesizer.streams
        try #require(streams.count == 2)
        #expect(streams[1].received.count == 1)
        #expect(streams[1].received.first?.contains("Comment") == true)

        let slow = SentenceSynthesizer([{ ($0.contains("Comment") ? 2000 : 0, false) }])
        let other = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                  model: ScriptedModel(), synthesizer: slow, output: FakeSpeaker())
        try await other.start()
        await other.submit(text: "Bonjour")
        await waitFor { await slow.streams.first?.received.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await slow.streams.count == 1)
    }

    /// With `sentenceRestarts` at 0, nothing starts again after the first sound: a sentence said as near-silence is
    /// lost, as it was before.
    @Test func theRuleCanBeTurnedOff() async throws {
        var config = PipelineConfig()
        config.sentenceRestarts = 0
        let synthesizer = SentenceSynthesizer([{ (0, $0.contains("Comment")) }])
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(), synthesizer: synthesizer, output: speaker, config: config)
        try await pipeline.start()
        await pipeline.submit(text: "Bonjour")
        await waitFor { await synthesizer.streams.first?.received.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await synthesizer.streams.count == 1)
    }
}

/// Set once, from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
