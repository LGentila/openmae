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
        cache = try context.model.newCache(parameters: parameters)
    }

    /// Loads an MLX model folder (config.json, *.safetensors, tokenizer files, chat template).
    public static func load(directory: URL, maxAnswerTokens: Int = 400) async throws -> MLXChatModel {
        let context = try await LLMModelFactory.shared.load(from: directory, using: TokenizerLoaderBridge())
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        let template = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"),
                                   encoding: .utf8)
        let parameters = GenerateParameters(maxTokens: maxAnswerTokens, temperature: 0.7, topP: 0.9)
        let model = try MLXChatModel(context: context, tokenizer: tokenizer,
                                     chatTemplate: template.flatMap(GemmaTemplateFix.patched),
                                     parameters: parameters)
        try await model.warmUp()
        return model
    }

    // MARK: - VoiceCore.LanguageModel

    public nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
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
                          onText: @Sendable (String) -> Void) throws
    {
        hold.set(false)  // a new answer never starts paused
        let prompt = try render(conversation, generationPrompt: true)
        let start = try reuseCache(for: prompt)
        snapshot = (Array(prompt[..<start]), cache.map { $0.copy() })
        let input = LMInput(tokens: MLXArray(prompt[start...].map { Int32($0) }))
        let clock = ContinuousClock()
        let t0 = clock.now
        var iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
        let d = clock.now - t0
        lastPrefill = (start, prompt.count - start,
                       Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        DebugLog.log("LLM: prefill \(prompt.count - start) tokens (reused \(start)) in \(lastPrefill.ms) ms")
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var produced: [Int] = []
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
            detokenizer.append(token: token)
            if let text = detokenizer.next(), !text.isEmpty { onText(text) }
            hold.waitWhileHeld(atMost: .milliseconds(1500))
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
        let messages: [Tokenizers.Message] = conversation.map { ["role": $0.role.rawValue, "content": $0.content] }
        return try tokenizer.applyChatTemplate(
            messages: messages, chatTemplate: chatTemplate.map { .literal($0) },
            addGenerationPrompt: generationPrompt, truncation: false, maxLength: nil, tools: nil,
            additionalContext: templateContext)
    }

    private func warmUp() throws {
        // First call compiles the Metal kernels; do it at load time, not during the first answer.
        try generate([ChatMessage(.user, "Bonjour")], maxTokens: 8) { _ in }
    }
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
enum GemmaTemplateFix {
    private static let anchor = "        {{- '<|turn>' + role + '\\n' }}\n    {%- endif -%}\n"
    private static let insertion = """
            {%- if role == 'model' and not continue_same_model_turn and not (enable_thinking | default(false)) -%}
                {{- '<|channel>thought\\n<channel|>' -}}
            {%- endif -%}

        """

    /// The patched template, or nil when the template is not Gemma 4's (then the model's own is used).
    static func patched(_ template: String) -> String? {
        guard template.contains(anchor), !template.contains(insertion) else { return nil }
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
