import Darwin
import Foundation
import VoiceCore

/// Finds the models on disk.
///
/// Models are looked for under `AppIdentity.modelsDirectory` first; during development, the download caches
/// of Hugging Face and FluidAudio are used as a fallback.
public enum ModelLocator {
    /// The language model: a folder path, a Hugging Face repository, or nil for this Mac's tier.
    public static func languageModel(_ argument: String? = nil) -> URL? {
        if let argument, FileManager.default.fileExists(atPath: argument) { return URL(fileURLWithPath: argument) }
        let tier = HardwareTier.recommended(for: .current)
        guard let repo = argument ?? ModelCatalog.languageModel(for: tier)?.repository else { return nil }
        let ours = AppIdentity.modelsDirectory.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"))
        if FileManager.default.fileExists(atPath: ours.path) { return ours }
        let hub = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        return try? FileManager.default.contentsOfDirectory(at: hub, includingPropertiesForKeys: nil)
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
    }

    /// Silero VAD (640 KB, MIT): shipped inside the app; the command-line tool finds it in the repository.
    public static func voiceActivity() -> URL? {
        [AppIdentity.modelsDirectory.appendingPathComponent("silero_vad.mlmodelc"),
         Bundle.main.url(forResource: "silero_vad", withExtension: "mlmodelc"),
         URL(fileURLWithPath: "App/Resources/silero_vad.mlmodelc")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public enum ProcessMemory {
    /// Physical memory used by this process (CoreML + MLX + everything), in GB — the figure Activity
    /// Monitor shows as "Memory".
    public static var footprintGB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : -1
    }
}
