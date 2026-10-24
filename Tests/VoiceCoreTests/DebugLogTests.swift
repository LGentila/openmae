import Foundation
import Testing

@testable import VoiceCore

/// The debug log (VOICE_DEBUG=1) lets the process go on when nothing reads its stderr any more: on 2026-10-21 the iPhone
/// app aborted twice, at the first line it logged after the console stream that read its stderr had dropped.
@Suite("Debug log without a reader")
struct DebugLogTests {
    /// Stderr is put on a pipe for the time of the test. A line of the log goes into it and is read back, in the log's
    /// format; then the pipe's reading end is closed, as when the reader is gone, and the log goes on writing into it.
    /// Before, the first of those writes ended these tests (SIGPIPE, or an Objective-C exception and abort() when
    /// SIGPIPE is ignored). The reader stays open until the first line is written, so that another test's write to
    /// stderr meanwhile cannot meet a pipe without a reader before the log has set it not to send SIGPIPE.
    @Test func linesIntoAStderrWithoutAReaderLetTheProcessGoOn() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        let (reading, writing) = (ends[0], ends[1])
        let saved = dup(STDERR_FILENO)
        try #require(saved >= 0)
        dup2(writing, STDERR_FILENO)
        close(writing)

        DebugLog.emit("a line still read")
        let noSIGPIPE = fcntl(STDERR_FILENO, F_GETNOSIGPIPE)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { read(reading, $0.baseAddress, $0.count) }
        close(reading)  // whatever read stderr is gone
        for n in 1...200 { DebugLog.emit("line \(n), read by nobody") }
        let lastWritten = DebugLog.writeToStandardError("and one more\n")

        dup2(saved, STDERR_FILENO)
        close(saved)
        // Still here: the process went on.
        #expect(noSIGPIPE == 1)
        #expect(!lastWritten)
        let received = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
        let line = try #require(received.split(separator: "\n").first { $0.hasSuffix("] a line still read") }, "\(received)")
        // The format is unchanged: the milliseconds since the log's start, on nine characters or more, one decimal.
        let stamp = String(line.dropFirst().prefix { $0 != "]" })
        let ms = try #require(Double(stamp.trimmingCharacters(in: .whitespaces)), "\(line)")
        #expect(line == "[\(stamp)] a line still read" && stamp == String(format: "%9.1f", ms))
    }
}
