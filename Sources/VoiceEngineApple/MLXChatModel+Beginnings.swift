import Foundation
import MLX
import MLXLMCommon
import VoiceCore

// Diagnostics for `voice-cli actions-bench --compare-beginnings`: the beginning every conversation starts with (the
// system prompt with its tools, and the example exchanges when there are), computed in several ways and compared with a
// float32 reference: the caches layer by layer, and the first token the model gives each request of a corpus from each.
//
// Why: the same beginning, computed in bfloat16 at load (on the warm-up's first 2 tokens) or again from scratch (when the
// tools change), made the model decide differently afterwards. Measured with Gemma 4 26B: no way of computing it is
// wrong, but every one in bfloat16 drifts from the float32 computation, the same amount whichever way: tiny roundings at
// first (3e-4 in layer 1), a third of the keys and values in the last layers. The requests the model hesitates on follow
// that drift ("Cherche-moi une recette de crumble aux pommes": a search at 100 % from the state at load, 5 % from the one
// computed from scratch, 100 % in float32); the other 227 of 228 requests of the corpora kept their decision. So the app
// computes it in float32 and rounds it (`MLXChatModel.beginningCache`): the comparison checks that its states, at load and
// after a tools change, are the reference's own computation, rounded.

extension MLXChatModel {
    /// A beginning as one way of computing it left the model's memory.
    public struct BeginningState: @unchecked Sendable {
        public let name: String
        let tokens: [Int]
        let cache: [KVCache]
    }

    /// Two caches compared, one layer.
    public struct LayerDifference: Sendable {
        public var layer: Int
        /// A sliding-window layer (only the last `sliding_window` positions are kept), or a full-attention one.
        public var sliding: Bool
        /// The positions both caches hold.
        public var positions: Range<Int>
        /// ‖a − b‖ / ‖b‖ over those positions, keys and values together.
        public var relative: Double
        /// The same at each position: its median, and the share of positions where it is over 0.5 (a token whose
        /// memory is far from the other one's).
        public var typical: Double
        public var far: Double
        /// The first position where they differ at all; nil when they are identical.
        public var firstDifference: Int?
    }

    /// What the model makes of a request's first token, from one beginning.
    public struct FirstToken: Sendable {
        /// The chance of opening a tool call, as `watchToolCalls` reads it.
        public var callChance: Double
        /// The most likely first token, as text.
        public var top: String
        /// Kullback–Leibler divergence from the reference's distribution, in nats.
        public var divergence: Double
    }

    public struct BeginningsComparison: Sendable {
        /// The states' names, the reference (float32) last.
        public var names: [String]
        /// Every pair of states (a before b), layer by layer.
        public var pairs: [(a: Int, b: Int, layers: [LayerDifference])]
        /// The app's way before its rounding, against the reference, layer by layer: the same float32 computation,
        /// whether every weight is in float32 or only what `beginningCache` converts.
        public var unrounded: [LayerDifference]
        /// For each request, for each state: its first token.
        public var firstTokens: [[FirstToken]]
    }

    struct BeginningsError: Error, CustomStringConvertible {
        let description: String
    }

    /// The beginning the model keeps now (`prefillBeginning`), as it was computed.
    public func beginningState(named name: String) -> BeginningState? {
        beginning.map { BeginningState(name: name, tokens: $0.tokens, cache: $0.cache.map { $0.copy() }) }
    }

    /// Computes the given states' beginning in other ways, each in a new cache: in bfloat16 as the app computed it before
    /// (from scratch, as when the tools changed; its first 2 tokens on their own then the rest, the chunks of the
    /// computation at load, without the warm-up), in chunks of 256 tokens and in one pass, in float32 with every weight
    /// converted (the reference, also rounded to the usual precision), and the app's way again (`beginningCache`), which
    /// is also compared with the reference before its rounding. Then compares every pair of caches, and reads each
    /// request's first token from every state: in float32 from the reference, as usual from the others (once for states
    /// that are identical).
    public func compareBeginnings(_ given: [BeginningState], requests: [[ChatMessage]]) throws -> BeginningsComparison {
        guard let tokens = given.first?.tokens, given.allSatisfy({ $0.tokens == tokens }), tokens.count > 2 else {
            throw BeginningsError(description: "no beginning to compare, or different ones")
        }
        func computed(_ name: String, _ compute: ([KVCache]) throws -> Void) throws -> BeginningState {
            let cache = try context.model.newCache(parameters: parameters)
            try compute(cache)
            return BeginningState(name: name, tokens: tokens, cache: cache)
        }
        var states = given
        states.append(try computed("bfloat16, from scratch") { try feed(tokens[...], into: $0) })
        states.append(try computed("bfloat16, 2 tokens, then the rest") {
            try feed(tokens[..<2], into: $0)
            try feed(tokens[2...], into: $0)
        })
        var small = parameters
        small.prefill.stepSize = 256
        states.append(try computed("bfloat16, chunks of 256") { try feed(tokens[...], into: $0, parameters: small) })
        var whole = parameters
        whole.prefill.chunking = .unchunked
        states.append(try computed("bfloat16, one pass") { try feed(tokens[...], into: $0, parameters: whole) })

        let halfTypes = enterFloat32()
        let reference: BeginningState
        let referenceLogProbs: [MLXArray]
        do {
            defer { leaveFloat32(halfTypes) }
            reference = try computed("float32, every weight converted (reference)") { try feed(tokens[...], into: $0) }
            referenceLogProbs = try requests.map { try firstTokenLogProbs($0, from: reference) }
        }
        let appWay = try beginningCache(tokens, rounded: false)
        let unrounded = compare(appWay, reference.cache)
        roundToMemoryType(appWay)
        states.append(BeginningState(name: "float32 activations, rounded, again (the app's way)", tokens: tokens,
                                     cache: appWay))
        states.append(rounded(reference, to: given[0].cache.first?.state.first?.dtype ?? .bfloat16,
                              name: "float32, every weight converted, rounded"))
        states.append(reference)

        var pairs: [(a: Int, b: Int, layers: [LayerDifference])] = []
        for a in states.indices {
            for b in states.indices where b > a {
                pairs.append((a, b, compare(states[a].cache, states[b].cache)))
            }
        }
        // A state identical to an earlier one gives the same first tokens: they are read once.
        let readFrom = states.indices.map { b in
            pairs.first { pair in
                pair.b == b && pair.layers.count == states[b].cache.count
                    && pair.layers.allSatisfy { $0.firstDifference == nil }
            }?.a ?? b
        }
        var firstTokens: [[FirstToken]] = []
        for (request, referenceRow) in zip(requests, referenceLogProbs) {
            var row: [FirstToken] = []
            for (index, state) in states.dropLast().enumerated() {
                row.append(readFrom[index] < index ? row[readFrom[index]]
                    : reading(try firstTokenLogProbs(request, from: state), reference: referenceRow))
            }
            row.append(reading(referenceRow, reference: referenceRow))
            firstTokens.append(row)
        }
        return BeginningsComparison(names: states.map(\.name), pairs: pairs, unrounded: unrounded,
                                    firstTokens: firstTokens)
    }

    /// Processes `tokens` into `cache` as `prefill` does.
    private func feed(_ tokens: ArraySlice<Int>, into cache: [KVCache], parameters: GenerateParameters? = nil) throws {
        let input = LMInput(tokens: MLXArray(tokens.map { Int32($0) }))
        _ = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters ?? self.parameters)
        eval(cache.flatMap(\.state))
    }

    /// The model's log-probabilities for the first token of its answer to `conversation`, computed on a copy of `state`
    /// (the request must start with its beginning) the way `generate` computes a request.
    private func firstTokenLogProbs(_ conversation: [ChatMessage], from state: BeginningState) throws -> MLXArray {
        let prompt = try render(conversation, generationPrompt: true)
        guard prompt.count > state.tokens.count, prompt.starts(with: state.tokens) else {
            throw BeginningsError(description: "a request does not start with the beginning")
        }
        let captured = CapturedLogits()
        let components = GenerationComponents().appendingLogitProcessor { LogitCapture(captured: captured) }
        let input = LMInput(tokens: MLXArray(prompt[state.tokens.count...].map { Int32($0) }))
        _ = try TokenIterator(input: input, model: context.model, cache: state.cache.map { $0.copy() },
                              parameters: parameters, components: components)
        guard let logits = captured.logits?.asType(.float32) else { throw BeginningsError(description: "no logits") }
        let logProbs = logits - logSumExp(logits, axis: -1, keepDims: true)
        eval(logProbs)
        return logProbs
    }

    private func reading(_ logProbs: MLXArray, reference: MLXArray) -> FirstToken {
        let divergence = (exp(reference) * (reference - logProbs)).sum().item(Float.self)
        let callChance = toolCallStart.map { exp(logProbs[$0]).item(Float.self) } ?? 0
        let top = logProbs.argMax().item(Int.self)
        return FirstToken(callChance: Double(callChance), top: tokenizer.decode(tokens: [top], skipSpecialTokens: false),
                          divergence: Double(divergence))
    }

    /// Puts the model's half-precision weights (scales, biases, norms: 2.7 GB with Gemma 4 26B) in float32, so that every
    /// computation is, until `leaveFloat32`. Returns their types.
    private func enterFloat32() -> [String: DType] {
        let half = context.model.parameters().flattened().filter { $0.1.dtype == .bfloat16 || $0.1.dtype == .float16 }
        let float32 = half.map { ($0.0, $0.1.asType(.float32)) }
        context.model.update(parameters: NestedDictionary<String, MLXArray>.unflattened(float32))
        return Dictionary(uniqueKeysWithValues: half.map { ($0.0, $0.1.dtype) })
    }

    /// Puts the weights back as they were (exactly: a float32 made from a half-precision value goes back to it).
    private func leaveFloat32(_ types: [String: DType]) {
        let restored = context.model.parameters().flattened().compactMap { key, array in
            types[key].map { (key, array.asType($0)) }
        }
        context.model.update(parameters: NestedDictionary<String, MLXArray>.unflattened(restored))
        eval(restored.map(\.1))
        Memory.clearCache()
    }

    private func rounded(_ state: BeginningState, to type: DType, name: String) -> BeginningState {
        let cache = state.cache.map { layer -> KVCache in
            var copy = layer.copy()
            copy.state = copy.state.map { $0.asType(type) }
            return copy
        }
        eval(cache.flatMap(\.state))
        return BeginningState(name: name, tokens: state.tokens, cache: cache)
    }

    private func compare(_ a: [KVCache], _ b: [KVCache]) -> [LayerDifference] {
        zip(a, b).enumerated().compactMap { layer, pair -> LayerDifference? in
            guard let x = Self.ordered(pair.0), let y = Self.ordered(pair.1) else { return nil }
            let start = max(x.first, y.first)
            let end = min(x.first + x.keys.dim(2), y.first + y.keys.dim(2))
            guard start < end else { return nil }
            func rows(_ array: MLXArray, from first: Int) -> MLXArray {
                array[.ellipsis, (start - first)..<(end - first), 0...].asType(.float32)
            }
            let (xk, xv) = (rows(x.keys, from: x.first), rows(x.values, from: x.first))
            let (yk, yv) = (rows(y.keys, from: y.first), rows(y.values, from: y.first))
            // Per position (axis 2), then over all of them.
            let difference = ((xk - yk) * (xk - yk)).sum(axes: [0, 1, 3]) + ((xv - yv) * (xv - yv)).sum(axes: [0, 1, 3])
            let size = (yk * yk).sum(axes: [0, 1, 3]) + (yv * yv).sum(axes: [0, 1, 3])
            let relative = sqrt(difference.sum() / size.sum()).item(Float.self)
            let perPosition = sqrt(difference / size)
            let typical = MLX.sorted(perPosition)[perPosition.dim(0) / 2].item(Float.self)
            let far = (perPosition .> 0.5).asType(.float32).mean().item(Float.self)
            let differs = (xk .!= yk).any(axes: [0, 1, 3]) .|| (xv .!= yv).any(axes: [0, 1, 3])
            let first = differs.any().item(Bool.self) ? start + differs.asType(.int32).argMax().item(Int.self) : nil
            return LayerDifference(layer: layer, sliding: pair.0 is RotatingKVCache, positions: start..<end,
                                   relative: Double(relative), typical: Double(typical), far: Double(far),
                                   firstDifference: first)
        }
    }

    /// A layer's keys and values in the order of their positions, and the position of the first one. A sliding-window
    /// cache that went round holds its rows from `idx` on first (Gemma keeps no token from the start: `keep` is 0).
    private static func ordered(_ cache: KVCache) -> (keys: MLXArray, values: MLXArray, first: Int)? {
        let state = cache.state
        guard state.count == 2 else { return nil }
        var (keys, values) = (state[0], state[1])
        if let rotating = cache as? RotatingKVCache {
            // keep, maxSize, step, offset, idx, origin, wrapped
            let meta = rotating.metaState
            guard meta.count >= 7, meta[0] == "0", let idx = Int(meta[4]) else { return nil }
            if meta[6] == "true", idx < keys.dim(2) {
                keys = concatenated([keys[.ellipsis, idx..., 0...], keys[.ellipsis, ..<idx, 0...]], axis: 2)
                values = concatenated([values[.ellipsis, idx..., 0...], values[.ellipsis, ..<idx, 0...]], axis: 2)
            }
        }
        return (keys, values, cache.offset - keys.dim(2))
    }
}

private final class CapturedLogits: @unchecked Sendable {
    var logits: MLXArray?
}

/// Keeps the first logits it sees (the first token of the answer).
private struct LogitCapture: LogitProcessor {
    let captured: CapturedLogits

    mutating func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        if captured.logits == nil { captured.logits = logits[0] }
        return logits
    }

    mutating func didSample(token: MLXArray) {}
}
