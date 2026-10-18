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
    private let directory: URL
    private var managers: [SpeechLanguage: PocketTtsManager] = [:]
    private var lastLanguage = SpeechLanguage.french
    private var warmRounds = 0

    /// - Parameters:
    ///   - computeUnits: `.avoidNeuralEngine` (GPU + CPU, default) or `.uniform(.cpuOnly)` to leave the
    ///     GPU entirely to the language model.
    ///   - store: the models folder, where the downloader put the voice with FluidAudio's layout. Every
    ///     file FluidAudio looks for is there, so it never goes online.
    public init(computeUnits: PocketTtsComputeUnits = .avoidNeuralEngine, store: ModelStore) {
        self.computeUnits = computeUnits
        self.directory = store.voiceBaseFolder
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
        let trace = DebugLog.enabled ? VoiceTrace(label: "TTS kept warm") : nil
        trace?.enqueued(text)
        session.enqueue(text)
        session.finish()
        for try await frame in session.frames { trace?.received(frame) }
        trace?.ended()
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
    private let trace: VoiceTrace?

    init(session: PocketTtsSession) {
        self.session = session
        let trace = DebugLog.enabled ? VoiceTrace() : nil
        self.trace = trace
        audio = AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in session.frames {
                        trace?.received(frame)
                        continuation.yield(frame.samples)
                    }
                    trace?.ended()
                    continuation.finish()
                } catch {
                    trace?.ended()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func enqueue(_ text: String) {
        trace?.enqueued(text)
        session.enqueue(text)
    }

    func finish() { session.finish() }

    func cancel() async {
        trace?.cancelled()
        await session.cancel()
    }
}

/// Diagnostics (VOICE_DEBUG=1): for each sentence the voice speaks, how long its first frame took, how many near-silent
/// frames came before the first audible one and how fast the frames came; or that it stayed silent from start to end.
final class VoiceTrace: @unchecked Sendable {
    /// Quieter than this (dB) is near-silence, as for the pipeline (`PipelineConfig.leadingSilenceThresholdDB`).
    static let audibleDB: Float = PipelineConfig().leadingSilenceThresholdDB ?? -45

    private struct Sentence {
        var index: Int
        var words: Int
        /// When the voice could start on it: its text given, and the sentence before it done.
        var start: ContinuousClock.Instant
        var firstFrame: ContinuousClock.Instant?
        var lastFrame: ContinuousClock.Instant?
        var frames = 0
        var quietFrames = 0
        var audible = false
        var loudest: Float = -120
    }

    private let label: String
    private let lock = NSLock()
    private let clock = ContinuousClock()
    // Guarded by `lock`.
    private var given: [(words: Int, at: ContinuousClock.Instant)] = []
    private var current: Sentence?
    private var stopped = false

    init(label: String = "TTS") { self.label = label }

    func enqueued(_ text: String) {
        // FluidAudio skips the texts that are only white space, and counts the others.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock { given.append((trimmed.split(separator: " ").count, clock.now)) }
    }

    func received(_ frame: PocketTtsSynthesizer.AudioFrame) {
        let now = clock.now
        let level = Self.loudnessDB(frame.samples)
        lock.withLock {
            let index = frame.utteranceIndex ?? 0
            if current?.index != index {
                let previousEnd = current?.lastFrame
                close()
                let text: (words: Int, at: ContinuousClock.Instant) = index < given.count ? given[index] : (0, now)
                current = Sentence(index: index, words: text.words, start: max(text.at, previousEnd ?? text.at))
            }
            guard var s = current else { return }
            if s.firstFrame == nil { s.firstFrame = now }
            s.lastFrame = now
            s.frames += 1
            s.loudest = max(s.loudest, level)
            if !s.audible {
                if level < Self.audibleDB {
                    s.quietFrames += 1
                } else {
                    s.audible = true
                    let first = s.firstFrame ?? now
                    let pace = s.frames > 1 ? Self.ms(now - first) / Double(s.frames - 1) : 0
                    DebugLog.log(String(
                        format: "%@: sentence %d (%d words) audible at frame %d after %d near-silent (%.2f s of audio),"
                            + " %.0f ms after its text; first frame after %.0f ms, then %.0f ms per frame",
                        label, s.index + 1, s.words, s.frames, s.quietFrames, Double(s.quietFrames) * 0.08,
                        Self.ms(now - s.start), Self.ms(first - s.start), pace))
                }
            }
            current = s
        }
    }

    func ended() { lock.withLock { close() } }

    /// Stopped before its end (an interruption, or another voice audible sooner).
    func cancelled() { lock.withLock { stopped = true } }

    /// Reports a sentence that ended without an audible frame. Called with `lock` held.
    private func close() {
        guard let s = current, !s.audible, let first = s.firstFrame, let last = s.lastFrame else { return }
        if stopped {
            DebugLog.log(String(
                format: "%@: sentence %d stopped after %d near-silent frames (%.2f s of audio), %.0f ms after its text",
                label, s.index + 1, s.frames, Double(s.frames) * 0.08, Self.ms(last - s.start)))
            return
        }
        DebugLog.log(String(
            format: "%@: sentence %d (%d words) silent throughout: %d frames (%.2f s of audio, loudest %.0f dB) in"
                + " %.0f ms after its text; first frame after %.0f ms",
            label, s.index + 1, s.words, s.frames, Double(s.frames) * 0.08, s.loudest, Self.ms(last - s.start),
            Self.ms(first - s.start)))
    }

    static func loudnessDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(max(meanSquare, 1e-12))
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
