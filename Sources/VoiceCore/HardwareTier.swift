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

/// Hardware tiers. The tier decides which language model is downloaded (ModelCatalog.swift); speech models
/// are the same everywhere. Thresholds and choices come from measurements on the reference Mac (M1 Pro,
/// 32 GB); the other tiers are estimates. The user can force another tier (Settings › Advanced).
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

    /// The tiers the user can choose from (Settings › Advanced).
    public static let selectable: [HardwareTier] = [.minimum, .standard, .comfort, .max]

    /// Only one tier could be measured: the reference Mac is an M1 Pro with 32 GB.
    public var isTested: Bool { self == .comfort }

    public static func < (a: HardwareTier, b: HardwareTier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}
