import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Synchronization
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
    /// Only its prefill observer ever changes (`watchPrefill`).
    private(set) var parameters: GenerateParameters
    private let stopTokens: Set<Int>
    /// Gemma 4 writes a tool call between these two tokens: `<|tool_call>call:name{…}<tool_call|>`.
    let toolCallStart: Int?
    private let toolCallEnd: Int?
    /// The tools, as the chat template wants them (in the system turn).
    private var tools: [VoiceCore.ToolSpec] = []
    /// The calls an answer may write one after the other (`limitToolCalls`).
    private var callsPerAnswer = 1
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
    /// while answers keep going into the history otherwise than the model wrote them (cut off: kept as far as the
    /// voice had them, while the model wrote on), every turn otherwise went back to that same point and computed
    /// more and more again (the turns after three answers cut off in a row: 1.04, 1.23 then 1.48 s with Gemma 4
    /// 26B, instead of 0.44 s each).
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
    ///
    /// It is computed in float32, in a new cache, then rounded to the model's own type (`beginningCache`); the
    /// conversations' tokens are computed in float32 on it too (`readingPrompt`), and the answers' in bfloat16.
    /// Computed in bfloat16, it drifted far from the model's exact computation (a third of the keys and values in Gemma
    /// 4 26B's last layers), differently at load (after the warm-up) and when the tools changed, and the requests the
    /// model hesitates on followed that draw: "Cherche-moi une recette de crumble aux pommes" opened a search at its
    /// first token 99 % of the time from the beginning computed at load, 19 % from the one computed when the tools
    /// changed (100 % from a float32 computation). In float32 it took less time on the reference Mac (Gemma 4 26B: 5.0
    /// s instead of 5.4 s at load; E4B: 2.6 s instead of 3.0 s), but more GPU memory while it lasts (0.8 GB more with
    /// Gemma 4 26B, 0.4 to 0.5 GB with E4B, 0.6 to 0.8 GB with E2B).
    private(set) var beginning: (tokens: [Int], cache: [KVCache])?
    /// The type of the model's memory as it computes a conversation (that of Gemma 4's half-precision weights: bfloat16),
    /// read before the warm-up: what is computed in float32 (the beginning, the requests, the history) is rounded to it.
    private var memoryType = DType.bfloat16
    /// Whether the tokens the model reads (a request's new tokens, the history computed ahead or again) are computed in
    /// float32 like the beginning (`readingPrompt`); off only for comparisons (`computePromptsInFloat32`).
    private(set) var promptsInFloat32 = true
    /// Whether, as they are computed in float32, the experts of a mixture-of-experts model (Gemma 4 26B) compute their
    /// products in bfloat16 (`ReadingExperts.halfPrecision`); on only for comparisons (`computeExpertsInHalfPrecision`).
    private(set) var expertsInHalfPrecision = false
    /// From how many rows (tokens × experts per token) the experts of a mixture-of-experts model pad their rows to the
    /// count MLX's batched kernel takes, as they are computed in float32 (`ReadingExperts`); nil: never, as before (only
    /// for comparisons, `padExpertRows`).
    private(set) var expertRowsPaddedFrom: Int? = ReadingExperts.paddedFrom
    /// What the model swaps in to compute in float32, and back out (`withFloat32Activations`): prepared at its first such
    /// computation and kept; nil until then, and again once the weights have changed type (`leaveFloat32`).
    var float32Swap: Float32Swap?
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
    /// Set for good by `windDown`, as soon as it is called (before it waits for the actor): the model computes nothing more
    /// in the background, and a keep-warm pass under way gives up (`keepWarm`).
    private nonisolated let windingDownFlag = Atomic<Bool>(false)
    private nonisolated var windingDown: Bool { windingDownFlag.load(ordering: .relaxed) }
    /// The `catchUp`s under way, each in its caller's task: `windDown` waits for them.
    private var catchUpsUnderWay = 0
    /// Counts what uses the cache, but the history computed ahead (`catchUp`): requests, conversations computed,
    /// beginnings, the tools changing. That computation stops as soon as the count moves.
    private var cacheUses = 0
    /// Requests sent and not answered yet, counted as soon as they are sent, before they reach the actor: the history
    /// computed ahead gives way to them (`catchUp`).
    private nonisolated let pendingRequests = Atomic<Int>(0)
    /// The history computed ahead goes this many tokens at a time: a request that comes meanwhile waits for one chunk at
    /// most (0.53 s with Gemma 4 26B, 0.28 s with E4B, on the reference Mac in `voice-cli cache-check`).
    private static let aheadChunk = 64
    /// Set from outside while a generation runs (the actor is busy then), hence a lock, not the actor.
    private nonisolated let hold = GenerationHold()
    // Note: "wiring" the weights in memory (MLX WiredMemoryTicket) was tried against a
    // one-off 2.6 s slowdown; it made every turn SLOWER on the reference Mac (0.5–0.65 s instead of
    // 0.28 s to process a new turn), so it is not used. Tried again against memory pressure: the weights were
    // compressed all the same. Locking them in RAM (`mlock`) froze the whole Mac in a test where another program held
    // 9 GB: macOS had nothing left to take. So they are only brought back and kept in use (`keepWarm`, `wakeUp`).
    /// The weights' memory (see `MemoryResidency`).
    private nonisolated let weightPages: [Range<UInt>]
    /// When `wakeUp` last brought the weights back.
    private nonisolated let lastWakeUp = WakeUpTimes()

    /// Diagnostics: how many times the cache had to be rebuilt from scratch.
    public private(set) var cacheRebuilds = 0
    /// Diagnostics: how many times a request went back to a snapshot.
    public private(set) var snapshotRestores = 0
    /// Diagnostics: how many times a request went back to the conversations' beginning (see `beginning`).
    public private(set) var beginningRestores = 0
    /// Diagnostics: answers stopped because they went round in circles (`RepetitionGuard`).
    public private(set) var loopsStopped = 0
    /// Diagnostics: how many times generation paused for the voice (`holdGeneration`), and for how long in all.
    public private(set) var voicePauses = (count: 0, seconds: 0.0)
    /// Diagnostics of the last request: tokens found in the cache, tokens computed, time to compute them, and how long
    /// it waited for the model before (another computation under way: the history computed ahead, a keep-warm pass).
    public private(set) var lastPrefill = (reused: 0, computed: 0, ms: 0.0, waitedMs: 0.0)
    /// Diagnostics: the GPU memory peak during the last request, from its start to its answer's last token (GB, the
    /// weights included).
    public private(set) var lastRequestPeakGB = 0.0
    /// Diagnostics of the last `catchUp`: tokens computed (0: nothing to do), and time to compute them.
    public private(set) var lastCatchUp = (computed: 0, ms: 0.0)
    /// Diagnostics: the tokens the model counts in its cache (what the next request trusts), and the tokens the cache
    /// holds (its offset). They differ only when something left the cache without saying so.
    public var cacheCounts: (counted: Int, held: Int) { (cachedTokens.count, cache.first?.offset ?? 0) }
    /// Diagnostics of the last `prefillBeginning` that computed a beginning: tokens computed, time to compute them, and the
    /// GPU memory peak meanwhile (GB, the weights included).
    public private(set) var lastBeginning: (computed: Int, ms: Double, peakGB: Double)?
    /// Benchmark diagnostics, off in the app (reading a probability at every token slows generation a little).
    private var watchingToolCalls = false
    /// With `watchToolCalls(true)`, for the last request: the chance the model gave to opening a tool call at the
    /// first token of its answer, and at its most tempted token before any call (`bestAt`: index in the answer).
    public private(set) var lastToolCallChances: (first: Double, best: Double, bestAt: Int)?
    /// With `watchToolCalls(true)`: the last answer exactly as the model wrote it, special tokens included.
    public private(set) var lastRawAnswer = ""
    /// Benchmark diagnostics, off in the app (as `watchingToolCalls`).
    private var watchingTokens = false
    /// With `watchTokens(true)`: the last answer's tokens, each with the chance the model gave it and its likeliest ones.
    public private(set) var lastTokens: [WatchedToken] = []

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
        // Not the small weights computing in float32 swaps for copies (`prepareFloat32Swap`): once swapped, the arrays
        // loaded go, and with MLX's free buffers given back (`releaseFreeBuffers`), so does their memory, which `wakeUp`
        // reads off the actor. They are smaller than a page anyway, so far.
        weightPages = MemoryResidency.ranges(context.model.parameters().flattened().map(\.1).filter { !Self.isSmall($0) })
    }

    /// Gives back to macOS the GPU memory MLX keeps for reuse, once a model has been released (tier change,
    /// models deleted).
    public static func releaseCachedMemory() {
        Memory.clearCache()
    }

    /// Diagnostics: the GPU memory held by the arrays in use (weights, cache, snapshots), in GB.
    public static var activeMemoryGB: Double {
        Double(Memory.activeMemory) / 1e9
    }

    /// Loads an MLX model folder (config.json, *.safetensors, tokenizer files, chat template), and warms it up.
    public static func load(directory: URL, maxAnswerTokens: Int = 400) async throws -> MLXChatModel {
        let context = try await LLMModelFactory.shared.load(from: directory, using: TokenizerLoaderBridge())
        let tokenizer = try await ModelTokenizer.load(from: directory)
        let template = try? String(contentsOf: directory.appendingPathComponent("chat_template.jinja"),
                                   encoding: .utf8)
        let parameters = GenerateParameters(maxTokens: maxAnswerTokens, temperature: 0.7, topP: 0.9)
        let model = try MLXChatModel(context: context, tokenizer: tokenizer,
                                     chatTemplate: template.map { GemmaTemplateFix.patched($0) ?? $0 },
                                     parameters: parameters)
        loaded.withLock { models in
            models.removeAll { $0.model == nil }
            models.append(LoadedModel(model: model))
        }
        await model.bringWeightsBack()
        try await model.warmUp()
        return model
    }

    /// Every model this process loaded, and still holds, winds down (`windDown`): before the process exits.
    public static func windDownAll() async {
        for model in loaded.withLock({ $0.compactMap(\.model) }) {
            await model.windDown()
        }
    }

    /// The models loaded in this process, held weakly, for `windDownAll`.
    private static let loaded = Mutex<[LoadedModel]>([])

    private struct LoadedModel: Sendable {
        weak var model: MLXChatModel?
    }

    /// Loading takes the Mac's free memory down for a moment, and macOS compresses the weights loaded first: by the end
    /// of the load, 61 to 97% of Gemma 4 26B's weights were out of RAM on the reference Mac, and the first passes waited
    /// for them (the warm-up's 14 tokens: 1.9 s; then the conversation's beginning, 124 tokens: 5.3 s). Read back from
    /// 8 threads, they come back in 0.57 to 1.3 s, and the warm-up then takes 0.24 to 0.71 s (see `MemoryResidency`).
    private func bringWeightsBack() {
        logResidency("after loading")
        let start = ContinuousClock.now
        MemoryResidency.touch(weightPages, threads: 8)
        DebugLog.log("LLM: weights brought back into memory in \(ContinuousClock.now - start)")
        logResidency("after bringing them back")
    }

    // MARK: - VoiceCore.LanguageModel

    public nonisolated func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream { continuation in
            let requested = ContinuousClock.now
            pendingRequests.add(1, ordering: .relaxed)  // counted at once: the history computed ahead gives way
            let task = Task {
                defer { self.pendingRequests.subtract(1, ordering: .relaxed) }
                do {
                    try await self.generate(conversation, requested: requested) { continuation.yield($0) }
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
        cacheUses += 1  // the history renders otherwise
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

    /// Benchmark diagnostics (`voice-cli story-bench`): every token of the answers, with the chance the model gave it
    /// and the tokens it found likeliest there (`lastTokens`).
    public func watchTokens(_ on: Bool) {
        watchingTokens = on
    }

    /// Benchmark diagnostics (`voice-cli … --bfloat16-prompts`): `false` computes the requests' new tokens and the history
    /// in the model's own type, as before they were computed in float32 (see `readingPrompt`), for comparisons in one
    /// build. The beginning stays in float32.
    public func computePromptsInFloat32(_ on: Bool) {
        promptsInFloat32 = on
    }

    /// Benchmark diagnostics (`voice-cli … --min-p`): the sampling's min-p instead of the app's (a token less likely than
    /// this fraction of the likeliest one is never drawn; 0: none), for comparisons in one build.
    public func sampleWithMinP(_ minP: Float) {
        parameters.minP = minP
    }

    /// Diagnostics: how the answers' tokens are drawn.
    public var sampling: (temperature: Float, topP: Float, minP: Float) {
        (parameters.temperature, parameters.topP, parameters.minP)
    }

    /// Benchmark diagnostics (`voice-cli … --bfloat16-experts`): `true` computes the products of a mixture-of-experts
    /// model's experts in bfloat16 as the requests and the history are computed in float32 (`ReadingExperts`), for
    /// comparisons in one build.
    public func computeExpertsInHalfPrecision(_ on: Bool) {
        expertsInHalfPrecision = on
    }

    /// Benchmark diagnostics (`voice-cli … --unpadded-experts`, `voice-cli read-sizes`): from how many rows (tokens ×
    /// experts per token) a mixture-of-experts model's experts pad their rows as they are computed in float32
    /// (`ReadingExperts`); nil: never, as before; `ReadingExperts.paddedFrom` in the app. For comparisons in one build.
    public func padExpertRows(from rows: Int?) {
        expertRowsPaddedFrom = rows
    }

    /// Diagnostics: the app's value of `padExpertRows(from:)`.
    public static let expertRowsPaddedFrom = ReadingExperts.paddedFrom

    /// Diagnostics (`voice-cli read-sizes`): how long the model takes to read `count` new tokens after `history`, as a
    /// request reads them (`generate`: in float32, into a cache whose memory a snapshot shares, up to the answer's first
    /// token drawn, everything waited for), for each count, each way of padding the experts' rows in `paddings` (see
    /// `padExpertRows`), `runs` times, after a first pass that is not kept. The new tokens are the first ones of the request
    /// `history` + `next`. Milliseconds, by way then count. The cache is left holding `history`.
    public func readTimes(after history: [ChatMessage], next: ChatMessage, counts: [Int], paddings: [Int?], runs: Int)
        throws -> [[Int: [Double]]]
    {
        cacheUses += 1
        try prefill(tokens: try render(history, generationPrompt: false))
        let prompt = try render(history + [next], generationPrompt: true)
        let start = commonPrefix(cachedTokens, prompt)
        guard start == cachedTokens.count, let most = counts.max(), start + most <= prompt.count else {
            throw ReadTimesError(message: "the request has \(prompt.count - start) new tokens, \(counts.max() ?? 0) asked")
        }
        let kept = (cache: cache, tokens: cachedTokens, padding: expertRowsPaddedFrom)
        defer { (cache, cachedTokens, expertRowsPaddedFrom) = kept }
        let clock = ContinuousClock()
        var times = paddings.map { _ in [Int: [Double]]() }
        for run in 0...runs {
            for count in counts {
                for (way, padding) in paddings.enumerated() {
                    expertRowsPaddedFrom = padding
                    cache = kept.cache.map { $0.copy() }  // shares its memory, as the cache a request's snapshot copied
                    cachedTokens = kept.tokens
                    let upcoming = UpcomingToken.Box()
                    let components = GenerationComponents().appendingLogitProcessor { UpcomingToken(box: upcoming) }
                    let t0 = clock.now
                    _ = try readingPrompt {
                        try readPrompt(Array(prompt[..<(start + count)]), from: start, components: components)
                    }
                    eval(cache.flatMap(\.state) + (upcoming.sampled.map { [$0] } ?? []))
                    let d = clock.now - t0
                    if run > 0 {
                        times[way][count, default: []].append(
                            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                    }
                }
            }
        }
        return times
    }

    public struct ReadTimesError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// `async` like the protocol's default (see `useTools`).
    public func limitToolCalls(_ count: Int) async {
        callsPerAnswer = max(1, count)
    }

    /// Diagnostics (`voice-cli cache-check`): `observer` is called on the request's own task each time the model has read
    /// a chunk of a long prompt, with the new tokens read so far and their number (then once more when all are read).
    /// mlx-swift-lm reads more than 512 new tokens in chunks, and between two it stops if the request was cancelled.
    public func watchPrefill(_ observer: (@Sendable (_ read: Int, _ total: Int) -> Void)?) {
        parameters.prefill.progress = observer
    }

    public func prefill(_ conversation: [ChatMessage]) throws {
        try prefill(tokens: try render(conversation, generationPrompt: false))
    }

    /// A new beginning is computed in a new cache, in float32 (see `beginning`); the cache then starts from it, as from the
    /// one kept when the beginning is the same. Every new conversation, and a change of tools, comes through here: the
    /// snapshots, which hold the conversation that ends, go.
    /// `async` like the protocol's default (see `useTools`): called on the model itself (voice-cli), a synchronous
    /// version lost to that default, which keeps nothing.
    public func prefillBeginning(_ conversation: [ChatMessage]) async throws {
        cacheUses += 1
        logResidency("before the conversations' beginning")
        let tokens = try render(conversation, generationPrompt: false)
        snapshot = nil
        turnSnapshot = nil
        if beginning?.tokens != tokens {
            // Another beginning: the old one's memory goes first, and the conversation's.
            beginning = nil
            cache = try context.model.newCache(parameters: parameters)
            cachedTokens = []
            let clock = ContinuousClock()
            let t0 = clock.now
            GPU.resetPeakMemory()
            beginning = (tokens, try beginningCache(tokens))
            let d = clock.now - t0
            lastBeginning = (tokens.count, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15,
                             Double(Memory.peakMemory) / 1e9)
            DebugLog.log("LLM: computed the conversations' beginning (\(tokens.count) tokens) in float32 in \(d)")
            logResidency("after the conversations' beginning")
        }
        guard let beginning else { return }
        cache = beginning.cache.map { $0.copy() }  // a copy: the beginning stays for the conversations to come
        cachedTokens = beginning.tokens
    }

    /// The model's memory of a beginning, computed in a new cache with float32 activations (`withFloat32Activations`),
    /// then rounded to the model's own type, layer by layer (`rounded: false`: left in float32, for diagnostics). The
    /// buffers of that computation go back to macOS.
    ///
    /// Meanwhile MLX keeps at most `beginningBuffers` of the buffers it frees. It keeps them to give them to a later
    /// computation of the same size (by default up to most of the Mac's memory), but here what one chunk of the prompt
    /// frees is never of the size the next one asks for: the sliding layers' keys and values grow from chunk to chunk,
    /// and the attention's buffers with them. With Gemma 4 26B and the actions' 1,462 tokens, MLX held 2.9 GB of them by
    /// the end, and the process's memory went from 17.1 to 19.1 GB (the bfloat16 computation before left 1.6 GB). At
    /// load, that came right after macOS had compressed most of the weights to load the voice, while the beginning brought
    /// them back: when the Mac was short of memory, it compressed them again meanwhile. Limited, the process's memory
    /// stays at 16.3 to 17.0 GB, and the beginning takes as long (reference Mac, M1 Pro 32 GB).
    func beginningCache(_ tokens: [Int], rounded: Bool = true) throws -> [KVCache] {
        let kept = Memory.cacheLimit
        Memory.cacheLimit = Self.beginningBuffers
        defer { Memory.cacheLimit = kept }
        let cache = try context.model.newCache(parameters: parameters)
        try withFloat32Activations {
            let input = LMInput(tokens: MLXArray(tokens.map { Int32($0) }))
            _ = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
            eval(cache.flatMap(\.state))
        }
        if rounded { roundToMemoryType(cache) }
        Memory.clearCache()
        return cache
    }

    /// What MLX keeps of the buffers it frees while computing a beginning (see `beginningCache`).
    static let beginningBuffers = 128 * 1024 * 1024

    /// Rounds a float32 memory to the model's own type, one layer after the other (the float32 layer goes before the next
    /// one is rounded: the memory peak stays that of the float32 memory).
    func roundToMemoryType(_ cache: [KVCache]) {
        for var layer in cache where !layer.state.isEmpty {
            let state = layer.state.map { $0.asType(memoryType) }
            eval(state)
            layer.state = state
        }
    }

    /// Runs `body`, which computes tokens into `cache` (the model's memory or a copy of it, which already holds what comes
    /// before them; `body` is given it), as the beginning is computed: with float32 activations (`withFloat32Activations`),
    /// on keys and values put in float32 first, so that the new tokens' own stay in float32 in every layer while they are
    /// computed; then the cache is rounded back to the model's own type, even if `body` throws. Without that first step,
    /// the sliding-window layers went to float32 anyway (the new tokens' keys and values are appended to them), but a
    /// full-attention layer only when its buffer had to grow: otherwise its new keys and values were rounded as they were
    /// written, before the new tokens read them, depending on the room an earlier answer had left.
    ///
    /// The rounding is handed to the GPU with nothing waited for, right behind the computation (which `body` handed over
    /// already, MLX computing lazily): the GPU does it next, and whatever reads the cache afterwards, an answer's next token
    /// included, comes after it. Rounded one layer after the other, each waited for before the next one (as a beginning
    /// is, `roundToMemoryType`), it kept the CPU waiting for the GPU once per layer of the cache at every request (30
    /// times with Gemma 4 26B, 24 with E4B, 15 with E2B), all of it before the answer's first token could come out.
    ///
    /// `halfPrecisionExperts` (comparisons): whether the experts compute in bfloat16, instead of `expertsInHalfPrecision`.
    func computeInFloat32<T>(_ cache: [KVCache], halfPrecisionExperts: Bool? = nil, _ body: ([KVCache]) throws -> T)
        rethrows -> T
    {
        for var layer in cache where !layer.state.isEmpty {
            layer.state = layer.state.map { $0.asType(.float32) }
        }
        defer {
            for var layer in cache where !layer.state.isEmpty {
                layer.state = layer.state.map { $0.asType(memoryType) }
            }
            asyncEval(cache.flatMap(\.state))
        }
        return try withFloat32Activations(halfPrecisionExperts: halfPrecisionExperts ?? expertsInHalfPrecision) {
            try body(cache)
        }
    }

    /// Runs `body`, which computes tokens the model reads into the cache (a request's new tokens, up to the one whose
    /// output gives the answer's first token; the history computed ahead, or again from a snapshot or the beginning), in
    /// float32 like the beginning (`computeInFloat32`). The answer's tokens are computed in the model's own type.
    ///
    /// Computed in bfloat16 on the float32 beginning, a request was far from the model's exact computation of it, and the
    /// first token of the answer (whether it opens a tool call) followed that on the requests the model hesitates on. With
    /// Gemma 4 26B and web-fr's 80 requests (`voice-cli actions-bench --compare-requests`), the chances of a call at the
    /// first token were 0.87 off in all from a float32 reference (every weight converted, nothing rounded), and one
    /// decision differed: "Mais si tu peux. Je veux le dernier chiffre en date…", after a search, opened one at 70 %
    /// (reference: 16 %). In float32: 0.25 off, no decision different (that request: 27 %). The history goes in float32 too:
    /// computed on its own in one pass in bfloat16 (`feedEarlierTurns`, a request that goes back to the beginning), that
    /// request opened a call at 77 % (25 % in float32); 64 tokens at a time (`computeAhead`), the first tokens of the ten
    /// requests with earlier exchanges were ten times closer to the reference's in float32 (median divergence 1e-6 nats
    /// instead of 1e-5).
    ///
    /// It costs no time (`voice-cli cache-check`, medians on the reference Mac: the first output in 561 ms instead of 575 in
    /// bfloat16 with Gemma 4 26B, 313 instead of 321 with E4B, 176 instead of 175 with E2B; a 706-token tool result
    /// computed in 2.66 s instead of 2.95 s with Gemma 4 26B), but GPU memory while those tokens are computed: the peak
    /// during a request is 0.81 GB higher with Gemma 4 26B (15.90 GB instead of 15.09), 0.45 GB with E4B, 0.34 GB with E2B.
    /// Computing in float32, MLX converts each quantized layer's scales and biases to float32 (every expert's, in Gemma 4
    /// 26B's mixture-of-experts layers), and the cache's keys and values are float32 meanwhile. Its first version took 30
    /// ms more with Gemma 4 26B (26 ms with E4B, 23 ms with E2B): it prepared what it swaps in again at every request, and
    /// waited for the GPU once per layer to round the cache (see `withFloat32Activations` and `computeInFloat32`).
    private func readingPrompt<T>(_ body: () throws -> T) rethrows -> T {
        if promptsInFloat32 { return try computeInFloat32(cache) { _ in try body() } }
        return try body()
    }

    /// Runs `body` with the model computing in float32: its quantized embedding tables give their rows dequantized in
    /// float32 (`Float32Rows`), and its small half-precision weights (norm weights, scalars, the router's scales: a few MB)
    /// are in float32. Its other weights stay as they are: a quantized layer computes in the type of what it is given,
    /// converting its scales on the fly, so every activation and the cache are float32 from the embeddings on, as when
    /// every weight is in float32 (2.7 GB more with Gemma 4 26B). Back as they were afterwards (a float32 made from a
    /// half-precision value goes back to it exactly). The experts of a mixture-of-experts model are swapped for
    /// `ReadingExperts` meanwhile, which pad their rows (`expertRowsPaddedFrom`) and, with `halfPrecisionExperts`, compute
    /// their products in bfloat16.
    ///
    /// What it swaps in and out is prepared once and kept (`float32Swap`), the float32 copies of the small weights
    /// included: rebuilt and converted at every request, then converted back and waited for, they took a few milliseconds
    /// of every request before its computation could start, and after it.
    private func withFloat32Activations<T>(halfPrecisionExperts: Bool = false, _ body: () throws -> T) rethrows -> T {
        let swap = float32Swap ?? prepareFloat32Swap()
        float32Swap = swap
        let model = context.model
        let experts = halfPrecisionExperts || expertRowsPaddedFrom != nil ? swap.experts : nil
        for layer in experts?.layers ?? [] {
            layer.halfPrecision = halfPrecisionExperts
            layer.paddedFrom = expertRowsPaddedFrom
        }
        model.update(parameters: swap.float32Weights)
        model.update(modules: swap.float32Tables)
        if let experts { model.update(modules: experts.reading) }
        defer {
            model.update(parameters: swap.weights)
            model.update(modules: swap.tables)
            if let experts { model.update(modules: experts.own) }
        }
        return try body()
    }

    /// The small half-precision weights `withFloat32Activations` swaps for float32 copies: norm weights, scalars, the
    /// router's scales.
    private static func isSmall(_ array: MLXArray) -> Bool {
        array.ndim <= 1 && (array.dtype == .bfloat16 || array.dtype == .float16)
    }

    /// Prepares what `withFloat32Activations` swaps in and out (`float32Swap`): the small half-precision weights and their
    /// float32 copies (computed here, once), the quantized embedding tables as `Float32Rows`, and the experts of a
    /// mixture-of-experts model as `ReadingExperts` (which share their weights).
    private func prepareFloat32Swap() -> Float32Swap {
        let model = context.model
        let leaves = model.leafModules().flattened()
        let tables = leaves.compactMap { key, module -> (String, QuantizedEmbedding)? in
            guard let table = module as? QuantizedEmbedding, table.mode == .affine else { return nil }
            return (key, table)
        }
        let experts = leaves.compactMap { key, module -> (String, QuantizedSwitchLinear, ReadingExperts)? in
            guard let experts = module as? QuantizedSwitchLinear, let reading = ReadingExperts(experts) else { return nil }
            return (key, experts, reading)
        }
        let small = model.parameters().flattened().filter { Self.isSmall($0.1) }
        let float32 = small.map { ($0.0, $0.1.asType(.float32)) }
        // Copies of their own, made from the float32 ones (the same values): the update puts new values into the very
        // arrays the model holds, those `parameters()` gave (and `asType` to their own type gives them back as they are).
        let weights = zip(small, float32).map { ($0.0.0, $0.1.1.asType($0.0.1.dtype)) }
        eval(float32.map(\.1) + weights.map(\.1))
        DebugLog.log("LLM: prepared to compute in float32: \(small.count) small weights ("
            + String(format: "%.1f MB", Double(float32.map(\.1.nbytes).reduce(0, +)) / 1e6) + " in float32), "
            + "\(tables.count) embedding tables, \(experts.count) experts' layers")
        return Float32Swap(
            weights: ModuleParameters.unflattened(weights), float32Weights: ModuleParameters.unflattened(float32),
            tables: ModuleChildren.unflattened(tables.map { ($0.0, $0.1 as Module) }),
            float32Tables: ModuleChildren.unflattened(tables.map { ($0.0, Float32Rows($0.1) as Module) }),
            experts: experts.isEmpty ? nil
                : (own: ModuleChildren.unflattened(experts.map { ($0.0, $0.1 as Module) }),
                   reading: ModuleChildren.unflattened(experts.map { ($0.0, $0.2 as Module) }),
                   layers: experts.map(\.2)))
    }

    /// Once the history no longer matches the cache (an answer cut off, kept as far as the voice had it while the model
    /// wrote on, or kept otherwise than the model wrote it), the next request went back to a snapshot and computed that
    /// answer again while the user waited (the turn
    /// after an interruption: 111 tokens in 555 ms instead of 48 in 439 ms, with Gemma 4 26B on the reference Mac). And
    /// since the snapshot it took then sat before that answer, a request that replaced it (a speculative answer
    /// abandoned, the user's message then heard in full) computed the answer once more, although only the end of the
    /// user's message had changed (253 tokens in 990 ms instead of 54 in 485 ms). The history is computed here instead,
    /// as soon as it is recorded, while the user speaks (after an interruption) or nobody does: the next request extends
    /// the cache, and its snapshot sits at its user's message. Computing that request's earlier turns in a pass of their
    /// own would give the same snapshot, but that second pass cost 0.25–0.5 s more at every such request. Nothing is
    /// computed when the cache holds the history or a request already went past it.
    ///
    /// The history also goes on from the cache with what the model never wrote: what the app says on its own (an
    /// announcement: the note, then what was said), and after an action the tool's result and the app's own sentences
    /// ("C'est noté."). The next request computed that too, while the user waited: the turn after an announcement 101
    /// tokens in 600 ms instead of 46 in 446 ms, the turn after an action 85 in 542 ms (Gemma 4 26B on the reference Mac;
    /// E4B: 93 tokens in 305 ms instead of 42 in 206 ms, and 77 in 302 ms). It is computed here instead, ahead
    /// (`computeAhead`), while nobody speaks: the turn after an announcement then computes 51 tokens in 456 ms (E4B: 47 in
    /// 185 ms), the turn after an action 52 in 465 ms (E4B: 48 in 187 ms). Nothing is computed ahead after an answer the
    /// model ended itself: only the end of its turn follows (the `\n` after `<turn|>`, no token the model stops at), which
    /// the next request computes with its own message.
    ///
    /// After an answer cut off, with the note read ahead (`Conversation.CutOffPlacement.ahead`), the history ends with a
    /// note rather than an answer (`Conversation.cutOffMessage`): the user speaks over the answer, and their request comes
    /// as soon as they stop. That history is computed at once, while they speak, like an answer cut off, even when the
    /// cache holds all of it but the note (an answer the model had written to its end, cut while the voice said it):
    /// computed ahead, it would wait for nobody speaking, which comes after their request, and that request would read the
    /// note with their words.
    /// `async` like the protocol's default (see `useTools`).
    public func catchUp(with conversation: [ChatMessage]) async {
        lastCatchUp = (0, 0)
        guard !windingDown else { return }
        catchUpsUnderWay += 1
        defer {
            releaseFreeBuffers()
            catchUpsUnderWay -= 1
        }
        guard let tokens = try? render(conversation, generationPrompt: false) else { return }
        let common = commonPrefix(cachedTokens, tokens, answering: false)
        guard common < tokens.count else { return }
        if common == cachedTokens.count, conversation.last?.role == .assistant {
            // A turn the model did not end follows when the rest holds a token it stops at (`<turn|>`, `<|tool_response>`).
            guard tokens[common...].contains(where: stopTokens.contains) else { return }
            lastCatchUp = await computeAhead(tokens, from: common)
            return
        }
        let clock = ContinuousClock()
        let t0 = clock.now
        guard let computed = try? prefill(tokens: tokens) else { return }
        let d = clock.now - t0
        lastCatchUp = (computed, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    /// Computes `tokens[start...]` into the cache, which holds `tokens[..<start]`, in the background (see `catchUp`):
    /// `aheadChunk` tokens at a time, while background work is allowed (nobody speaks: `allowBackgroundWork`) and no
    /// request is sent. A request sent meanwhile goes first, once the chunk under way is done, and computes the rest in
    /// its own pass, as before; so does the next request when someone speaks. A pass of its own costs more than the same
    /// tokens in a request's (about 50 tokens: 0.56 s instead of 0.15 s with Gemma 4 26B, 0.29 s instead of 0.1 s with
    /// E4B), but nobody waits for it: it starts as soon as the announcement is said, and the user's next request comes
    /// later (a pause after their first words, then its transcription). Given up too as soon as anything else uses the
    /// cache (a new conversation, other tools), when the task is cancelled, and when the model winds down (`windDown`).
    /// Returns the tokens computed, and the time spent computing them.
    private func computeAhead(_ tokens: [Int], from start: Int) async -> (computed: Int, ms: Double) {
        let uses = cacheUses
        let clock = ContinuousClock()
        var spent = Duration.zero
        var computed = 0
        if backgroundAllowed, pendingRequests.load(ordering: .relaxed) == 0 {
            let t0 = clock.now
            bringCacheBack()
            spent += clock.now - t0
        }
        while backgroundAllowed, !windingDown, pendingRequests.load(ordering: .relaxed) == 0, cacheUses == uses,
              !Task.isCancelled, cachedTokens.count < tokens.count
        {
            let done = cachedTokens.count
            let chunk = Array(tokens[..<min(done + Self.aheadChunk, tokens.count)])
            let t0 = clock.now
            // `readPrompt` keeps `cachedTokens` in step if it throws.
            let read = (try? readingPrompt { try readPrompt(chunk, from: done) }) != nil
            if read {
                eval(cache.flatMap(\.state))
                cachedTokens = Array(chunk.prefix(cachedTokenCount(upTo: chunk.count)))
            }
            spent += clock.now - t0
            computed += cachedTokens.count - done
            guard read else { break }
            await Task.yield()  // a request sent meanwhile goes first
        }
        let stopped = cacheUses != uses ? "the cache was used meanwhile"
            : cachedTokens.count >= tokens.count ? nil
            : pendingRequests.load(ordering: .relaxed) > 0 ? "a request was sent" : !backgroundAllowed ? "someone speaks"
            : windingDown ? "the model winds down" : "stopped"
        DebugLog.log("LLM: computed \(computed) of \(tokens.count - start) tokens of the history ahead (reused \(start)) in "
            + "\(spent)" + (stopped.map { ", then gave way: \($0)" } ?? ""))
        return (computed, Double(spent.components.seconds) * 1000 + Double(spent.components.attoseconds) / 1e15)
    }

    /// Returns how many tokens were computed.
    @discardableResult
    private func prefill(tokens: [Int]) throws -> Int {
        let start = try reuseCache(for: tokens, answering: false).reused
        guard start < tokens.count else { return 0 }
        let clock = ContinuousClock()
        let t0 = clock.now
        bringCacheBack()
        // The iterator also samples one token, which we ignore.
        _ = try readingPrompt { try readPrompt(tokens, from: start) }
        eval(cache.flatMap(\.state))
        cachedTokens = Array(tokens.prefix(cachedTokenCount(upTo: tokens.count)))
        DebugLog.log("LLM: computed \(tokens.count - start) tokens of the conversation (reused \(start)) in \(clock.now - t0)")
        return tokens.count - start
    }

    /// Processes `tokens[start...]` into the cache, which holds `tokens[..<start]`, and returns the iterator that then
    /// gives the answer's tokens.
    ///
    /// mlx-swift-lm reads more than 512 new tokens in chunks, and between two it stops if the request was cancelled: the
    /// chunks read stay in the cache. So when it throws, `cachedTokens` is brought in step with the cache first. Left
    /// behind, the next request trusted it and was computed from the wrong place (its tokens at the wrong positions, after
    /// the abandoned chunks), and every later one built on that: a summing up cancelled after 353 of its 706 new tokens
    /// (the user speaking over the waiting phrase) left the cache with 353 tokens more than the model counted, with Gemma 4
    /// 26B, until a request went back to a snapshot or a new conversation started.
    private func readPrompt(_ tokens: [Int], from start: Int, components: GenerationComponents = .init()) throws
        -> TokenIterator
    {
        let input = LMInput(tokens: MLXArray(tokens[start...].map { Int32($0) }))
        do {
            return try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters,
                                     components: components)
        } catch {
            cachedTokens = Array(tokens.prefix(cachedTokenCount(upTo: tokens.count)))
            DebugLog.log("LLM: stopped after \(cachedTokens.count - start) of \(tokens.count - start) new tokens: \(error)")
            throw error
        }
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

    /// Has the model compute nothing more in the background, for good (the history computed ahead, a shortened history,
    /// the keep-warm passes), and returns once it computes nothing at all: what was under way has stopped at its next
    /// chunk, the requests already sent have ended, and the GPU has finished what they left it (an answer's last step has
    /// it compute the token after, `TokenIterator`). Before the process exits (`voice-cli`): at exit, the objects MLX
    /// keeps for the whole process (its command queues, its locks) are destroyed, and a computation still under way on
    /// another thread crashed the process ("[METAL] Command buffer execution failed: Internal Error", "mutex lock failed:
    /// Invalid argument", or a segmentation fault). It did after `voice-cli conversation` runs with Gemma 4 26B whose last
    /// answer, three actions, left the model computing the history ahead. The app winds it down too before it ends
    /// (`AssistantHost.windDown`), where a keep-warm pass crashed it the same way.
    public nonisolated func windDown() async {
        windingDownFlag.store(true, ordering: .relaxed)  // at once: a keep-warm pass under way holds the actor
        await waitUntilIdle()
    }

    /// `windDown`, once the actor is free.
    private func waitUntilIdle() async {
        let start = ContinuousClock.now
        while catchUpsUnderWay > 0 || rebuildTask != nil || pendingRequests.load(ordering: .relaxed) > 0 {
            // What it waits for runs on this actor: in a cancelled task, `Task.sleep` alone returns at once and never
            // lets it.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        Stream.defaultStream.synchronize()
        DebugLog.log("LLM: wound down in \(ContinuousClock.now - start)")
    }

    /// Reads one byte of every page of the weights and of the conversation's memory from the CPU: what macOS compressed
    /// since the last pass comes back, and the pages count as used again (see `MemoryResidency`). Then reads every
    /// weight once on the GPU (a sum per tensor: ≈ 0.35 s of GPU for 15 GB); running a few tokens through the model
    /// would not do: a mixture-of-experts model only touches the experts those tokens are routed to.
    ///
    /// The conversation's memory is read on the GPU too: the GPU alone ever wrote it, and the reads from the CPU did not
    /// always bring it back. In the app, on the reference Mac under memory pressure, the conversations' beginning stayed 93%
    /// out of RAM through every keep-warm pass between loading and the first request (the weights came back at each pass),
    /// and that request read its 47 new tokens in 1.28 s instead of about 0.5 s; once a request had read it on the GPU, it
    /// stayed in RAM. Its 0.25 to 0.75 GB (Gemma 4 26B) cost nothing measurable: the GPU part of a pass stayed at 0.24 to
    /// 0.36 s.
    ///
    /// The model winding down (`windDown`: the app quits) stops the reads from the CPU where they are, and nothing is
    /// computed on the GPU: the app waited for the whole pass, up to 1.4 s with Gemma 4 26B when macOS had compressed a
    /// quarter of the weights (0.87 s of reads from the CPU, then the GPU).
    public func keepWarm() {
        guard backgroundAllowed, !windingDown else { return }
        logResidency("before keep-warm")
        let clock = ContinuousClock()
        let start = clock.now
        let conversation = conversationMemory
        MemoryResidency.touch(weightPages + MemoryResidency.ranges(conversation), threads: 4) { [self] in windingDown }
        let touched = clock.now
        guard !windingDown else {
            DebugLog.log("LLM: keep-warm given up after \(touched - start), the model winds down")
            return
        }
        eval((context.model.parameters().flattened().map(\.1) + conversation).map { $0.sum() })
        DebugLog.log("LLM: kept warm in \(clock.now - start) (CPU \(touched - start))")
        releaseFreeBuffers()
    }

    /// Someone started to speak (see `KeepsWarm`): the weights macOS compressed or wrote to swap since the last keep-warm
    /// pass come back while they speak, several pages at a time, rather than during the request. Off the actor, so that
    /// a request that comes meanwhile does not wait for it; at most once every 5 s. The conversation's memory comes back
    /// meanwhile too (`wakeConversationUp`).
    public nonisolated func wakeUp() {
        guard lastWakeUp.claim(spacing: .seconds(5)) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let start = ContinuousClock.now
            MemoryResidency.touch(weightPages, threads: 4)
            DebugLog.log("LLM: weights woken up in \(ContinuousClock.now - start)")
        }
        Task(priority: .userInitiated) { await self.wakeConversationUp() }
    }

    /// `wakeUp` for the conversation's memory: the cache, its copies and the conversations' beginning, read from the CPU on
    /// the actor (they change with every request), as soon as nothing else uses the cache.
    ///
    /// `wakeUp` brought back only the weights, and the cache the request then read was sometimes out of RAM: macOS
    /// compresses it as it does the weights, between two keep-warm passes, and within seconds of being computed while the
    /// voice loads. The GPU brings such memory back one page after the other (see `releaseFreeBuffers`), far more slowly
    /// than reads from several CPU threads: on the reference Mac (Gemma 4 26B, the usual apps open, requests 30 to 150 s
    /// apart in `voice-cli conversation`), a request that found the cache and its copies compressed (0.77 GB), with a fifth
    /// of the weights, read its 54 new tokens in 1.76 s instead of about 0.45 s. See also `bringCacheBack`.
    private func wakeConversationUp() {
        let clock = ContinuousClock()
        let start = clock.now
        MemoryResidency.touch(MemoryResidency.ranges(conversationMemory), threads: 4)
        DebugLog.log("LLM: conversation's memory woken up in \(clock.now - start)")
        logResidency("after waking up")
    }

    /// Reads the cache's every page from the CPU, several threads at once, right before the GPU computes on it (a
    /// request, the history computed ahead or again): what macOS compressed or wrote to swap since it was last used comes
    /// back now rather than one page at a time as the GPU reads it (see `wakeConversationUp`). With the cache all in RAM
    /// it costs 7 ms (14 at most) with Gemma 4 26B and 0.24 to 0.31 GB of cache, on the reference Mac.
    private func bringCacheBack() {
        let clock = ContinuousClock()
        let start = clock.now
        MemoryResidency.touch(MemoryResidency.ranges(cache.flatMap(\.state)), threads: 4)
        DebugLog.log("LLM: cache brought back in \(clock.now - start)")
    }

    /// Gives back to macOS the buffers MLX keeps for reuse once a computation is over, when they are more than
    /// `idleBuffers`: nobody uses them until the next computation, and macOS compresses them, or writes them to swap, like
    /// any memory left unused; the computation that reuses them then waits while the GPU brings them back, one page after
    /// the other. Computing the history ahead left 1.8 to 3.1 GB of them with Gemma 4 26B on the reference Mac (a request
    /// leaves about 0.1 GB), most often all compressed by the next request (requests 30 to 150 s apart in `voice-cli
    /// conversation`, the usual apps open): one read its 42 new tokens in 5.77 s, the weights and the cache all in RAM, and
    /// the five others that found them compressed 44 to 63 tokens in 0.78 to 1.02 s, against 0.42 and 0.62 s for the two
    /// that found nothing compressed. The next computation gets new buffers instead: with the same requests, every one but
    /// the first after launch read its new tokens in 0.42 to 0.47 s, and the process's footprint between requests went
    /// down from 18.3–19.6 GB to 16.2–16.6 GB.
    private func releaseFreeBuffers() {
        let kept = Memory.cacheMemory
        guard kept > Self.idleBuffers else { return }
        Memory.clearCache()
        DebugLog.log(String(format: "LLM: gave back %.2f GB of free buffers", Double(kept) / 1e9))
    }

    /// What MLX may keep of its free buffers between two computations (see `releaseFreeBuffers`).
    static let idleBuffers = 256 * 1024 * 1024

    /// The cache, its copies and a shortened history in preparation.
    private var conversationMemory: [MLXArray] {
        ([cache, snapshot?.cache, turnSnapshot?.cache, beginning?.cache, rebuild?.cache].compactMap { $0 })
            .flatMap { $0.flatMap(\.state) }
    }

    /// Diagnostics (`VOICE_DEBUG_MEMORY=1`): how much of the weights and of the conversation's memory is in RAM, and of
    /// the conversations' beginning and the cache on their own (they share their memory until the cache moves on).
    private func logResidency(_ moment: String) {
        guard MemoryResidency.enabled else { return }
        let clock = ContinuousClock()
        let t0 = clock.now
        let weights = MemoryResidency.count(weightPages)
        let conversation = MemoryResidency.count(MemoryResidency.ranges(conversationMemory))
        let kept = MemoryResidency.count(MemoryResidency.ranges(beginning?.cache.flatMap(\.state) ?? []))
        let current = MemoryResidency.count(MemoryResidency.ranges(cache.flatMap(\.state)))
        DebugLog.log("LLM memory \(moment): weights \(weights.text), conversation \(conversation.text) (beginning: "
            + "\(kept.text); cache: \(current.text)); "
            + String(format: "MLX free buffers %.2f GB; ", Double(Memory.cacheMemory) / 1e9)
            + MemoryResidency.processText + " (read in \(clock.now - t0))")
    }

    /// Shortening the history changes its beginning, so the whole rest must be recomputed (seconds
    /// to minutes for a long talk). That work happens in a second cache, 64 tokens at a time
    /// (≈ 0.25 s each), only while nobody speaks; the current cache keeps answering meanwhile. The
    /// first request that starts with the shortened history switches to the new cache.
    public func prepareShortenedHistory(_ conversation: [ChatMessage]) async throws {
        guard !windingDown else { return }
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
        while !windingDown, let r = rebuild, r.done < r.tokens.count - 1 {
            if !backgroundAllowed {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            advanceRebuild(chunk: 64)
            await Task.yield()  // let a waiting request through between chunks
        }
        rebuildTask = nil
        DebugLog.log(windingDown ? "LLM: background rebuild given up, the model winds down"
                                 : "LLM: background rebuild complete")
        releaseFreeBuffers()
    }

    private func advanceRebuild(chunk: Int) {
        guard var r = rebuild else { return }
        let end = min(r.done + chunk, r.tokens.count - 1)
        let input = LMInput(tokens: MLXArray(r.tokens[r.done..<end].map { Int32($0) }))
        func read(_ cache: [KVCache]) throws -> TokenIterator {
            try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
        }
        // In float32, as the history in the cache (see `readingPrompt`).
        guard (try? (promptsInFloat32 ? computeInFloat32(r.cache, read) : read(r.cache))) != nil else {
            rebuild = nil
            return
        }
        eval(r.cache.flatMap(\.state))
        r.done = end
        rebuild = r
    }

    // MARK: - Generation

    /// `requested`: when the request was sent (`reply`), to tell how long it waited for the model.
    private func generate(_ conversation: [ChatMessage], maxTokens: Int? = nil, requested: ContinuousClock.Instant? = nil,
                          onOutput: @Sendable (ModelOutput) -> Void) throws
    {
        let waited = requested.map { ContinuousClock.now - $0 } ?? .zero
        if requested != nil { DebugLog.log("LLM: waiting for the model (\(waited))") }
        hold.set(false)  // a new answer never starts paused
        logResidency("before the request")
        GPU.resetPeakMemory()
        defer { lastRequestPeakGB = Double(Memory.peakMemory) / 1e9 }
        let prompt = try render(conversation, generationPrompt: true)
        let (reused, from) = try reuseCache(for: prompt)
        let wentBack = from != .cache
        let clock = ContinuousClock()
        let t0 = clock.now
        bringCacheBack()
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
        let chances = ToolCallWatch.Chances()
        let upcoming = UpcomingToken.Box()
        var components = GenerationComponents()
        if watchingToolCalls, let toolCallStart, !tools.isEmpty {
            components = components.appendingLogitProcessor { ToolCallWatch(token: toolCallStart, chances: chances) }
        }
        if !tools.isEmpty {
            components = components.appendingLogitProcessor { UpcomingToken(box: upcoming) }
        }
        let draws = TokenWatch.Draws()
        if watchingTokens {
            components = components.appendingLogitProcessor { TokenWatch(draws: draws) }
        }
        var iterator = try readingPrompt { try readPrompt(prompt, from: start, components: components) }
        let d = clock.now - t0
        lastPrefill = (reused, prompt.count - reused,
                       Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15,
                       Double(waited.components.seconds) * 1000 + Double(waited.components.attoseconds) / 1e15)
        DebugLog.log("LLM: prefill \(prompt.count - reused) tokens (reused \(reused)) in \(lastPrefill.ms) ms")
        if answeringAgain || wentBack {
            // Once the tool's result is in, or the prompt of a request that went back (see `snapshot`).
            if !answeringAgain { turnSnapshot = snapshot }  // the one from before (see `turnSnapshot`)
            snapshot = (Array(prompt.prefix(cachedTokenCount(upTo: prompt.count))), cache.map { $0.copy() })
        }
        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var produced: [Int] = []
        /// With `watchingTokens`: what each token of the answer added to its text, by its index in `produced`.
        var texts: [Int: String] = [:]
        var callTokens: [Int]?  // inside a tool call
        var callNamed = false
        /// The calls written so far that could be read.
        var callsWritten = 0
        /// An answer that goes round in circles ends there, rather than at the token limit after the voice read it all.
        var repetition = RepetitionGuard()
        defer {
            // The iterator feeds each token back into the cache *before* returning it, so the cache
            // holds the prompt plus every token returned. Its offset is the ground truth.
            let all = prompt + produced
            cachedTokens = Array(all.prefix(cachedTokenCount(upTo: all.count)))
            DebugLog.log(String(format: "LLM: done writing, %d tokens (MLX: %.2f GB in use, %.2f GB kept for reuse)",
                                produced.count, Double(Memory.activeMemory) / 1e9, Double(Memory.cacheMemory) / 1e9))
            releaseFreeBuffers()
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
                    DebugLog.log("LLM: call closed, next token drawn: \(upcoming.token.map { tokenTrace([$0]) } ?? "none")")
                    let call = toolCall(from: tokens)
                    if case .toolCall = call { callsWritten += 1 }
                    onOutput(call)
                    // The history goes on from here with the tools' results (`<|tool_response>`), while E4B and E2B
                    // would write `<eos>` next: once in the cache, that token no longer matches the history, and the
                    // request after the calls goes back to a snapshot. So the answer ends right after the last call,
                    // its last token already in the cache.
                    guard upcoming.token == toolCallStart else { break }
                    // Another call follows: the user asked for several things at once. The pipeline carries out each
                    // call as soon as it is reported, while the next one is written (`reply` writes into a stream of
                    // its own), and the history keeps them all, as written, then their results. Beyond the calls the
                    // app carries out in one request (`limitToolCalls`), the next one is not written: it would be
                    // written for nothing (0.6 to 1.2 s per call, with E4B and Gemma 4 26B in voice-cli conversation on
                    // the reference Mac), and since the history would not keep it, the cache would no longer match the
                    // history from there (the request after it went back to a snapshot to compute it again, 110 to 140
                    // tokens, 0.5 to 1 s). The pipeline says how many things the app does at once. After a call that
                    // could not be read, the next one is written, as it can be carried out instead.
                    if case .toolCall = call, callsWritten >= callsPerAnswer {
                        onOutput(.moreToolCalls)
                        break
                    }
                } else {
                    callTokens = tokens + [token]
                    if !callNamed, let name = Self.callName(context.tokenizer.decode(tokenIds: tokens + [token])) {
                        callNamed = true
                        onOutput(.toolCallNamed(name))
                    }
                }
                continue
            }
            if repetition.add(token) {
                loopsStopped += 1
                DebugLog.log("LLM: the answer goes round in circles, stopped after \(produced.count) tokens: "
                             + tokenTrace(produced.suffix(12)))
                break
            }
            detokenizer.append(token: token)
            if let text = detokenizer.next(), !text.isEmpty {
                onOutput(.text(text))
                if watchingTokens { texts[produced.count - 1] = text }
            }
            let pause = clock.now
            if let ranOut = hold.waitWhileHeld(atMost: .milliseconds(1500)) {
                let paused = clock.now - pause
                voicePauses = (voicePauses.count + 1,
                               voicePauses.seconds + Double(paused.components.seconds)
                                   + Double(paused.components.attoseconds) / 1e18)
                DebugLog.log("LLM: paused for the voice \(paused) after \(produced.count) tokens"
                             + (ranOut ? ", the pause ran out" : ""))
            }
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
        if watchingTokens {
            // draws.values[i] is the i-th token drawn, as `produced[i]` (the iterator draws one token ahead: the last
            // draw may be past the end).
            func written(_ token: Int) -> String { context.tokenizer.decode(tokenIds: [token], skipSpecialTokens: false) }
            lastTokens = produced.enumerated().map { index, token in
                let draw = index < draws.values.count ? draws.values[index] : nil
                return WatchedToken(
                    id: token, token: written(token), text: texts[index] ?? "", chance: draw?.chance ?? 0,
                    likeliest: (draw?.likeliest ?? []).map { WatchedToken.Choice(token: written($0.token), chance: $0.chance) })
            }
        }
        if let tokens = callTokens {  // cut off before its end
            DebugLog.log("LLM: call cut off before its end: \(tokenTrace(tokens))")
            onOutput(.unreadableToolCall(context.tokenizer.decode(tokenIds: tokens)))
        }
    }

    /// Diagnostics: tokens with their ids, `48 "<|tool_call>" · 6639 "call"`.
    private func tokenTrace(_ tokens: some Sequence<Int>) -> String {
        tokens.map { "\($0) " + context.tokenizer.decode(tokenIds: [$0], skipSpecialTokens: false).debugDescription }
            .joined(separator: " · ")
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
        else {
            DebugLog.log("LLM: unreadable call: \(tokenTrace(tokens))")
            return .unreadableToolCall(body)
        }
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
        cacheUses += 1
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
        _ = try readingPrompt { try readPrompt(earlier, from: start) }
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
        // The type the model computes in, which its memory is rounded to after what is computed in float32 (the warm-up's
        // own request included): that of its half-precision weights (quantization scales, norms), float32 without any.
        memoryType = context.model.parameters().flattened().lazy.map(\.1.dtype)
            .first { $0 == .bfloat16 || $0 == .float16 } ?? .float32
        // First call compiles the Metal kernels (float32 for the request, the model's own type for the answer); do it at
        // load time, not during the first answer.
        try generate([ChatMessage(.user, "Bonjour")], maxTokens: 8) { _ in }
    }
}

/// A quantized embedding table that gives its rows dequantized in float32, as float32 scales would, without converting
/// the whole table to float32 (Gemma 4 E2B and E4B's per-layer one has 147 and 176 MB of scales and biases).
private final class Float32Rows: QuantizedEmbedding {
    init(_ table: QuantizedEmbedding) {
        super.init(weight: table.weight, scales: table.scales, biases: table.biases, groupSize: table.groupSize,
                   bits: table.bits, mode: table.mode, globalScale: table.globalScale)
        freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let shape = x.shape
        let x = x.flattened()
        return dequantized(weight[x], scales: scales[x].asType(.float32), biases: biases?[x].asType(.float32),
                           groupSize: groupSize, bits: bits, mode: mode).reshaped(shape + [-1])
    }
}

/// What `MLXChatModel.withFloat32Activations` swaps into the model and back out, by name.
struct Float32Swap {
    /// The small half-precision weights (norm weights, scalars, the router's scales), and their float32 copies.
    let weights: ModuleParameters
    let float32Weights: ModuleParameters
    /// The quantized embedding tables, and the same as `Float32Rows`.
    let tables: ModuleChildren
    let float32Tables: ModuleChildren
    /// The experts of a mixture-of-experts model, the same as `ReadingExperts`, and those one by one; nil without any.
    let experts: (own: ModuleChildren, reading: ModuleChildren, layers: [ReadingExperts])?
}

/// The experts of a mixture-of-experts layer (`QuantizedSwitchLinear`), the same weights, swapped in while the model reads
/// tokens in float32 (`MLXChatModel.withFloat32Activations`): the requests' new tokens, the history computed ahead or
/// again, the beginning. Computed as the original's, but for two things.
///
/// Their rows are padded. The experts compute one row per token and expert it is routed to (8 per token with Gemma 4
/// 26B), sorted by expert from 8 tokens on (`SwitchGLU`). MLX computes sorted rows with its batched kernel, which reads an
/// expert's weights once for a block of 16 rows, only from 4 rows per expert on average (512 with Gemma 4 26B's 128
/// experts: 64 tokens); below, it computes them one by one, reading their expert's weights again for each row. So from
/// `paddedFrom` rows on (nil: never), fewer rows than the batched kernel's count are padded to it, with rows of zeros
/// routed to the last expert (the rows stay sorted), and the padding's products dropped: the batched kernel computes them
/// all, as in a block of 64 tokens or more, and nothing else changes (the cache, the history, the answer's tokens).
///
/// With Gemma 4 26B on the reference Mac (M1 Pro; `voice-cli read-sizes`: N new tokens read after 1,503, up to the
/// answer's first token, medians of 5 runs), the rows computed one by one cost about 7 ms more per token, until the
/// batched kernel took over: 63 tokens in 648 ms, 64 in 490. Padded, 40 to 63 tokens took 461 to 544 ms instead of 477 to
/// 661 (46: 468 instead of 525; 56: 514 instead of 610; 62: 495 instead of 661; each read right after the unpadded one,
/// which gained it about 10 ms, as the same code from 64 tokens on showed). Below about 40 tokens the padding saved
/// nothing or cost more (32 tokens: 391 ms instead of 376; 8: 326 instead of 224), hence `paddedFrom`: 320 rows, 40 tokens.
///
/// `halfPrecision`: they compute their products in the type of their scales (bfloat16) whatever they are given, and give
/// them back in the type they were given. Given float32, a quantized layer computes in float32 and converts its scales and
/// biases to float32 first, all of them, at every pass: in Gemma 4 26B's mixture-of-experts layers, those of their 128
/// experts (1.4 GB in bfloat16 in all). In bfloat16, the experts' inputs and products are rounded to bfloat16 instead: the
/// rest of the computation (attention, the dense layers, the norms, the router, the sum of the experts' products) stays in
/// float32. Only for comparisons (`computeExpertsInHalfPrecision`, `voice-cli … --bfloat16-experts`): on the reference Mac
/// (M1 Pro, whose GPU computes bfloat16 without hardware support), the experts' products took longer in bfloat16 than the
/// conversions saved, and the memory peak hardly moved (`voice-cli cache-check`, Gemma 4 26B, medians: first output 607 ms
/// instead of 561, GPU memory peak during a request 15.76 GB instead of 15.90).
final class ReadingExperts: SwitchLinear {
    /// The app's `paddedFrom`: 40 tokens of Gemma 4 26B (8 experts each), 2.5 rows per expert on average.
    static let paddedFrom: Int? = 320

    /// Set by the model before it swaps them in (`MLXChatModel.withFloat32Activations`).
    var halfPrecision = false
    var paddedFrom = ReadingExperts.paddedFrom
    /// Named as the original's, the same arrays: the model's parameters are the same while it is swapped in.
    let scales: MLXArray
    let biases: MLXArray
    /// The original's quantized weights, which `SwitchLinear` keeps out of reach (a leading `_`: not a parameter again).
    private let _packed: MLXArray
    private let groupSize: Int
    private let bits: Int
    private let mode: QuantizationMode
    /// The rows from which MLX computes sorted rows with its batched kernel: 4 per expert.
    private let batchedRows: Int

    /// Nil for experts this does not handle (other than affine quantization, or with a bias of their own).
    init?(_ experts: QuantizedSwitchLinear) {
        let own = Dictionary(uniqueKeysWithValues: experts.parameters().flattened())
        guard experts.mode == .affine, own["bias"] == nil, let weight = own["weight"], let scales = own["scales"],
              let biases = own["biases"], weight.ndim == 3
        else { return nil }
        self.scales = scales
        self.biases = biases
        _packed = weight
        groupSize = experts.groupSize
        bits = experts.bits
        mode = experts.mode
        batchedRows = 4 * weight.dim(0)
        super.init(inputDims: weight.dim(2) * 32 / experts.bits, outputDims: weight.dim(1), numExperts: weight.dim(0),
                   weight: weight)
        freeze()
    }

    override func callAsFunction(_ x: MLXArray, _ indices: MLXArray, sortedIndices: Bool = false) -> MLXArray {
        let input = halfPrecision ? x.asType(scales.dtype) : x
        let rows = indices.size
        func products(_ input: MLXArray, _ indices: MLXArray) -> MLXArray {
            gatherQuantizedMM(input, _packed, scales: scales, biases: biases, rhsIndices: indices, transpose: true,
                              groupSize: groupSize, bits: bits, mode: mode, sortedIndices: sortedIndices)
        }
        let output: MLXArray
        if sortedIndices, let paddedFrom, rows >= paddedFrom, rows < batchedRows, indices.ndim == 1, input.ndim == 3,
           input.dim(0) == rows, input.dim(1) == 1
        {
            let extra = batchedRows - rows
            output = products(padded(input, widths: [[0, extra], 0, 0]),
                              concatenated([indices, broadcast(indices[(rows - 1)...], to: [extra])]))[..<rows]
        } else {
            output = products(input, indices)
        }
        return halfPrecision ? output.asType(x.dtype) : output
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

/// Diagnostics (`MLXChatModel.watchTokens`): a token of an answer, the chance the model gave it there (its probability,
/// before the sampling's temperature and filters), and the tokens the model found likeliest there.
public struct WatchedToken: Sendable, Encodable {
    public struct Choice: Sendable, Encodable {
        /// The token's text alone, special tokens written out.
        public var token: String
        public var chance: Double
    }

    public var id: Int
    /// The token's text alone, special tokens written out.
    public var token: String
    /// What the answer's text gained with it (`ModelOutput.text`): empty for a token of a call, or one that completes no
    /// character yet.
    public var text: String
    public var chance: Double
    /// The likeliest tokens there, the likeliest first.
    public var likeliest: [Choice]
}

/// Reads, at every token, the chance the model gives to the token it draws and to its likeliest ones (benchmark
/// diagnostics: a token the model hardly expected, drawn all the same, shows up here).
private struct TokenWatch: LogitProcessor {
    final class Draws: @unchecked Sendable {
        var values: [(chance: Double, likeliest: [(token: Int, chance: Double)])] = []
        /// The chances at the token being drawn, until it is.
        var chances: MLXArray?
    }

    let draws: Draws
    /// How many of the likeliest tokens are kept.
    var count = 5

    mutating func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        draws.chances = softmax(logits.asType(.float32), axis: -1).reshaped([-1])
        return logits
    }

    mutating func didSample(token: MLXArray) {
        guard let chances = draws.chances else { return }
        draws.chances = nil
        let order = argSort(-chances, axis: -1)[..<count]
        let likeliest = zip(order.asArray(Int32.self), chances.take(order).asArray(Float.self))
            .map { (token: Int($0), chance: Double($1)) }
        let drawn = chances[token.item(Int.self)].item(Float.self)
        draws.values.append((Double(drawn), likeliest))
    }
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

/// When `MLXChatModel.wakeUp` last ran, from any thread.
final class WakeUpTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant?  // guarded by `lock`

    /// True, and now becomes the last time, unless the last time was less than `spacing` ago.
    func claim(spacing: Duration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if let last, now - last < spacing { return false }
        last = now
        return true
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

    /// Nil when generation was not held; otherwise whether the pause ran out of time (the voice still not audible).
    @discardableResult
    func waitWhileHeld(atMost limit: Duration) -> Bool? {
        condition.lock()
        defer { condition.unlock() }
        guard held else { return nil }
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        while held, condition.wait(until: deadline) {}
        let ranOut = held
        held = false  // a pause that ran out of time is over, until the pipeline holds generation again
        return ranOut
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
