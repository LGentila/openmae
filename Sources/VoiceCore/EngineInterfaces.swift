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
        calls([call])
    }

    /// The tool calls the assistant wrote one after the other in one answer, as they go into the history: one message,
    /// followed by their results in the same order (`result(of:_:)`), as Gemma 4's template renders them and the model
    /// wrote them (all its calls, then all their results).
    public static func calls(_ calls: [ToolCall]) -> ChatMessage {
        var message = ChatMessage(.assistant, "")
        message.toolCalls = calls
        return message
    }

    /// What the tool returned, right after the call. Without the model's own marks (`ModelMarkers`), whatever the tool:
    /// a text from outside in it cannot pass for the end of the result and the start of something else.
    public static func result(of call: ToolCall, _ result: JSONValue) -> ChatMessage {
        var message = ChatMessage(.tool, call.name)
        message.toolResult = ModelMarkers.strip(result)
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
    /// After the call just reported, the model went on to another one (the user asked for several things at once) while
    /// it had written as many calls as the app carries out in one request (`LanguageModel.limitToolCalls`): the answer
    /// ends there, without that call, and the app says how many things it does at a time.
    case moreToolCalls
}

/// How an answer begins (`LanguageModel.reply(to:opening:)`).
public enum AnswerOpening: Sendable, Equatable {
    /// As the model writes it.
    case free
    /// With a tool call: the answer's first token opens one, whatever chance the model gave it; the model writes the call
    /// itself, and what follows. A model without tools, or that writes no calls of its own, answers as it would.
    case toolCall
}

/// The conversational model.
///
/// Implementations keep the model's working memory (KV cache) between calls and only process what
/// changed since the previous call, so `reply` stays fast turn after turn. A cancelled reply (the user
/// interrupted, or a speculative turn was abandoned) must leave the model usable for the next call.
public protocol LanguageModel: Sendable {
    /// Streams the answer to the conversation, piece by piece. Cancel the consuming task to stop.
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error>
    /// The same, the answer opening as `opening` says. By default `reply(to:)`, whatever the opening.
    func reply(to conversation: [ChatMessage], opening: AnswerOpening) -> AsyncThrowingStream<ModelOutput, Error>
    /// The tools the model may call. They are part of the system prompt: change them only between
    /// conversations, then `prefillBeginning` again.
    func useTools(_ tools: [ToolSpec]) async
    /// How many calls an answer may write one after the other (1: the first one only), the calls the app carries out in
    /// one request: past them, the answer ends with `ModelOutput.moreToolCalls`.
    func limitToolCalls(_ count: Int) async
    /// A tool call written the way this model writes it, to show it an example in its instructions; nil when
    /// it has no such written form.
    func toolCallText(_ call: ToolCall) async -> String?
    /// Processes the conversation without answering (e.g. the conversation so far, once the tools changed).
    func prefill(_ conversation: [ChatMessage]) async throws
    /// The history as the next request will start, once an exchange is recorded. A model that keeps its working memory
    /// between requests computes now what of it that memory no longer matches (an answer cut off, or recorded otherwise
    /// than the model wrote it), while nobody waits for an answer; and so a history that ends with a note rather than an
    /// answer (`Conversation.cutOffMessage`, the note read ahead: the user speaks over the answer, and their request comes
    /// as soon as they stop). What the model never wrote, after what its memory holds (an announcement, a tool's result
    /// and the app's own sentences), it computes in the background, while that is allowed (`allowBackgroundWork`), and it
    /// gives way to any request sent meanwhile, which then computes the rest. Nothing when the memory holds the history
    /// (or went past it), or when only the end of an answer the model wrote follows. Returns once done, or given up.
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
    /// Background work may use the GPU only while this is true (the pipeline turns it off while someone
    /// speaks or the assistant is thinking or speaking, so the voice never stutters).
    func allowBackgroundWork(_ allowed: Bool) async
    /// The chance the model gave to opening a tool call at the first token of the answer it is writing (or of the last
    /// one it wrote), whatever it then wrote: whether it meant to call a tool from the start. Known once that answer
    /// opens a call after text of its own (from that `ModelOutput.toolCallStarted` on), readable while it is written;
    /// nil otherwise, or when the model does not tell.
    var callChanceAtStart: Double? { get }
}

extension LanguageModel {
    public func reply(to conversation: [ChatMessage], opening: AnswerOpening) -> AsyncThrowingStream<ModelOutput, Error> {
        reply(to: conversation)
    }
    public var callChanceAtStart: Double? { nil }
    public func useTools(_ tools: [ToolSpec]) async {}
    public func limitToolCalls(_ count: Int) async {}
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
    /// Someone started to speak (a request may follow within a second or two), or the conversation is about to start:
    /// brings back now what macOS pushed out of memory since the last `keepWarm()`, so that the request does not wait
    /// for it. Returns at once; cheap when nothing was pushed out.
    func wakeUp()
}

extension KeepsWarm {
    public func wakeUp() {}
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
    /// Audio chunks, in order, each with the text it says.
    var audio: AsyncThrowingStream<VoiceAudio, Error> { get }
    /// Stops generation immediately (barge-in). Returns once no more audio will be produced.
    func cancel() async
}

/// A chunk of a voice's audio, and the text it says: the pipeline knows from it which sentence of an answer was being
/// said when the device that plays it went out of reach (`VoicePipeline.setOutputReachable`).
public struct VoiceAudio: Sendable, Equatable {
    /// Mono Float32 at the voice's `outputSampleRate`.
    public var samples: [Float]
    /// The text it says: which `enqueue` call gave it, counted from 0 (blank texts included); nil when the voice cannot
    /// tell.
    public var text: Int?

    public init(_ samples: [Float], text: Int? = nil) {
        self.samples = samples
        self.text = text
    }
}

/// How the playback of what an output was given ended (`AudioOutput.waitUntilDone`).
public enum PlaybackEnd: Sendable, Equatable {
    /// Played to its end, or stopped as asked (`stopImmediately`).
    case confirmed
    /// The device that plays it never said it did: its connection dropped, or it let go of the conversation meanwhile.
    /// The user may have heard none of it, or only part.
    case unconfirmed
}

/// Where the assistant's voice goes: the speakers in the app, a recorder in the CLI, an iPhone through the link.
public protocol AudioOutput: Sendable {
    /// Queues audio for playback and returns quickly (playback continues in the background).
    func play(_ samples: [Float], sampleRate: Double) async
    /// Returns when everything queued has been played (or stopped), and whether that is sure: the Mac's speakers always
    /// know, a device at the other end of a connection only once it says so.
    @discardableResult func waitUntilDone() async -> PlaybackEnd
    /// Barge-in: silence now, drop anything queued.
    func stopImmediately() async
    /// The device that plays the voice went out of reach (its connection dropped): what is being given to it is dropped
    /// without telling it, so that what it already has it still plays (it could not be told to stop anyway), and the
    /// next sound starts anew. Whoever waits for the end of the playback is let go. Speakers that are always within reach
    /// stop, as for a barge-in.
    func abandon() async
}

extension AudioOutput {
    public func abandon() async { await stopImmediately() }
}
