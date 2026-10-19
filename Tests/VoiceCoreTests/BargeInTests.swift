import Foundation
import Testing

@testable import VoiceCore

/// What it takes to interrupt Maé depends on the device that has the conversation (`BargeInProfile`): on the Mac as
/// before; on an iPhone, her louder echo is not taken for the user. The pipeline on the fake stages of PipelineTests:
/// a chunk with a sample above 0.05 is speech, and the voice plays one sample per millisecond.
@Suite("Barge-in profiles", .serialized)
struct BargeInTests {
    /// A chunk taken for speech, at `db` dB (from -45 to -25): 0.06 in its first samples, then silence.
    static func voice(atDB db: Float) -> [Float] {
        let samples = Int((512 * pow(10, db / 10) / (0.06 * 0.06)).rounded())
        return (0..<512).map { $0 < samples ? 0.06 : 0 }
    }

    let loud = [Float](repeating: 0.5, count: 512)  // -6 dB
    let silence = [Float](repeating: 0, count: 512)

    /// A pipeline saying a long answer (about 10 s) where the conversation is, with `profile`; nil: as configured
    /// (the Mac's).
    func speaking(_ profile: BargeInProfile?) async throws -> (VoicePipeline, FakeSpeaker, EventRecorder) {
        let long = (1...20).map { "Phrase numéro \($0) de la réponse. " }
        let speaker = FakeSpeaker()
        let pipeline = VoicePipeline(detector: LoudnessDetector(), transcriber: CountingTranscriber(),
                                     model: ScriptedModel(answer: long), synthesizer: FakeSynthesizer(), output: speaker)
        let log = EventRecorder()
        Task { for await event in pipeline.events { await log.record(event) } }
        try await pipeline.start()
        if let profile { await pipeline.setBargeIn(profile) }
        for _ in 0..<10 { await pipeline.push(loud) }  // the question
        for _ in 0..<20 { await pipeline.push(silence) }
        await waitFor { await speaker.played > 0 }
        try await Task.sleep(for: .milliseconds(50))
        return (pipeline, speaker, log)
    }

    /// `chunk`, `count` times over Maé's voice, then silence; true when it interrupted her.
    func say(_ chunk: [Float], _ count: Int, to pipeline: VoicePipeline, _ log: EventRecorder) async throws -> Bool {
        for _ in 0..<count { await pipeline.push(chunk) }
        for _ in 0..<5 { await pipeline.push(silence) }
        try await Task.sleep(for: .milliseconds(100))
        return await log.bargeIns > 0
    }

    func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<400 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aVoiceOver224msStopsHerOnTheMac() async throws {
        let (pipeline, speaker, log) = try await speaking(nil)
        #expect(await pipeline.config.bargeIn == .mac)
        #expect(try await !say(loud, 6, to: pipeline, log))  // 192 ms: a burst of her echo
        #expect(try await say(loud, 7, to: pipeline, log))  // 224 ms
        #expect(await speaker.stops >= 1)
        await pipeline.stop()
    }

    /// On the Mac, a voice at -33 dB is the user's: what her echo reached on the iPhone, the bug of issue 47.
    @Test func aQuietVoiceStopsHerOnTheMac() async throws {
        let (pipeline, _, log) = try await speaking(nil)
        #expect(try await say(Self.voice(atDB: -33), 8, to: pipeline, log))
        await pipeline.stop()
    }

    @Test func herEchoAtMinus33dBDoesNotStopHerOnTheIPhone() async throws {
        let (pipeline, speaker, log) = try await speaking(.iPhone)
        #expect(try await !say(Self.voice(atDB: -33), 30, to: pipeline, log))  // about 1 s of it
        #expect(await speaker.stops == 0)
        #expect(await speaker.remainingMs > 1000)  // she goes on
        #expect(try await say(Self.voice(atDB: -27), 9, to: pipeline, log))  // louder: the user
        await pipeline.stop()
    }

    @Test func theIPhoneTakesAVoiceOf288ms() async throws {
        let (pipeline, _, log) = try await speaking(.iPhone)
        #expect(try await !say(loud, 8, to: pipeline, log))  // 256 ms
        #expect(try await say(loud, 9, to: pipeline, log))  // 288 ms
        await pipeline.stop()
    }

    @Test func backToTheMacsProfile() async throws {
        let (pipeline, _, log) = try await speaking(.iPhone)
        await pipeline.setBargeIn(.mac)
        #expect(try await say(loud, 7, to: pipeline, log))
        await pipeline.stop()
    }

    @Test func valuesToTryFromTheEnvironment() {
        let tried = BargeInProfile.iPhone.adjusted(by: ["TRY_DB": "-28", "TRY_MS": "320"], prefix: "TRY")
        #expect(tried.minLevelDB == -28)
        #expect(tried.minSpeechMs == 320)
        #expect(tried.device.hasPrefix("iPhone"))
        #expect(BargeInProfile.iPhone.adjusted(by: [:], prefix: "TRY") == .iPhone)
        #expect(BargeInProfile.iPhone.adjusted(by: ["TRY_DB": "loud", "TRY_MS": "-5"], prefix: "TRY") == .iPhone)
    }
}
