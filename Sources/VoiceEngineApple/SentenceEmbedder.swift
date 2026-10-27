import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon

/// A sentence-embedding model on MLX (`MLXEmbedders`), for the study of searching the memory's journal by meaning
/// (issue #167, `voice-cli memory-bench --embedder` and `journal-bench --embedder`). Not used by the app.
///
/// Each text is embedded alone (no padding), with the prefixes its model was trained with: what the folder's
/// `config_sentence_transformers.json` says for "query" and "document", or the model family's own (E5's « query: » and
/// « passage: », Qwen3-Embedding's instruction). The vector is L2-normalized: the dot product is the cosine.
public actor SentenceEmbedder {
    public nonisolated let folder: URL
    public nonisolated let queryPrefix: String
    public nonisolated let documentPrefix: String
    /// Whether the last token must be the end-of-text token (Qwen3-Embedding pools the last token).
    private let endToken: Int?
    private let container: EmbedderModelContainer
    private let device: Device
    public nonisolated let dimension: Int
    /// Bytes of the weights, as MLX counted them once loaded.
    public nonisolated let weightBytes: Int

    public static func load(directory: URL, cpu: Bool = false) async throws -> SentenceEmbedder {
        let device: Device = cpu ? .cpu : .gpu
        let before = Memory.activeMemory
        let container = try await Device.withDefaultDevice(device) {
            try await EmbedderModelFactory.shared.loadContainer(from: directory, using: TokenizerLoaderBridge())
        }
        let config = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "config.json")))) as? [String: Any] ?? [:]
        let modelType = config["model_type"] as? String ?? ""
        let prompts = ((try? JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "config_sentence_transformers.json")))) as? [String: Any])?[
                "prompts"] as? [String: String]
        var query = prompts?["query"] ?? ""
        var document = prompts?["document"] ?? ""
        let name = directory.lastPathComponent.lowercased()
        if prompts == nil, name.contains("e5") {
            query = "query: "
            document = "passage: "
        }
        var endToken: Int?
        if modelType == "qwen3" {
            query = "Instruct: Given a search query, retrieve relevant passages that answer the query\nQuery:"
            document = ""
            endToken = await container.perform { $0.tokenizer.convertTokenToId("<|endoftext|>") }
        }
        let embedder = SentenceEmbedder(folder: directory, queryPrefix: query, documentPrefix: document,
                                        endToken: endToken, container: container, device: device, dimension: 0,
                                        weightBytes: Memory.activeMemory - before)
        let probe = try await embedder.embed("Bonjour", query: false)
        return SentenceEmbedder(folder: directory, queryPrefix: query, documentPrefix: document, endToken: endToken,
                                container: container, device: device, dimension: probe.count,
                                weightBytes: Memory.activeMemory - before)
    }

    private init(folder: URL, queryPrefix: String, documentPrefix: String, endToken: Int?,
                 container: EmbedderModelContainer, device: Device, dimension: Int, weightBytes: Int)
    {
        self.folder = folder
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.endToken = endToken
        self.container = container
        self.device = device
        self.dimension = dimension
        self.weightBytes = weightBytes
    }

    /// The text's vector, normalized; `query`: a search's words, else an exchange (a document).
    public func embed(_ text: String, query: Bool) async throws -> [Float] {
        let input = (query ? queryPrefix : documentPrefix) + text
        let endToken = self.endToken
        let device = self.device
        return await container.perform { context in
            Device.withDefaultDevice(device) {
                var tokens = context.tokenizer.encode(text: input, addSpecialTokens: true)
                if tokens.count > 512 { tokens = Array(tokens.prefix(511)) + [tokens.last!] }
                if let endToken, tokens.last != endToken { tokens.append(endToken) }
                let ids = MLXArray(tokens.map(Int32.init)).reshaped(1, -1)
                let mask = MLXArray.ones([1, tokens.count], dtype: .bool)
                let output = context.model(ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids),
                                           attentionMask: mask)
                let pooled = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: false)
                eval(pooled)
                return pooled[0].asArray(Float.self)
            }
        }
    }

    /// How many tokens the text takes, with its prefix.
    public func tokenCount(_ text: String, query: Bool) async -> Int {
        let input = (query ? queryPrefix : documentPrefix) + text
        return await container.perform { $0.tokenizer.encode(text: input, addSpecialTokens: true).count }
    }

    public static var activeMemory: Int { Memory.activeMemory }
    public static var peakMemory: Int { Memory.peakMemory }
}
