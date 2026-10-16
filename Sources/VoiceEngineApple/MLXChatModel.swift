import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import VoiceCore

/// The conversational model (Gemma 4 by default) running on the GPU with MLX.
///
/// Why not mlx-swift-lm's `ChatSession`: it cannot drop a turn once started, which the pipeline needs
/// (a speculative answer abandoned because the user kept talking), nor shorten the history. So this
/// class manages the model's working memory (the KV cache) itself, with one simple rule:
///
///   every request is rendered to tokens in full; the part already in the cache is skipped; if the
///   cache holds tokens that are no longer wanted (abandoned turn, trimmed history), it is rewound —
///   or rebuilt from scratch when the model cannot rewind (Gemma's sliding-window layers past 1024
///   tokens).
///
/// Measured effect on the reference Mac (M1 Pro): 0.3–0.5 s to first token on later turns instead of
/// 0.6–0.9 s.
public actor MLXChatModel: VoiceCore.LanguageModel, KeepsWarm, YieldsToVoice {
    private let context: ModelContext
    private let tokenizer: any Tokenizers.Tokenizer
    private let chatTemplate: String?
    private let parameters: GenerateParameters
    private let stopTokens: Set<Int>
    /// Gemma 4 writes a tool call between these two tokens: `<|tool_call>call:name{…}<tool_call|>`.
    private let toolCallStart: Int?
    private let toolCallEnd: Int?
    /// The tools, as the chat template wants them (in the system turn).
    private var tools: [VoiceCore.ToolSpec] = []
    private var toolSchemas: [[String: any Sendable]]?
    /// The arguments of recent calls exactly as the model wrote them, so that the history renders them
    /// identically and the cache stays valid.
    private var rawArguments: [VoiceCore.ToolCall: String] = [:]
    private var cache: [KVCache]
    private var cachedTokens: [Int] = []
    /// Copy of the cache taken just before the last request's new tokens were fed in. Copies share
    /// the underlying memory until one side changes, so this costs almost nothing.
    private var snapshot: (tokens: [Int], cache: [KVCache])?
    /// A shortened history being computed in the background, in a second cache, chunk by chunk.
    private var rebuild: (tokens: [Int], cache: [KVCache], done: Int)?
    private var rebuildTask: Task<Void, Never>?
    private var backgroundAllowed = true
    /// Set from outside while a generation runs (the actor is busy then), hence a lock, not the actor.
    private nonisolated let hold = GenerationHold()
    // Note: "wiring" the weights in memory (MLX WiredMemoryTicket) was tried against a
    // one-off 2.6 s slowdown; it made every turn SLOWER on the reference Mac (0.5–0.65 s instead of
    // 0.28 s to process a new turn), so it is not used.

    /// Diagnostics: how many times the cache had to be rebuilt from scratch.
    public private(set) var cacheRebuilds = 0
    /// Diagnostics of the last request: tokens found in the cache, tokens computed, and time to compute them.
    public private(set) var lastPrefill = (reused: 0, computed: 0, ms: 0.0)
    /// Benchmark diagnostics, off in the app (reading a probability at every token slows generation a little).
    private var watchingToolCalls = false
    /// With `watchToolCalls(true)`, for the last request: the chance the model gave to opening a tool call at the
    /// first token of its answer, and at its most tempted token before any call (`bestAt`: index in the answer).
    public private(set) var lastToolCallChances: (first: Double, best: Double, bestAt: Int)?
    /// With `watchToolCalls(true)`: the last answer exactly as the model wrote it, special tokens included.
    public private(set) var lastRawAnswer = ""

    /// Template variables: no hidden "thinking" before answering (it would delay the voice).
    private let templateContext: [String: any Sendable] = ["enable_thinking": false]

    private init(context: ModelContext, tokenizer: any Tokenizers.Tokenizer, chatTemplate: String?,
                 parameters: GenerateParameters) throws
    {
        self.context = context
        self.tokenizer = tokenizer
        self.chatTemplate = chatTemplate
        self.parameters = parameters
        var stops = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
        }
        stopTokens = stops
        toolCallStart = tokenizer.convertTokenToId("<|tool_call>")
        toolCallEnd = tokenizer.convertTokenToId("<tool_call|>")
        cache = try context.model.newCache(parameters: parameters)
    }

    /// Loads an MLX model folder (config.json, *.safetensors, tokenizer files, chat template).
    /// Gives back to macOS the GPU memory MLX keeps for reuse, once a model has been released (tier change,
    /// models deleted).
    public static func releaseCachedMemory() {
        Memory.clearCache()
    }

    public static func load(directory: URL, maxAnswerTokens: Int = 400) async throws -> MLXChatModel {
        let context = try await LLMModelFactory.shared.load(from: directory, using: TokenizerLoaderBridge())
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        let template = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"),
                                   encoding: .utf8)
        let parameters = GenerateParameters(maxTokens: maxAnswerTokens, temperature: 0.7, topP: 0.9)
        let model = try MLXChatModel(context: context, tokenizer: tokenizer,
                                     chatTemplate: template.map { GemmaTemplateFix.patched($0) ?? $0 },
                                     parameters: parameters)
        try await model.warmUp()
        return model
    }

    // MARK: - VoiceCore.LanguageModel

    public nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { continuation in
            let requested = ContinuousClock.now
            let task = Task {
                do {
                    DebugLog.log("LLM: waiting for the model (\(ContinuousClock.now - requested))")
                    try await self.generate(conversation) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `async` like the protocol's default: a synchronous version would lose to that default in async callers.
    public func useTools(_ tools: [VoiceCore.ToolSpec]) async {
        self.tools = tools
        toolSchemas = tools.isEmpty ? nil : tools.map(Self.schema)
    }

    /// `<|tool_call>call:name{key:<|"|>text<|"|>,count:3}<tool_call|>`, keys in alphabetical order like the model
    /// writes them. `async` like the protocol's default (see `useTools`).
    public func toolCallText(_ call: VoiceCore.ToolCall) async -> String? {
        guard toolCallStart != nil, toolCallEnd != nil else { return nil }
        return "<|tool_call>call:\(call.name)\(Self.callText(.object(call.arguments)))<tool_call|>"
    }

    private static func callText(_ value: VoiceCore.JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): "<|\"|>" + s + "<|\"|>"
        case .array(let a): "[" + a.map(callText).joined(separator: ",") + "]"
        case .object(let o):
            "{" + o.sorted { $0.key < $1.key }.map { $0.key + ":" + callText($0.value) }.joined(separator: ",") + "}"
        }
    }

    public func watchToolCalls(_ on: Bool) {
        watchingToolCalls = on
    }

    public func prefill(_ conversation: [ChatMessage]) throws {
        let tokens = try render(conversation, generationPrompt: false)
        let start = try reuseCache(for: tokens)
        guard start < tokens.count else { return }
        let input = LMInput(tokens: MLXArray(tokens[start...].map { Int32($0) }))
        // Creating the iterator processes the whole prompt into the cache (it also samples one token,
        // which we ignore).
        _ = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
        eval(cache.flatMap(\.state))
        cachedTokens = Array(tokens.prefix(cachedTokenCount(upTo: tokens.count)))
    }

    /// The conversation as the model reads it, special tokens included (for checking the prompt).
    public func promptText(_ conversation: [ChatMessage]) throws -> String {
        tokenizer.decode(tokens: try render(conversation, generationPrompt: false), skipSpecialTokens: false)
    }

    public func tokenCount(_ conversation: [ChatMessage]) throws -> Int {
        try render(conversation, generationPrompt: false).count
    }

    public nonisolated func holdGeneration(_ held: Bool) {
        hold.set(held)
    }

    public func allowBackgroundWork(_ allowed: Bool) {
        backgroundAllowed = allowed
    }

    /// Reads every weight once (a sum per tensor: ≈ 0.1 s of GPU for 15 GB) so that macOS sees the
    /// model in use and keeps it in memory. Running a few tokens through the model would not do: a
    /// mixture-of-experts model only touches the experts those tokens are routed to.
    public func keepWarm() {
        guard backgroundAllowed else { return }
        let start = ContinuousClock.now
        eval(context.model.parameters().flattened().map { $0.1.sum() })
        DebugLog.log("LLM: kept warm in \(ContinuousClock.now - start)")
    }

    /// Shortening the history changes its beginning, so the whole rest must be recomputed (seconds
    /// to minutes for a long talk). That work happens in a second cache, 64 tokens at a time
    /// (≈ 0.25 s each), only while nobody speaks; the current cache keeps answering meanwhile. The
    /// first request that starts with the shortened history switches to the new cache.
    public func prepareShortenedHistory(_ conversation: [ChatMessage]) async throws {
        let tokens = try render(conversation, generationPrompt: false)
        if let r = rebuild, commonPrefix(Array(r.tokens[..<r.done]), tokens) == r.done {
            rebuild = (tokens, r.cache, r.done)  // same shortened history, grown since: keep the progress
        } else {
            rebuild = (tokens, try context.model.newCache(parameters: parameters), 0)
        }
        if rebuildTask == nil {
            rebuildTask = Task { await self.runRebuild() }
        }
        await rebuildTask?.value
    }

    private func runRebuild() async {
        while let r = rebuild, r.done < r.tokens.count - 1 {
            if !backgroundAllowed {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            advanceRebuild(chunk: 64)
            await Task.yield()  // let a waiting request through between chunks
        }
        rebuildTask = nil
        DebugLog.log("LLM: background rebuild complete")
    }

    private func advanceRebuild(chunk: Int) {
        guard var r = rebuild else { return }
        let end = min(r.done + chunk, r.tokens.count - 1)
        let input = LMInput(tokens: MLXArray(r.tokens[r.done..<end].map { Int32($0) }))
        guard (try? TokenIterator(input: input, model: context.model, cache: r.cache, parameters: parameters)) != nil
        else {
            rebuild = nil
            return
        }
        eval(r.cache.flatMap(\.state))
        r.done = end
        rebuild = r
    }

    // MARK: - Generation

    private func generate(_ conversation: [ChatMessage], maxTokens: Int? = nil,
                          onOutput: @Sendable (ModelOutput) -> Void) throws
    {
        hold.set(false)  // a new answer never starts paused
        let prompt = try render(conversation, generationPrompt: true)
        let start = try reuseCache(for: prompt)
        snapshot = (Array(prompt[..<start]), cache.map { $0.copy() })
        let input = LMInput(tokens: MLXArray(prompt[start...].map { Int32($0) }))
        let clock = ContinuousClock()
        let t0 = clock.now
        let chances = ToolCallWatch.Chances()
        var components = GenerationComponents()
        if watchingToolCalls, let toolCallStart, !tools.isEmpty {
            components = components.appendingLogitProcessor { ToolCallWatch(token: toolCallStart, chances: chances) }
        }
        var iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters,
                                         components: components)
        let d = clock.now - t0
        lastPrefill = (start, prompt.count - start,
                       Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        DebugLog.log("LLM: prefill \(prompt.count - start) tokens (reused \(start)) in \(lastPrefill.ms) ms")
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var produced: [Int] = []
        var callTokens: [Int]?  // inside a tool call
        defer {
            // The iterator feeds each token back into the cache *before* returning it, so the cache
            // holds the prompt plus every token returned. Its offset is the ground truth.
            let all = prompt + produced
            cachedTokens = Array(all.prefix(cachedTokenCount(upTo: all.count)))
        }
        while let token = iterator.next() {
            produced.append(token)
            if stopTokens.contains(token) || token == context.tokenizer.unknownTokenId { break }
            if Task.isCancelled {
                DebugLog.log("LLM: cancelled after \(produced.count) tokens")
                break
            }
            if let maxTokens, produced.count >= maxTokens { break }
            if token == toolCallStart, !tools.isEmpty {
                callTokens = []
                onOutput(.toolCallStarted)
                continue
            }
            if let tokens = callTokens {
                if token == toolCallEnd {
                    callTokens = nil
                    onOutput(toolCall(from: tokens))
                } else {
                    callTokens = tokens + [token]
                }
                continue
            }
            detokenizer.append(token: token)
            if let text = detokenizer.next(), !text.isEmpty { onOutput(.text(text)) }
            hold.waitWhileHeld(atMost: .milliseconds(1500))
        }
        if watchingToolCalls {
            // values[i] is the chance at the i-th token of the answer (the iterator reads one token ahead: the last
            // value is past the end); after a call opens, they mean nothing.
            let end = min(produced.firstIndex { $0 == toolCallStart }.map { $0 + 1 } ?? produced.count,
                          chances.values.count)
            let before = chances.values.prefix(end)
            lastToolCallChances = before.indices.max { before[$0] < before[$1] }
                .map { (before.first ?? 0, before[$0], $0) }
            lastRawAnswer = context.tokenizer.decode(tokenIds: produced, skipSpecialTokens: false)
        }
        if let tokens = callTokens {  // cut off before its end
            onOutput(.unreadableToolCall(context.tokenizer.decode(tokenIds: tokens)))
        }
    }

    /// Reads a call with mlx-swift-lm's Gemma 4 parser (`call:name{key:<|"|>value<|"|>,…}`).
    private func toolCall(from tokens: [Int]) -> ModelOutput {
        let body = context.tokenizer.decode(tokenIds: tokens)  // special tokens kept: <|"|> delimits strings
        guard let parsed = ToolCallFormat.gemma4.createParser()
            .parse(content: "<|tool_call>" + body + "<tool_call|>", tools: toolSchemas)
        else { return .unreadableToolCall(body) }
        let call = VoiceCore.ToolCall(name: parsed.function.name,
                                      arguments: parsed.function.arguments.mapValues(Self.value))
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close {
            if rawArguments.count > 50 { rawArguments.removeAll() }
            rawArguments[call] = String(body[body.index(after: open)..<close])
        }
        return .toolCall(call)
    }

    private static func value(_ value: MLXLMCommon.JSONValue) -> VoiceCore.JSONValue {
        switch value {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(Self.value))
        case .object(let o): .object(o.mapValues(Self.value))
        }
    }

    /// Makes the cache match the beginning of `tokens`; returns how many tokens are already in it.
    ///
    /// In order of preference: keep the cache as is (the new request extends it), rewind it, go back
    /// to the snapshot taken before the previous request (an abandoned speculative turn, or an
    /// interrupted answer, when Gemma's sliding-window layers can no longer rewind), rebuild it.
    private func reuseCache(for tokens: [Int]) throws -> Int {
        if let r = rebuild, r.done >= r.tokens.count - 1, commonPrefix(r.tokens, tokens) >= r.done {
            cache = r.cache  // the shortened history is ready: switch to it
            cachedTokens = Array(r.tokens[..<r.done])
            rebuild = nil
            snapshot = nil
            DebugLog.log("LLM: switched to the shortened history (\(cachedTokens.count) tokens)")
        }
        var common = commonPrefix(cachedTokens, tokens)
        let excess = cachedTokens.count - common
        guard excess > 0 else { return common }
        if canTrimPromptCache(cache), trimPromptCache(cache, numTokens: excess) == excess {
            cachedTokens.removeLast(excess)
            return common
        }
        if let snapshot, commonPrefix(snapshot.tokens, tokens) == snapshot.tokens.count {
            cache = snapshot.cache
            cachedTokens = snapshot.tokens
            self.snapshot = nil
            DebugLog.log("LLM: restored the snapshot (\(cachedTokens.count) tokens)")
            return cachedTokens.count
        }
        cache = try context.model.newCache(parameters: parameters)
        cachedTokens = []
        common = 0
        cacheRebuilds += 1
        return common
    }

    private func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        let limit = min(a.count, b.count - 1)  // leave ≥ 1 token to compute logits from
        while n < limit, a[n] == b[n] { n += 1 }
        return n
    }

    private func cachedTokenCount(upTo maximum: Int) -> Int {
        min(cache.first?.offset ?? maximum, maximum)
    }

    private func render(_ conversation: [ChatMessage], generationPrompt: Bool) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: templateMessages(conversation), chatTemplate: chatTemplate.map { .literal($0) },
            addGenerationPrompt: generationPrompt, truncation: false, maxLength: nil, tools: toolSchemas,
            additionalContext: templateContext)
    }

    /// The conversation as Gemma 4's template reads it. A tool's result goes into the assistant message that
    /// made the call (`tool_responses`, Gemma's own form), which renders it right after the call.
    private func templateMessages(_ conversation: [ChatMessage]) -> [Tokenizers.Message] {
        var messages: [Tokenizers.Message] = []
        for message in conversation {
            switch message.role {
            case .tool:
                guard var last = messages.popLast() else { continue }
                var responses = last["tool_responses"] as? [[String: any Sendable]] ?? []
                let result: [String: any Sendable]
                if case .object(let object)? = message.toolResult {
                    result = object.filter { $0.value != .null }.mapValues(Self.sendable)
                } else {
                    result = ["valeur": message.toolResult.map(Self.sendable) ?? ""]
                }
                responses.append(["name": message.content, "response": result])
                last["tool_responses"] = responses
                messages.append(last)
            case .assistant where !message.toolCalls.isEmpty:
                let calls: [[String: any Sendable]] = message.toolCalls.map { call in
                    let arguments: any Sendable = rawArguments[call]
                        ?? (Self.sendable(.object(call.arguments)) as? [String: any Sendable] ?? [:])
                    return ["function": ["name": call.name, "arguments": arguments] as [String: any Sendable]]
                }
                messages.append(["role": "assistant", "content": message.content, "tool_calls": calls])
            default:
                messages.append(["role": message.role.rawValue, "content": message.content])
            }
        }
        return messages
    }

    /// A tool, as the template wants it (an OpenAI-style function declaration).
    private static func schema(_ tool: VoiceCore.ToolSpec) -> [String: any Sendable] {
        var properties: [String: any Sendable] = [:]
        for parameter in tool.parameters {
            var property: [String: any Sendable] = ["description": parameter.description]
            switch parameter.kind {
            case .string: property["type"] = "string"
            case .integer: property["type"] = "integer"
            case .boolean: property["type"] = "boolean"
            case .oneOf(let values):
                property["type"] = "string"
                property["enum"] = values
            }
            properties[parameter.name] = property
        }
        let parameters: [String: any Sendable] = [
            "type": "object", "properties": properties,
            "required": tool.parameters.filter(\.required).map(\.name),
        ]
        return ["type": "function",
                "function": ["name": tool.name, "description": tool.description, "parameters": parameters]
                    as [String: any Sendable]]
    }

    /// A JSON value for the template (absent values are left out of objects).
    private static func sendable(_ value: VoiceCore.JSONValue) -> any Sendable {
        switch value {
        case .null: ""
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        case .array(let a): a.map(Self.sendable)
        case .object(let o): o.filter { $0.value != .null }.mapValues(Self.sendable)
        }
    }

    private func warmUp() throws {
        // First call compiles the Metal kernels; do it at load time, not during the first answer.
        try generate([ChatMessage(.user, "Bonjour")], maxTokens: 8) { _ in }
    }
}

/// Reads, at every token, the chance the model gives to opening a tool call (benchmark diagnostics: a call the
/// model considered but did not pick shows up here).
private struct ToolCallWatch: LogitProcessor {
    final class Chances: @unchecked Sendable {
        var values: [Double] = []
    }

    let token: Int
    let chances: Chances

    mutating func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        let chance = softmax(logits.asType(.float32), axis: -1)[0, token].item(Float.self)
        chances.values.append(Double(chance))
        return logits
    }

    mutating func didSample(token: MLXArray) {}
}

/// Lets the pipeline pause token generation (see `YieldsToVoice`). The generation loop runs without
/// suspension points, so the pause is a short blocking wait on a condition, bounded in time.
final class GenerationHold: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false  // guarded by `condition`

    func set(_ value: Bool) {
        condition.lock()
        held = value
        condition.broadcast()
        condition.unlock()
    }

    func waitWhileHeld(atMost limit: Duration) {
        condition.lock()
        defer { condition.unlock() }
        guard held else { return }
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        while held, condition.wait(until: deadline) {}
        held = false  // a pause that ran out of time is over for this answer
    }
}

/// Gemma 4 chat-template fix.
///
/// When it generates, Gemma's template opens the answer with an empty thought block
/// (`<|channel>thought\n<channel|>`), but when it re-renders PAST answers it leaves that block out.
/// The history therefore stops matching the cache at every turn, and since Gemma's sliding-window
/// layers cannot be rewound, the whole conversation was recomputed each time (+0.3–0.5 s).
/// The fix renders past answers exactly as they were generated. Model files are not modified.
///
/// Only the larger models' template opens answers that way: the E2B and E4B ones answer right after
/// `<|turn>model`, so theirs already matches and is left alone (patching it would add to past answers a block
/// the model never wrote, and break the cache the same way).
enum GemmaTemplateFix {
    private static let anchor = "        {{- '<|turn>' + role + '\\n' }}\n    {%- endif -%}\n"
    private static let emptyThought = "{{- '<|channel>thought\\n<channel|>' -}}"
    private static let insertion = """
            {%- if role == 'model' and not continue_same_model_turn and not (enable_thinking | default(false)) -%}
                \(emptyThought)
            {%- endif -%}

        """

    /// The patched template, or nil when it needs no fix (not Gemma 4's, or answers open without a thought block).
    static func patched(_ template: String) -> String? {
        guard template.contains(anchor), template.contains(emptyThought), !template.contains(insertion) else { return nil }
        return template.replacingOccurrences(of: anchor, with: anchor + insertion)
    }
}

/// Adapts swift-transformers' tokenizer to mlx-swift-lm (what its `#huggingFaceTokenizerLoader()`
/// macro expands to, written out to avoid compiling Swift macros).
struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int]
    {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
