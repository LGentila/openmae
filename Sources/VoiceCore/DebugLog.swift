import Foundation

/// Timestamped trace of the engine's steps, for diagnosing latency. Off unless the environment
/// variable VOICE_DEBUG=1 is set (the app's debug panel will use the metrics instead).
public enum DebugLog {
    public static let enabled = ProcessInfo.processInfo.environment["VOICE_DEBUG"] == "1"
    private static let start = ContinuousClock.now

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let d = ContinuousClock.now - start
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        FileHandle.standardError.write(Data(String(format: "[%9.1f] %@\n", ms, message()).utf8))
    }
}
