import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import VoiceCore

/// A sentence-embedding model on MLX (`MLXEmbedders`, on the GPU), for searching the memory's journal by meaning
/// (`MeaningMemoryStore`): LFM2.5-Embedding-350M in the app (`ModelCatalog.journalSearch`).
///
/// Each text is embedded alone (no padding), with the prefix its model was trained with for a search's words or for a
/// document (`config_sentence_transformers.json`'s "query" and "document" prompts: « query: » and « document: » for
/// LFM2.5), 512 tokens at most; the vector is of length 1, so that the dot product of two is their cosine. With LFM2.5
/// on the reference Mac (M1 Pro): 199 MB of weights, about 110 MB more for a moment while it embeds, 13 to 16 ms for a
/// search's words, 23 to 25 ms for an exchange.
public actor SentenceEmbedder: SentenceEmbedding {
    /// The model's folder name (its pack's id in the app).
    public nonisolated let model: String
    public nonisolated let queryPrefix: String
    public nonisolated let documentPrefix: String
    /// Vectors' length.
    public nonisolated let dimension: Int
    /// Bytes of the weights, as MLX counted them once loaded.
    public nonisolated let weightBytes: Int
    private let container: EmbedderModelContainer

    /// Longest text embedded, in tokens: an exchange longer than that is embedded from its beginning.
    static let maximumTokens = 512

    public static func load(directory: URL) async throws -> SentenceEmbedder {
        let before = Memory.activeMemory
        let container = try await EmbedderModelFactory.shared.loadContainer(from: directory,
                                                                           using: TokenizerLoaderBridge())
        let settings = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "config_sentence_transformers.json")))) as? [String: Any]
        let prompts = settings?["prompts"] as? [String: String]
        let probe = SentenceEmbedder(model: directory.lastPathComponent, queryPrefix: prompts?["query"] ?? "",
                                     documentPrefix: prompts?["document"] ?? "", dimension: 0, weightBytes: 0,
                                     container: container)
        let dimension = try await probe.embed("Bonjour", query: false).count  // and warms it up
        return SentenceEmbedder(model: probe.model, queryPrefix: probe.queryPrefix,
                                documentPrefix: probe.documentPrefix, dimension: dimension,
                                weightBytes: Memory.activeMemory - before, container: container)
    }

    private init(model: String, queryPrefix: String, documentPrefix: String, dimension: Int, weightBytes: Int,
                 container: EmbedderModelContainer)
    {
        self.model = model
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.dimension = dimension
        self.weightBytes = weightBytes
        self.container = container
    }

    /// The text's vector; `query`: a search's words, otherwise an exchange.
    public func embed(_ text: String, query: Bool) async throws -> [Float] {
        let input = (query ? queryPrefix : documentPrefix) + text
        let maximum = Self.maximumTokens
        return await container.perform { context in
            var tokens = context.tokenizer.encode(text: input, addSpecialTokens: true)
            // Its beginning, and the token that ends it.
            if tokens.count > maximum, let last = tokens.last { tokens = Array(tokens.prefix(maximum - 1)) + [last] }
            let ids = MLXArray(tokens.map(Int32.init)).reshaped(1, -1)
            let mask = MLXArray.ones([1, tokens.count], dtype: .bool)
            let output = context.model(ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids),
                                       attentionMask: mask)
            let pooled = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: false)
            eval(pooled)
            return pooled[0].asArray(Float.self)
        }
    }

    /// How many tokens the text takes, with its prefix (voice-cli memory-bench).
    public func tokenCount(_ text: String, query: Bool) async -> Int {
        let input = (query ? queryPrefix : documentPrefix) + text
        return await container.perform { $0.tokenizer.encode(text: input, addSpecialTokens: true).count }
    }

    /// GPU memory in use, and its peak (voice-cli memory-bench).
    public static var activeMemory: Int { Memory.activeMemory }
    public static var peakMemory: Int { Memory.peakMemory }
}
