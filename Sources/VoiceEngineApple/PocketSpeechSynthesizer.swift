import FluidAudio
import Foundation
import VoiceCore

/// Text-to-speech with Kyutai's Pocket TTS (CC-BY-4.0 weights, MIT code), CoreML export by
/// FluidInference, run through FluidAudio. French voice "estelle" (chosen by ear).
///
/// Measured on an M1 Pro: on the GPU, first audio 0.16–0.26 s and 1.2–1.3× faster than
/// real time; on the Neural Engine it is SLOWER (1.2 s, ×1.0) and needs a 9–12 min compilation on
/// first launch. So the default here is "no Neural Engine".
public actor PocketSpeechSynthesizer: SpeechSynthesizer, KeepsWarm {
    public nonisolated let outputSampleRate = 24_000.0

    public static let voices: [SpeechLanguage: String] = [.french: "estelle", .english: "alba"]
    private static let packs: [SpeechLanguage: PocketTtsLanguage] = [.french: .french24L, .english: .english]

    private let computeUnits: PocketTtsComputeUnits
    private let directory: URL?
    private var managers: [SpeechLanguage: PocketTtsManager] = [:]
    private var lastLanguage = SpeechLanguage.french
    private var warmRounds = 0

    /// - Parameters:
    ///   - computeUnits: `.avoidNeuralEngine` (GPU + CPU, default) or `.uniform(.cpuOnly)` to leave the
    ///     GPU entirely to the language model.
    ///   - directory: where the models are (FluidAudio's default cache when nil).
    public init(computeUnits: PocketTtsComputeUnits = .avoidNeuralEngine, directory: URL? = nil) {
        self.computeUnits = computeUnits
        self.directory = directory
    }

    /// Loads (and warms up) the voices for these languages now rather than at their first use.
    public func preload(_ languages: [SpeechLanguage]) async throws {
        for language in languages { _ = try await manager(for: language) }
    }

    public func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream {
        lastLanguage = language
        let manager = try await manager(for: language)
        return PocketStream(session: try await manager.makeSession(voice: Self.voices[language]))
    }

    /// Speaks a word into the void, so that macOS keeps the voice in memory: the voice of the current
    /// language every time, the other ones every fourth time (each costs ~0.4 s of GPU).
    public func keepWarm() async {
        let start = ContinuousClock.now
        warmRounds += 1
        for (language, manager) in managers where language == lastLanguage || warmRounds % 4 == 0 {
            try? await Self.speakSilently(language == .french ? "Oui." : "Yes.", manager: manager, language: language)
        }
        DebugLog.log("TTS: kept warm in \(ContinuousClock.now - start)")
    }

    private static func speakSilently(_ text: String, manager: PocketTtsManager, language: SpeechLanguage)
        async throws
    {
        let session = try await manager.makeSession(voice: voices[language])
        session.enqueue(text)
        session.finish()
        for try await _ in session.frames {}
    }

    private func manager(for language: SpeechLanguage) async throws -> PocketTtsManager {
        if let manager = managers[language] { return manager }
        let manager = PocketTtsManager(
            defaultVoice: Self.voices[language]!, language: Self.packs[language]!, directory: directory,
            computeUnits: computeUnits)
        try await manager.initialize()
        // Warm-up: the first synthesis compiles GPU kernels.
        try await Self.speakSilently(language == .french ? "Bonjour." : "Hello.", manager: manager, language: language)
        managers[language] = manager
        return manager
    }
}

/// One spoken answer: text goes in sentence by sentence, 80 ms audio frames come out.
struct PocketStream: SynthesisStream {
    let session: PocketTtsSession
    let audio: AsyncThrowingStream<[Float], Error>

    init(session: PocketTtsSession) {
        self.session = session
        audio = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in session.frames { continuation.yield(frame.samples) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func enqueue(_ text: String) { session.enqueue(text) }
    func finish() { session.finish() }
    func cancel() async { await session.cancel() }
}
