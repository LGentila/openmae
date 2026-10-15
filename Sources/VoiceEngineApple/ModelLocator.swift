import Darwin
import Foundation
import VoiceCore

/// Where the engine stages find their models.
///
/// Everything downloaded lives in the models folder (`ModelStore`, filled by `ModelDownloader`); the stages
/// load from there and never go online.
public enum ModelLocator {
    /// Silero VAD (640 KB, MIT): shipped inside the app; the command-line tool finds it in the repository.
    public static func voiceActivity() -> URL? {
        [Bundle.main.url(forResource: "silero_vad", withExtension: "mlmodelc"),
         URL(fileURLWithPath: "App/Resources/silero_vad.mlmodelc")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

extension ModelStore {
    /// FluidAudio's voice wants the folder that CONTAINS "Models": it adds "Models/pocket-tts/…" itself.
    public var voiceBaseFolder: URL { root.deletingLastPathComponent() }
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
