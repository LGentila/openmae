import Foundation

// The models the app downloads on first launch, and where each one comes from.
//
// Each model is pinned to one revision (a commit) of its Hugging Face repository, and each file to its size
// and SHA-256: the app only accepts exactly the bytes that were tested, even if the repository changes
// later. This file says which repositories and revisions are used; the file lists are generated from
// Hugging Face into ModelFiles.swift (`voice-cli catalog`, see the README).
//
// The only model not listed here is Silero VAD (640 KB): it ships inside the app.

/// One file of a model, as published at the pinned revision.
public struct ModelFile: Sendable, Equatable, Codable {
    /// Path inside the repository, which is also its path inside the model's folder on disk.
    public var path: String
    public var size: Int64
    /// SHA-256 of the content, lowercase hexadecimal.
    public var sha256: String

    public init(_ path: String, _ size: Int64, _ sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// What a model does in the pipeline.
public enum ModelRole: String, Sendable, Codable, CaseIterable {
    case speechRecognition, languageModel, voice
}

/// A downloadable model: some files of one Hugging Face repository, at one revision, stored in
/// `Models/<id>/` with the repository's own layout.
public struct ModelPack: Sendable, Equatable, Codable, Identifiable {
    /// Also the name of its folder in the models directory.
    public var id: String
    public var role: ModelRole
    public var displayName: String
    public var repository: String
    /// Commit of the repository the files come from.
    public var revision: String
    public var license: String
    public var files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Where a file is downloaded from (Hugging Face redirects large files to its CDN).
    public func downloadURL(_ file: ModelFile) -> URL {
        var url = URL(string: "https://huggingface.co")!
        for part in (repository + "/resolve/" + revision + "/" + file.path).split(separator: "/") {
            url.append(path: String(part))
        }
        return url
    }
}

public enum ModelCatalog {
    /// Speech recognition, every tier: NVIDIA Parakeet TDT 0.6B v3 (25 European languages), CoreML export by
    /// FluidInference. Only the int8 encoder that was measured is downloaded, not the repository's other
    /// variants.
    public static let speechRecognition = pack(
        "parakeet-tdt-0.6b-v3", .speechRecognition, "Parakeet TDT 0.6B v3",
        "FluidInference/parakeet-tdt-0.6b-v3-coreml", "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe", "CC-BY-4.0")

    /// The voice, every tier: Kyutai's Pocket TTS, CoreML export by FluidInference. French (24 layers, voice
    /// "estelle") and English (voice "alba"); the repository's other languages and voices are not
    /// downloaded. The folder keeps FluidAudio's name and layout (`pocket-tts/v2.1/<language>/`): FluidAudio
    /// then finds every file it would otherwise fetch, so it never goes online.
    public static let voice = pack(
        "pocket-tts", .voice, "Pocket TTS", "FluidInference/pocket-tts-coreml",
        "91748676fe3c8b2eb3007b3125253bcd898202c3", "CC-BY-4.0")

    // Language models, 4-bit MLX conversions by mlx-community of Google's Gemma 4 (Apache-2.0). Note: the
    // E2B and E4B conversions' model cards say "gemma" where Google's originals say Apache-2.0.
    static let gemmaE2B = pack(
        "gemma-4-e2b-it-4bit", .languageModel, "Gemma 4 E2B", "mlx-community/gemma-4-e2b-it-4bit",
        "238767527555cb75a05732a84dff5d6ba0dd6809", "Apache-2.0")
    static let gemmaE4B = pack(
        "gemma-4-e4b-it-4bit", .languageModel, "Gemma 4 E4B", "mlx-community/gemma-4-e4b-it-4bit",
        "475b9088d29754a3379866cf5aeb6b41acd313c2", "Apache-2.0")
    /// The comfort tier's model until it moved to the QAT one (below): still listed, so that Settings shows it on a Mac
    /// that has it, where it can be deleted.
    static let gemma26B = pack(
        "gemma-4-26b-a4b-it-4bit", .languageModel, "Gemma 4 26B-A4B", "mlx-community/gemma-4-26b-a4b-it-4bit",
        "0d77464eeb233a2da68ebf9d7dc4edaac7db956d", "Apache-2.0")
    /// Google's quantization-aware-trained Gemma 4 26B-A4B (trained to be quantized to 4 bits), converted by
    /// mlx-community: its experts in 4 bits as the conversion above, its shared MLP and router in 8 bits (0.27 GB more).
    /// The conversion above writes malformed words the voice then reads (« constru-ite » or « construles » for
    /// « construite », « d'Avrons » for « d'Avranches », « Aujourd'elle »): in 37 of 100 stories with the app's tools
    /// (`voice-cli story-bench`, 2026-10-25), against 4 of 100 with this one, which writes « construite » every time.
    /// Its model card names no license; Google's QAT weights are Apache-2.0, as the others.
    static let gemma26BQAT = pack(
        "gemma-4-26b-a4b-it-qat-4bit", .languageModel, "Gemma 4 26B-A4B (QAT)",
        "mlx-community/gemma-4-26B-A4B-it-qat-4bit", "0e3cbab38ce568cf6e23543010d08d03b731910c", "Apache-2.0")
    static let gemma26B8bit = pack(
        "gemma-4-26b-a4b-it-8bit", .languageModel, "Gemma 4 26B-A4B (8 bits)",
        "mlx-community/gemma-4-26b-a4b-it-8bit", "33c6d23798a0af159529890f79329206dbfbd73c", "Apache-2.0")

    /// The language model of each tier. Only the comfort tier could be measured (M1 Pro, 32 GB).
    public static func languageModel(for tier: HardwareTier) -> ModelPack? {
        switch tier {
        case .unsupported: nil
        case .minimum: gemmaE2B
        case .standard: gemmaE4B
        case .comfort: gemma26BQAT
        case .max: gemma26B8bit
        }
    }

    /// Everything a tier needs, in download order: the small models first, so the progress bar moves at once.
    public static func packs(for tier: HardwareTier) -> [ModelPack] {
        guard let languageModel = languageModel(for: tier) else { return [] }
        return [speechRecognition, voice, languageModel]
    }

    public static let all = [speechRecognition, voice, gemmaE2B, gemmaE4B, gemma26B, gemma26BQAT, gemma26B8bit]

    private static func pack(
        _ id: String, _ role: ModelRole, _ displayName: String, _ repository: String, _ revision: String,
        _ license: String
    ) -> ModelPack {
        ModelPack(id: id, role: role, displayName: displayName, repository: repository, revision: revision,
                  license: license, files: generatedFiles[id] ?? [])
    }
}
