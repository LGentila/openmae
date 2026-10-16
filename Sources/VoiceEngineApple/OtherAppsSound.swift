import CoreAudio
import Darwin
import VoiceCore

/// How loud the other apps (music, videos) are, in speakers mode.
public enum OtherAppsLevel: Sendable {
    /// At rest: untouched.
    case normal
    /// While the assistant prepares or says its answer: lower, still heard.
    case lowered
    /// While the user speaks.
    case silent

    /// The other apps' amplitude, and how many seconds they take to get there.
    fileprivate var duck: (level: Float32, ramp: Float32) {
        switch self {
        case .normal: (1, 0.6)
        case .lowered: (0.4, 0.3)  // about −8 dB: −12 dB was found too faint to hear over a room
        case .silent: (0, 0.15)
        }
    }
}

/// Turns the other apps' sound down on the speakers with Core Audio's ducking (`AudioDeviceDuck`): the system lowers
/// every other process playing on a device, with a ramp, until this app asks for another level or quits.
///
/// Voice processing ducks the other apps the same way and cannot be told not to: its lowest setting is about −4 dB,
/// applied as it starts. The level set here replaces it, as both come from this app, so it is set again right after
/// voice processing starts. `AudioDeviceDuck` is exported by CoreAudio but no longer declared in the macOS SDK: it is
/// looked up at run time, and without it the other apps stay where voice processing puts them.
enum OtherAppsSound {
    private typealias Duck = @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

    private static let duck: Duck? = {
        // RTLD_DEFAULT: every image loaded in the process, CoreAudio included.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else {
            DebugLog.log("audio: AudioDeviceDuck not found, other apps stay where voice processing puts them")
            return nil
        }
        return unsafeBitCast(symbol, to: Duck.self)
    }()

    /// Brings the other apps playing on `devices` to `level`, in its own time or in `ramp` seconds.
    static func set(_ level: OtherAppsLevel, on devices: [AudioObjectID], ramp: Float32? = nil) {
        guard let duck else { return }
        let target = level.duck
        for device in devices {
            let status = duck(device, target.level, nil, ramp ?? target.ramp)
            if status != noErr { DebugLog.log("audio: other apps \(level) on device \(device) failed (\(status))") }
        }
    }
}
