import Foundation

// The four engine stages, as interfaces. The pipeline only talks to these protocols, so each stage
// can be swapped (another model, another platform, a premium extension) without touching the rest.
// Implementations for Apple Silicon live in the VoiceEngineApple target.

/// Microphone audio format used everywhere in the engine: 16 kHz, mono, Float32 in [-1, 1].
public enum EngineAudio {
    public static let inputSampleRate = 16_000.0
}

public enum SpeechLanguage: String, Sendable, Codable, CaseIterable {
    case french = "fr"
    case english = "en"
}

/// Voice activity detection: "is someone speaking in this short chunk of audio?"
public protocol SpeechDetector: Sendable {
    /// Number of samples the detector consumes per call (512 = 32 ms at 16 kHz for Silero).
    var chunkSize: Int { get }
    /// Probability (0…1) that the chunk contains speech. Stateful: chunks must arrive in order.
    func speechProbability(_ chunk: [Float]) async throws -> Float
    /// Forget the recurrent state (call between unrelated audio streams).
    func reset() async
}

/// Speech-to-text for one finished utterance.
public protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// The conversational model.
///
/// Implementations keep the model's working memory (KV cache) between calls and only process what
/// changed since the previous call, so `reply` stays fast turn after turn. A cancelled reply (the user
/// interrupted, or a speculative turn was abandoned) must leave the model usable for the next call.
public protocol LanguageModel: Sendable {
    /// Streams the answer to the conversation, piece by piece. Cancel the consuming task to stop.
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    /// Processes the conversation without answering (e.g. the system prompt at launch).
    func prefill(_ conversation: [ChatMessage]) async throws
    /// Size of the conversation in model tokens (used to keep it inside the context window).
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int
    /// Prepares a shortened history (oldest exchanges dropped) in the background and returns once it is
    /// ready. Meanwhile the caller keeps sending the full history, which the current memory serves.
    func prepareShortenedHistory(_ conversation: [ChatMessage]) async throws
    /// Background work may use the GPU only while this is true (the pipeline turns it off while the
    /// assistant is thinking or speaking, so the voice never stutters).
    func allowBackgroundWork(_ allowed: Bool) async
}

extension LanguageModel {
    public func prepareShortenedHistory(_ conversation: [ChatMessage]) async throws { try await prefill(conversation) }
    public func allowBackgroundWork(_ allowed: Bool) async {}
}

/// A stage whose model macOS may push out of memory after a quiet moment, when the Mac runs short
/// of memory: the next answer then takes seconds instead of a fraction of a second (seen in the app
/// on the reference Mac: 4.2 s instead of 0.25 s after 2½ minutes of silence). `keepWarm()` uses the
/// model briefly so that it stays in memory; the pipeline calls it regularly while nobody speaks.
public protocol KeepsWarm: Sendable {
    func keepWarm() async
}

/// A language model that can pause its generation while the voice starts. Both share the GPU: while
/// the model writes the rest of the answer, the voice needed 0.7–2 s instead of ~0.3 s to produce its
/// first audible sound (measured on the reference Mac). The model is far ahead of speech anyway.
public protocol YieldsToVoice: Sendable {
    /// Callable from any thread, even while the model is generating.
    func holdGeneration(_ held: Bool)
}

/// Text-to-speech, streaming: text goes in sentence by sentence, audio comes out as it is produced.
public protocol SpeechSynthesizer: Sendable {
    var outputSampleRate: Double { get }
    /// Starts an utterance. Heavy per-utterance work may happen here, ahead of the first text.
    func startUtterance(language: SpeechLanguage) async throws -> any SynthesisStream
}

public protocol SynthesisStream: Sendable {
    func enqueue(_ text: String)
    /// No more text: the audio stream ends once everything enqueued has been spoken.
    func finish()
    /// Audio chunks (mono Float32 at `outputSampleRate`), in order.
    var audio: AsyncThrowingStream<[Float], Error> { get }
    /// Stops generation immediately (barge-in). Returns once no more audio will be produced.
    func cancel() async
}

/// Where the assistant's voice goes: the speakers in the app, a recorder in the CLI.
public protocol AudioOutput: Sendable {
    /// Queues audio for playback and returns quickly (playback continues in the background).
    func play(_ samples: [Float], sampleRate: Double) async
    /// Returns when everything queued has been played (or stopped).
    func waitUntilDone() async
    /// Barge-in: silence now, drop anything queued.
    func stopImmediately() async
}
