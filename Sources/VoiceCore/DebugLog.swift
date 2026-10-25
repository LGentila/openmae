import Foundation

/// Timestamped trace of the engine's steps, for diagnosing latency. Off unless the environment
/// variable VOICE_DEBUG=1 is set (the app's debug panel will use the metrics instead).
public enum DebugLog {
    public static let enabled = ProcessInfo.processInfo.environment["VOICE_DEBUG"] == "1"
    private static let start = ContinuousClock.now

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        emit(message())
    }

    /// Writes one line of the log to stderr, enabled or not (the tests call it directly).
    static func emit(_ message: String) {
        // The start is read before the clock: the first line a process logs is what sets it, and read after, the
        // clock came first and that line's stamp was a hair below zero ("-0.0").
        let origin = start
        let d = ContinuousClock.now - origin
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        writeToStandardError(String(format: "[%9.1f] %@\n", ms, message))
    }

    /// Writes `text` to stderr, and lets a failed write go: whatever reads stderr (a pipe into `head`, the console
    /// stream of `devicectl … --console`, a terminal) can be gone, and a log line must not end the process then.
    /// `FileHandle.write(_:)` raised an Objective-C exception that Swift cannot catch, and the process aborted; and a
    /// write into a pipe without a reader sends SIGPIPE, which ends it too. So the bytes go through write(2), whose
    /// failure is only a return value, and stderr is first set not to send SIGPIPE (`F_SETNOSIGPIPE`): before every
    /// write, since another file may have been put on descriptor 2 since the last one. Returns whether all of `text`
    /// was written.
    @discardableResult
    public static func writeToStandardError(_ text: String) -> Bool {
        _ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)
        var text = text
        return text.withUTF8 { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(STDERR_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
