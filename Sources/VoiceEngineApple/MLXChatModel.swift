import Foundation
import Hub
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
    let context: ModelContext
    let tokenizer: any Tokenizers.Tokenizer
    private let chatTemplate: String?
    let parameters: GenerateParameters
    private let stopTokens: Set<Int>
    /// Gemma 4 writes a tool call between these two tokens: `<|tool_call>call:name{…}<tool_call|>`.
    let toolCallStart: Int?
    private let toolCallEnd: Int?
    /// The tools, as the chat template wants them (in the system turn).
    private var tools: [VoiceCore.ToolSpec] = []
    private var toolSchemas: [[String: any Sendable]]?
    /// The arguments of recent calls exactly as the model wrote them, so that the history renders them
    /// identically and the cache stays valid.
    private var rawArguments: [VoiceCore.ToolCall: String] = [:]
    private var cache: [KVCache]
    private var cachedTokens: [Int] = []
    /// Copy of the cache taken just before the last request's new tokens were fed in. It shares the
    /// cache's memory until the cache changes, then holds its own (about 0.26 GB with Gemma 4 26B).
    /// For a second pass (after a tool call) it is taken once the tool's result is in instead: the next
    /// turn often has to come back to it (the history keeps the answer as the voice said it, which is not
    /// always what the model wrote) and computed that result again (a 700-token one: 3.4 s instead of
    /// 0.5 s with Gemma 4 26B on the reference Mac; 5–6 s seen in the app after a web search). The same
    /// once the prompt is in, after a request that went back to a snapshot or started again from scratch:
    /// while answers keep going into the history otherwise than the model wrote them (cut off: " […]"),
    /// every turn otherwise went back to that same point and computed more and more again (the turns after
    /// three answers cut off in a row: 1.04, 1.23 then 1.48 s with Gemma 4 26B, instead of 0.44 s each).
    private var snapshot: (tokens: [Int], cache: [KVCache])?
    /// While later requests answer the same user message (a second pass), the snapshot taken before the
    /// first one. If the turn is dropped then (the user spoke again before any voice), the request that
    /// replaces it differs from that message on: without this, the whole conversation was computed again
    /// (6.5 s instead of 0.6 s for a short one with Gemma 4 26B). After a request that went back, the
    /// snapshot taken before its new tokens, for the same reason (its answer abandoned).
    private var turnSnapshot: (tokens: [Int], cache: [KVCache])?
    /// Copy of the cache holding the beginning every conversation starts with (`prefillBeginning`): the system prompt
    /// with its tools, and the example exchanges when there are. Once the cache holds more than that beginning, Gemma's
    /// sliding-window layers cannot be rewound to it and no other snapshot ends there: each new conversation computed it
    /// again, and its first answer waited for that (the actions' 1,462 tokens on the reference Mac: 5.6 s with Gemma 4
    /// 26B, 3 s with E4B). It is restored instead (10 ms), and so is it for a request that nothing else in memory can
    /// serve, and to prepare a shortened history. It shares the cache's memory until the cache moves on, then holds its
    /// own, for good: 0.24 GB with Gemma 4 26B and the actions, 0.04 GB with E4B.
    private(set) var beginning: (tokens: [Int], cache: [KVCache])?
    /// The user's message the last request answered.
    private var lastTurn: Turn?

    /// A user's message: its place in the conversation, and the message.
    private struct Turn: Equatable {
        var index: Int
        var message: ChatMessage
    }

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
    /// Diagnostics: how many times a request went back to a snapshot.
    public private(set) var snapshotRestores = 0
    /// Diagnostics: how many times a request went back to the conversations' beginning (see `beginning`).
    public private(set) var beginningRestores = 0
    /// Diagnostics of the last request: tokens found in the cache, tokens computed, and time to compute them.
    public private(set) var lastPrefill = (reused: 0, computed: 0, ms: 0.0)
    /// Diagnostics of the last `catchUp`: tokens computed (0: nothing to do), and time to compute them.
    public private(set) var lastCatchUp = (computed: 0, ms: 0.0)
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

    /// Diagnostics: the GPU memory held by the arrays in use (weights, cache, snapshots), in GB.
    public static var activeMemoryGB: Double {
        Double(Memory.activeMemory) / 1e9
    }

    public static func load(directory: URL, maxAnswerTokens: Int = 400) async throws -> MLXChatModel {
        let context = try await LLMModelFactory.shared.load(from: directory, using: TokenizerLoaderBridge())
        let tokenizer = try await ModelTokenizer.load(from: directory)
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
        try prefill(tokens: try render(conversation, generationPrompt: false))
    }

    /// `async` like the protocol's default (see `useTools`): called on the model itself (voice-cli), a synchronous
    /// version lost to that default, which keeps nothing.
    public func prefillBeginning(_ conversation: [ChatMessage]) async throws {
        let tokens = try render(conversation, generationPrompt: false)
        if beginning?.tokens != tokens { beginning = nil }  // another beginning: the old one's memory goes first
        try prefill(tokens: tokens)
        beginning = (tokens, cache.map { $0.copy() })
    }

    /// Once the history no longer matches the cache (an answer cut off: " […]", or kept otherwise than the model wrote
    /// it), the next request went back to a snapshot and computed that answer again while the user waited (the turn
    /// after an interruption: 111 tokens in 555 ms instead of 48 in 439 ms, with Gemma 4 26B on the reference Mac). And
    /// since the snapshot it took then sat before that answer, a request that replaced it (a speculative answer
    /// abandoned, the user's message then heard in full) computed the answer once more, although only the end of the
    /// user's message had changed (253 tokens in 990 ms instead of 54 in 485 ms). The history is computed here instead,
    /// as soon as it is recorded, while the user speaks (after an interruption) or nobody does: the next request extends
    /// the cache, and its snapshot sits at its user's message. Computing that request's earlier turns in a pass of their
    /// own would give the same snapshot, but that second pass cost 0.25–0.5 s more at every such request. Nothing is
    /// computed when the cache holds the history or a request already went past it, nor when the history goes on from
    /// the cache (the next request computes the rest in its own pass, as usual).
    /// `async` like the protocol's default (see `useTools`).
    public func catchUp(with conversation: [ChatMessage]) async {
        lastCatchUp = (0, 0)
        guard let tokens = try? render(conversation, generationPrompt: false) else { return }
        let common = commonPrefix(cachedTokens, tokens, answering: false)
        guard common < cachedTokens.count, common < tokens.count else { return }
        let clock = ContinuousClock()
        let t0 = clock.now
        guard let computed = try? prefill(tokens: tokens) else { return }
        let d = clock.now - t0
        lastCatchUp = (computed, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    /// Returns how many tokens were computed.
    @discardableResult
    private func prefill(tokens: [Int]) throws -> Int {
        let start = try reuseCache(for: tokens, answering: false).reused
        guard start < tokens.count else { return 0 }
        let clock = ContinuousClock()
        let t0 = clock.now
        let input = LMInput(tokens: MLXArray(tokens[start...].map { Int32($0) }))
        // Creating the iterator processes the whole prompt into the cache (it also samples one token,
        // which we ignore).
        _ = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
        eval(cache.flatMap(\.state))
        cachedTokens = Array(tokens.prefix(cachedTokenCount(upTo: tokens.count)))
        DebugLog.log("LLM: computed \(tokens.count - start) tokens of the conversation (reused \(start)) in \(clock.now - t0)")
        return tokens.count - start
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
        } else if let beginning, commonPrefix(beginning.tokens, tokens) == beginning.tokens.count {
            rebuild = (tokens, beginning.cache.map { $0.copy() }, beginning.tokens.count)  // from the beginning it keeps
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
        let (reused, from) = try reuseCache(for: prompt)
        let wentBack = from != .cache
        let clock = ContinuousClock()
        let t0 = clock.now
        let start = reused == 0 || from == .beginning
            ? try feedEarlierTurns(of: conversation, prompt: prompt, from: reused) : reused
        let turn = conversation.lastIndex { $0.role == .user }.map { Turn(index: $0, message: conversation[$0]) }
        let answeringAgain = turn != nil && turn == lastTurn  // a second pass, after a tool call
        lastTurn = turn
        if !answeringAgain {
            turnSnapshot = nil
            snapshot = start > 0 ? (Array(prompt[..<start]), cache.map { $0.copy() }) : nil
        } else if turnSnapshot == nil {
            if let snapshot, commonPrefix(snapshot.tokens, prompt) == snapshot.tokens.count {
                turnSnapshot = snapshot
            } else if start > 0 {
                turnSnapshot = (Array(prompt[..<start]), cache.map { $0.copy() })
            }
        }
        let input = LMInput(tokens: MLXArray(prompt[start...].map { Int32($0) }))
        let chances = ToolCallWatch.Chances()
        let upcoming = UpcomingToken.Box()
        var components = GenerationComponents()
        if watchingToolCalls, let toolCallStart, !tools.isEmpty {
            components = components.appendingLogitProcessor { ToolCallWatch(token: toolCallStart, chances: chances) }
        }
        if !tools.isEmpty {
            components = components.appendingLogitProcessor { UpcomingToken(box: upcoming) }
        }
        var iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters,
                                         components: components)
        let d = clock.now - t0
        lastPrefill = (reused, prompt.count - reused,
                       Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        DebugLog.log("LLM: prefill \(prompt.count - reused) tokens (reused \(reused)) in \(lastPrefill.ms) ms")
        if answeringAgain || wentBack {
            // Once the tool's result is in, or the prompt of a request that went back (see `snapshot`).
            if !answeringAgain { turnSnapshot = snapshot }  // the one from before (see `turnSnapshot`)
            snapshot = (Array(prompt.prefix(cachedTokenCount(upTo: prompt.count))), cache.map { $0.copy() })
        }
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var produced: [Int] = []
        var callTokens: [Int]?  // inside a tool call
        var callNamed = false
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
                callNamed = false
                onOutput(.toolCallStarted)
                continue
            }
            if let tokens = callTokens {
                if token == toolCallEnd {
                    callTokens = nil
                    onOutput(toolCall(from: tokens))
                    // The history goes on from here with the tool's result (`<|tool_response>`), while E4B and E2B
                    // would write `<eos>` next: once in the cache, that token no longer matches the history, and the
                    // request after the call goes back to a snapshot. So the answer ends right after the call, its
                    // last token already in the cache, unless the model opens another call (see `VoicePipeline`).
                    if upcoming.token != toolCallStart { break }
                } else {
                    callTokens = tokens + [token]
                    if !callNamed, let name = Self.callName(context.tokenizer.decode(tokenIds: tokens + [token])) {
                        callNamed = true
                        onOutput(.toolCallNamed(name))
                    }
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

    /// The tool's name once the beginning of a call has it whole: "call:chercher_web{" → "chercher_web"; nil before.
    private static func callName(_ beginning: String) -> String? {
        guard let open = beginning.firstIndex(of: "{"), let call = beginning[..<open].range(of: "call:") else { return nil }
        let name = beginning[call.upperBound..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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

    /// Where a request's computation starts from (see `reuseCache`).
    private enum Start {
        case cache, snapshot, beginning, scratch
    }

    /// Makes the cache match the beginning of `tokens`; returns how many tokens are already in it, and where it went
    /// for that. `answering`: at least the last token is computed, the answer's first token is read from its output.
    ///
    /// In order of preference: keep the cache as is (the new request extends it), rewind it, go back
    /// to a snapshot when Gemma's sliding-window layers can no longer rewind (an abandoned speculative
    /// turn, an interrupted answer, an answer the history keeps otherwise than the model wrote it, a
    /// turn dropped after a tool call, a new conversation), rebuild it.
    private func reuseCache(for tokens: [Int], answering: Bool = true) throws -> (reused: Int, from: Start) {
        if let r = rebuild, r.done >= r.tokens.count - 1, commonPrefix(r.tokens, tokens) >= r.done {
            cache = r.cache  // the shortened history is ready: switch to it
            cachedTokens = Array(r.tokens[..<r.done])
            rebuild = nil
            snapshot = nil
            turnSnapshot = nil
            DebugLog.log("LLM: switched to the shortened history (\(cachedTokens.count) tokens)")
        }
        func holds(_ held: [Int]) -> Bool { commonPrefix(held, tokens, answering: answering) == held.count }
        let common = commonPrefix(cachedTokens, tokens, answering: answering)
        let excess = cachedTokens.count - common
        guard excess > 0 else { return (common, .cache) }
        DebugLog.log("LLM: the request leaves the cache at token \(common) \(divergence(at: common, tokens))")
        if canTrimPromptCache(cache), trimPromptCache(cache, numTokens: excess) == excess {
            cachedTokens.removeLast(excess)
            return (common, .cache)
        }
        // A snapshot restored becomes the cache itself, hence dropped.
        if let snapshot, holds(snapshot.tokens) {
            self.snapshot = nil
            return (restore(snapshot), .snapshot)
        }
        if let turnSnapshot, holds(turnSnapshot.tokens) {
            snapshot = nil
            self.turnSnapshot = nil
            return (restore(turnSnapshot), .snapshot)
        }
        snapshot = nil  // neither can serve a request that goes on from this one
        turnSnapshot = nil
        if let beginning, holds(beginning.tokens) {
            cache = beginning.cache.map { $0.copy() }  // a copy: the beginning stays for the conversations to come
            cachedTokens = beginning.tokens
            beginningRestores += 1
            DebugLog.log("LLM: back to the conversations' beginning (\(cachedTokens.count) tokens)")
            return (cachedTokens.count, .beginning)
        }
        cache = try context.model.newCache(parameters: parameters)
        cachedTokens = []
        cacheRebuilds += 1
        return (0, .scratch)
    }

    private func restore(_ snapshot: (tokens: [Int], cache: [KVCache])) -> Int {
        cache = snapshot.cache
        cachedTokens = snapshot.tokens
        snapshotRestores += 1
        DebugLog.log("LLM: restored the snapshot (\(cachedTokens.count) tokens)")
        return cachedTokens.count
    }

    /// Diagnostics: the text around the first token where a request and the cache differ, on each side.
    private func divergence(at index: Int, _ tokens: [Int]) -> String {
        func text(_ t: [Int], _ range: Range<Int>) -> String {
            let range = range.clamped(to: 0..<t.count)
            return tokenizer.decode(tokens: Array(t[range]), skipSpecialTokens: false).debugDescription
        }
        return "(after \(text(tokens, index - 8..<index))): cache \(text(cachedTokens, index..<index + 24)), "
            + "request \(text(tokens, index..<index + 24))"
    }

    /// For a request computed from scratch, or from the conversations' beginning: the turns before its user's message
    /// go in first (after the `start` tokens the cache holds), so that the snapshot holds them. Taken at 0 tokens, it
    /// served no later request: each one the cache could not serve was computed from scratch again, until one happened
    /// to extend the cache exactly (6.9–7.3 s per request instead of 0.5–1 s for a short conversation with Gemma 4 26B).
    /// Returns how many tokens the cache now holds.
    private func feedEarlierTurns(of conversation: [ChatMessage], prompt: [Int], from start: Int) throws -> Int {
        guard let user = conversation.lastIndex(where: { $0.role == .user }), user > 0 else { return start }
        let earlier = try render(Array(conversation[..<user]), generationPrompt: false)
        guard earlier.count > start, commonPrefix(earlier, prompt) == earlier.count else { return start }
        let input = LMInput(tokens: MLXArray(earlier[start...].map { Int32($0) }))
        _ = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
        eval(cache.flatMap(\.state))
        cachedTokens = Array(earlier.prefix(cachedTokenCount(upTo: earlier.count)))
        return cachedTokens.count
    }

    /// How many tokens `a` and `b` start with in common. `answering`: at most all of `b` but its last token, which
    /// must be computed for its output.
    private func commonPrefix(_ a: [Int], _ b: [Int], answering: Bool = true) -> Int {
        var n = 0
        let limit = min(a.count, answering ? b.count - 1 : b.count)
        while n < limit, a[n] == b[n] { n += 1 }
        return n
    }

    private func cachedTokenCount(upTo maximum: Int) -> Int {
        min(cache.first?.offset ?? maximum, maximum)
    }

    func render(_ conversation: [ChatMessage], generationPrompt: Bool) throws -> [Int] {
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

/// Keeps the token the iterator has drawn but not yet returned: it reads one token ahead, so when it returns a token,
/// that token is in the cache and the next one is already known.
private struct UpcomingToken: LogitProcessor {
    final class Box: @unchecked Sendable {
        var sampled: MLXArray?
        var token: Int? { sampled?.item(Int.self) }
    }

    let box: Box

    mutating func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray { logits }

    mutating func didSample(token: MLXArray) { box.sampled = token }
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
/// After a tool's result, the template opens nothing: the model goes on with its turn, and Gemma 4 26B opened that
/// answer with the same empty block itself (in all 28 such answers seen), which the history left out too. After each
/// second pass (a refused call tried again, a result summed up), the cache no longer matched the history from that
/// answer on, and the answer was computed again from a snapshot: at the next request, and since `catchUp` while nobody
/// waits (31 and 39 tokens, 0.34 and 0.47 s with Gemma 4 26B on the reference Mac). So the generation prompt after a
/// tool's result opens the answer with the block too, as for a new turn, and the history renders it there: the model
/// no longer writes those four tokens one by one, and what it writes after them is what the history renders.
///
/// Only the larger models' template opens answers that way: the E2B and E4B ones answer right after
/// `<|turn>model` and after a tool's result, so theirs already matches and is left alone (patching it would add to
/// past answers a block the model never wrote, and break the cache the same way).
enum GemmaTemplateFix {
    private static let anchor = "        {{- '<|turn>' + role + '\\n' }}\n    {%- endif -%}\n"
    private static let emptyThought = "{{- '<|channel>thought\\n<channel|>' -}}"
    /// Every model message opens with the block: a new turn, and an answer that goes on with it after a tool's result
    /// (`continue_same_model_turn`).
    private static let insertion = """
            {%- if role == 'model' and not (enable_thinking | default(false)) -%}
                \(emptyThought)
            {%- endif -%}

        """
    /// The generation prompt after a tool's result, which the template leaves empty.
    private static let afterToolResult = """

        {%- if add_generation_prompt and ns.prev_message_type == 'tool_response' and not (enable_thinking | default(false)) -%}
            \(emptyThought)
        {%- endif -%}
        """

    /// The patched template, or nil when it needs no fix (not Gemma 4's, or answers open without a thought block).
    static func patched(_ template: String) -> String? {
        guard template.contains(anchor), template.contains(emptyThought), !template.contains(insertion) else { return nil }
        return template.replacingOccurrences(of: anchor, with: anchor + insertion) + afterToolResult
    }
}

/// A model folder's tokenizer, as `AutoTokenizer.from(modelFolder:)` loads it, except that it decodes the text exactly as
/// the model wrote it. When the tokenizer's settings do not say otherwise, swift-transformers tidies decoded text the
/// English way: it removes the space before "?", "!", "." and "," (Hugging Face's own library no longer does by
/// default). Gemma writes French typography ("ta journée ?"), so its answers went into the history as "ta journée?",
/// which is another token than the one in the model's memory: the next request had to go back to a snapshot and compute
/// the answer again. That was the most common reason for a request to go back (13 of 25 in `voice-cli cache-check`).
enum ModelTokenizer {
    static func load(from directory: URL) async throws -> any Tokenizers.Tokenizer {
        let files = LanguageModelConfigurationFromHub(modelFolder: directory)
        guard var settings = try await files.tokenizerConfig?.dictionary(or: [:]) else { throw TokenizerError.missingConfig }
        if settings["clean_up_tokenization_spaces"]?.boolean() == nil {
            settings["clean_up_tokenization_spaces"] = Config(false)
        }
        return try PreTrainedTokenizer(tokenizerConfig: Config(settings), tokenizerData: try await files.tokenizerData)
    }
}

/// Adapts swift-transformers' tokenizer to mlx-swift-lm (what its `#huggingFaceTokenizerLoader()`
/// macro expands to, written out to avoid compiling Swift macros).
struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await ModelTokenizer.load(from: directory))
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
