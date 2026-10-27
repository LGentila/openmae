import CryptoKit
import Foundation
import VoiceCore

// Model commands of voice-cli:
//
//   voice-cli download [--tier minimum|standard|comfort|max]   downloads a tier's models, like the app
//   voice-cli download --journal-search                         the model of the journal's search by meaning
//   voice-cli verify [--tier …|--all]                           re-reads the models and checks every SHA-256
//   voice-cli catalog                                           regenerates Sources/VoiceCore/ModelFiles.swift

// MARK: - download, verify

func tierOption(_ o: Options) throws -> HardwareTier {
    guard let name = o.tier else { return HardwareTier.recommended(for: .current) }
    guard let tier = HardwareTier(rawValue: name), HardwareTier.selectable.contains(tier) else {
        throw CLIError("unknown tier: \(name) (minimum, standard, comfort or max)")
    }
    return tier
}

func runDownload(_ o: Options) async throws {
    let store = ModelStore()
    let packs: [ModelPack]
    if o.journalSearch {
        packs = [ModelCatalog.journalSearch]
        print("the journal's search by meaning: \(ModelCatalog.journalSearch.displayName)")
    } else {
        let tier = try tierOption(o)
        packs = ModelCatalog.packs(for: tier)
        print("tier “\(tier.rawValue)”: \(packs.map(\.displayName).joined(separator: ", "))")
    }
    print("folder: \(store.root.path)")
    print("to download: \(gb(store.bytesToDownload(packs))) · free space: \(gb(store.availableBytes()))")
    let clock = ContinuousClock()
    let start = clock.now
    try await ModelDownloader(store: store).download(packs) { p in
        let speed = p.bytesPerSecond.map { String(format: "%.1f MB/s", $0 / 1e6) } ?? "…"
        let state = p.waitingForNetwork ? "waiting for the network" : (p.currentModel ?? "")
        let line = String(format: "\r%5.1f %% · %@ of %@ · %@ · %@", p.fraction * 100, gb(p.doneBytes),
                          gb(p.totalBytes), speed, state)
        FileHandle.standardOutput.write(Data((line.padding(toLength: 90, withPad: " ", startingAt: 0)).utf8))
    }
    print("\ndone in \(clock.now - start) · complete: \(store.isComplete(packs) ? "yes" : "NO")")
}

func runVerify(_ o: Options) throws {
    let store = ModelStore()
    let packs = o.all ? ModelCatalog.all : ModelCatalog.packs(for: try tierOption(o))
    var problems = 0
    for pack in packs {
        let missing = store.missingFiles(pack)
        let start = Date()
        let corrupted = try store.corruptedFiles(pack)
        problems += missing.count + corrupted.count
        print("\(pack.id): \(pack.files.count - missing.count)/\(pack.files.count) files, "
              + "\(corrupted.count) damaged, checked in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        for file in corrupted { print("  DAMAGED: \(file.path)") }
    }
    print(problems == 0 ? "everything is as expected" : "\(problems) file(s) missing or damaged")
}

func gb(_ bytes: Int64?) -> String {
    bytes.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "?"
}

// MARK: - catalog

/// Which files of each repository the app needs: the rest of the repository is never downloaded.
/// `listings`: folders to list on Hugging Face (recursively or not); `keep`: the files to take.
private struct Selection {
    let listings: [(folder: String, recursive: Bool)]
    let keep: @Sendable (String) -> Bool
}

private let selections: [String: Selection] = {
    // Parakeet v3: the four compiled models FluidAudio's `loadLocal` opens (int8 encoder), and the vocabulary.
    let parakeet = Selection(listings: [("", true)]) { path in
        ["Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/"]
            .contains { path.hasPrefix($0) } || path == "parakeet_vocab.json"
    }
    // Pocket TTS: for each language, the four models FluidAudio loads on the GPU ("fp16" FlowLM), the
    // constants, and the one voice used; plus the files FluidAudio would otherwise fetch at every launch
    // (encoder_recover_pinv.bin at the root, speaker_proj_weight.bin for the 24-layer French pack).
    let voices = ["french_24l": "estelle", "english": "alba"]
    let pocket = Selection(listings: [("", false), ("v2.1/french_24l", true), ("v2.1/english", true)]) { path in
        if path == "encoder_recover_pinv.bin" { return true }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "v2.1", let voice = voices[parts[1]] else { return false }
        let models = ["cond_prefill.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder_fused.mlmodelc", "mimi_decoder.mlmodelc"]
        if models.contains(parts[2]) { return true }
        let constants = ["bos_emb.bin", "bos_before_voice.bin", "text_embed_table.bin", "tokenizer.model",
                         "speaker_proj_weight.bin", voice + ".safetensors"]
        return parts.count == 4 && parts[2] == "constants_bin" && constants.contains(parts[3])
    }
    // MLX language models: the whole repository except its documentation.
    let mlx = Selection(listings: [("", true)]) { path in path != "README.md" && path != ".gitattributes" }
    // The sentence-embedding model of the journal's search: what MLXEmbedders loads (weights, configuration, the
    // prompts it was trained with, tokenizer), not the repository's Python code, chat template, license or documentation.
    let embedder = Selection(listings: [("", false)]) { path in
        ["config.json", "config_sentence_transformers.json", "model.safetensors", "special_tokens_map.json",
         "tokenizer.json", "tokenizer_config.json"].contains(path)
    }
    var selections = ["parakeet-tdt-0.6b-v3": parakeet, "pocket-tts": pocket, ModelCatalog.journalSearch.id: embedder]
    for pack in ModelCatalog.all where pack.role == .languageModel { selections[pack.id] = mlx }
    return selections
}()

/// One entry of Hugging Face's "tree" API.
private struct TreeEntry: Decodable {
    struct LFS: Decodable { let oid: String; let size: Int64 }
    let type: String
    let path: String
    let size: Int64
    /// Git blob id (SHA-1 of "blob <size>\0" + content).
    let oid: String
    /// Large files: `oid` is the SHA-256 of the content.
    let lfs: LFS?
}

func runCatalog(_ o: Options) async throws {
    let output = CommandLine.arguments.contains("--out") ? o.out : URL(fileURLWithPath: "Sources/VoiceCore/ModelFiles.swift")
    var body = ""
    for pack in ModelCatalog.all {
        guard let selection = selections[pack.id] else { throw CLIError("no selection for \(pack.id)") }
        var entries: [TreeEntry] = []
        for listing in selection.listings {
            entries += try await listTree(pack, folder: listing.folder, recursive: listing.recursive)
        }
        let files = entries.filter { $0.type == "file" && selection.keep($0.path) }.sorted { $0.path < $1.path }
        body += "        \"\(pack.id)\": [  // \(pack.repository) @ \(pack.revision.prefix(8))\n"
        var total: Int64 = 0
        for entry in files {
            let sha256: String
            if let lfs = entry.lfs {
                sha256 = lfs.oid
            } else {
                // Small files are stored in git: their id is a SHA-1. Fetch them to compute their SHA-256.
                let data = try await fetch(pack.downloadURL(ModelFile(entry.path, entry.size, "")))
                let blob = Data("blob \(data.count)\0".utf8) + data
                guard Insecure.SHA1.hash(data: blob).map({ String(format: "%02x", $0) }).joined() == entry.oid
                else { throw CLIError("\(pack.id)/\(entry.path): content differs from Hugging Face's index") }
                sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            total += entry.size
            body += "            ModelFile(\"\(entry.path)\", \(entry.size), \"\(sha256)\"),\n"
        }
        body += "        ],\n"
        print("\(pack.id): \(files.count) files, \(gb(total))")
        if files.isEmpty { throw CLIError("no file selected for \(pack.id)") }
    }
    let source = """
        // GENERATED by `voice-cli catalog` (Sources/VoiceCLI/ModelCommands.swift) from Hugging Face, at the
        // revisions pinned in ModelCatalog.swift: do not edit by hand. Path inside the repository, size in bytes,
        // SHA-256 of the content.

        extension ModelCatalog {
            static let generatedFiles: [String: [ModelFile]] = [

        """ + body + """
            ]
        }

        """
    try source.write(to: output, atomically: true, encoding: .utf8)
    print("written: \(output.path)")
}

/// Lists a folder of the repository at the pinned revision, following the pages of the answer.
private func listTree(_ pack: ModelPack, folder: String, recursive: Bool) async throws -> [TreeEntry] {
    var components = URLComponents(string: "https://huggingface.co/api/models/\(pack.repository)/tree/\(pack.revision)")!
    if !folder.isEmpty { components.path += "/" + folder }
    components.queryItems = [URLQueryItem(name: "recursive", value: recursive ? "true" : "false")]
    var next = components.url
    var entries: [TreeEntry] = []
    while let url = next {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CLIError("listing refused: \(url)") }
        entries += try JSONDecoder().decode([TreeEntry].self, from: data)
        next = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link")
            .flatMap { $0.contains("rel=\"next\"") ? $0 : nil }
            .flatMap { $0.split(separator: ">").first?.dropFirst() }
            .flatMap { URL(string: String($0)) }
    }
    return entries
}

private func fetch(_ url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CLIError("download refused: \(url)") }
    return data
}
