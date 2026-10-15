import Foundation

/// What the engine needs to know about the Mac to pick models.
public struct HardwareProfile: Sendable, Equatable, Codable {
    /// Physical memory in GiB (a "32 Go" Mac reports 32).
    public var memoryGiB: Double
    /// e.g. "Apple M1 Pro".
    public var chipName: String

    public init(memoryGiB: Double, chipName: String) {
        self.memoryGiB = memoryGiB
        self.chipName = chipName
    }

    /// The Mac this code runs on.
    public static var current: HardwareProfile {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let chip = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return HardwareProfile(
            memoryGiB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            chipName: chip)
    }

    public var isAppleSilicon: Bool { chipName.hasPrefix("Apple M") }
}

/// Hardware tiers. The tier decides which language model is downloaded; speech models are the same
/// everywhere. Thresholds and choices come from measurements on the reference Mac (M1 Pro, 32 GB); the other
/// tiers are estimates.
public enum HardwareTier: String, Sendable, Codable, CaseIterable, Comparable {
    case unsupported, minimum, standard, comfort, max

    public static func recommended(for hw: HardwareProfile) -> HardwareTier {
        guard hw.isAppleSilicon else { return .unsupported }
        switch hw.memoryGiB {
        case ..<7: return .unsupported
        case ..<15: return .minimum  // 8 GB
        case ..<30: return .standard  // 16, 18, 24 GB
        case ..<46: return .comfort  // 32, 36 GB
        default: return .max  // 48 GB and more
        }
    }

    /// Only one tier could be measured: the reference Mac is an M1 Pro with 32 GB.
    public var isTested: Bool { self == .comfort }

    public static func < (a: HardwareTier, b: HardwareTier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// A downloadable model and what the user needs to know about it.
public struct ModelSpec: Sendable, Equatable, Codable {
    public var displayName: String
    /// Hugging Face repository the files come from.
    public var repository: String
    /// Approximate download size, shown before downloading.
    public var downloadGB: Double
    public var license: String
}

/// Which models each tier uses.
public enum ModelCatalog {
    public static func languageModel(for tier: HardwareTier) -> ModelSpec? {
        switch tier {
        case .unsupported: return nil
        case .minimum:
            return ModelSpec(displayName: "Gemma 4 E2B", repository: "mlx-community/gemma-4-e2b-it-4bit",
                             downloadGB: 3.6, license: "Apache-2.0")
        case .standard:
            return ModelSpec(displayName: "Gemma 4 E4B", repository: "mlx-community/gemma-4-e4b-it-4bit",
                             downloadGB: 5.2, license: "Apache-2.0")
        case .comfort:
            return ModelSpec(displayName: "Gemma 4 26B-A4B",
                             repository: "mlx-community/gemma-4-26b-a4b-it-4bit", downloadGB: 15.3,
                             license: "Apache-2.0")
        case .max:
            return ModelSpec(displayName: "Gemma 4 26B-A4B (8 bits)",
                             repository: "mlx-community/gemma-4-26b-a4b-it-8bit", downloadGB: 28.0,
                             license: "Apache-2.0")
        }
    }

    public static let speechRecognition = ModelSpec(
        displayName: "Parakeet TDT 0.6B v3", repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        downloadGB: 0.46, license: "CC-BY-4.0")
    public static let voiceActivity = ModelSpec(
        displayName: "Silero VAD v6.2.1", repository: "aufklarer/Silero-VAD-v6.2.1-CoreML",
        downloadGB: 0.001, license: "MIT")
    public static let speechSynthesis = ModelSpec(
        displayName: "Pocket TTS (French)", repository: "FluidInference/pocket-tts-coreml",
        downloadGB: 1.8, license: "CC-BY-4.0")
}
