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
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    /// Assistant: the tool calls it wrote.
    public var toolCalls: [ToolCall] = []
    /// Tool: the result of the call written in the assistant message just before.
    public var toolResult: JSONValue?

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }

    /// The assistant's tool call, as it goes into the history.
    public static func call(_ call: ToolCall) -> ChatMessage {
        var message = ChatMessage(.assistant, "")
        message.toolCalls = [call]
        return message
    }

    /// What the tool returned, right after the call.
    public static func result(of call: ToolCall, _ result: JSONValue) -> ChatMessage {
        var message = ChatMessage(.tool, call.name)
        message.toolResult = result
        return message
    }

    private enum CodingKeys: String, CodingKey { case role, content, toolCalls, toolResult }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolResult = try c.decodeIfPresent(JSONValue.self, forKey: .toolResult)
    }
}

/// What the language model writes: text for the voice, or a tool call.
public enum ModelOutput: Sendable, Equatable {
    case text(String)
    /// A tool call has begun: no text for the voice until it is complete.
    case toolCallStarted
    /// The call's tool, as soon as the model has written its name (a few tokens after `toolCallStarted`).
    case toolCallNamed(String)
    case toolCall(ToolCall)
    /// A call the model wrote but that could not be read (the raw text, for the model's second try).
    case unreadableToolCall(String)
}

/// The conversational model.
///
/// Implementations keep the model's working memory (KV cache) between calls and only process what
/// changed since the previous call, so `reply` stays fast turn after turn. A cancelled reply (the user
/// interrupted, or a speculative turn was abandoned) must leave the model usable for the next call.
public protocol LanguageModel: Sendable {
    /// Streams the answer to the conversation, piece by piece. Cancel the consuming task to stop.
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error>
    /// The tools the model may call. They are part of the system prompt: change them only between
    /// conversations, then `prefillBeginning` again.
    func useTools(_ tools: [ToolSpec]) async
    /// A tool call written the way this model writes it, to show it an example in its instructions; nil when
    /// it has no such written form.
    func toolCallText(_ call: ToolCall) async -> String?
    /// Processes the conversation without answering (e.g. the conversation so far, once the tools changed).
    func prefill(_ conversation: [ChatMessage]) async throws
    /// The history as the next request will start, once an exchange is recorded. A model that keeps its working memory
    /// between requests computes now what of it that memory no longer matches (an answer cut off, or recorded otherwise
    /// than the model wrote it), while nobody waits for an answer; nothing when the memory holds it (or went past it),
    /// or when the history only goes on from what the memory holds.
    func catchUp(with conversation: [ChatMessage]) async
    /// Processes the beginning every conversation starts with (`Conversation.beginning`: the system prompt, and the
    /// example exchanges when there are) and keeps it, so that a new conversation starts from it without computing it
    /// again. Call it again whenever that beginning changes.
    func prefillBeginning(_ beginning: [ChatMessage]) async throws
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
    public func useTools(_ tools: [ToolSpec]) async {}
    public func toolCallText(_ call: ToolCall) async -> String? { nil }
    public func catchUp(with conversation: [ChatMessage]) async {}
    public func prefillBeginning(_ beginning: [ChatMessage]) async throws { try await prefill(beginning) }
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
