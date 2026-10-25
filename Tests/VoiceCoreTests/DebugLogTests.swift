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
    /// That pipe is the whole process's stderr, so the line is not alone in it: other tests' writes, os_log messages
    /// (mirrored to stderr under xcodebuild) and XCTest's "XCTestOutputBarrier" marker, written without a newline, can
    /// come just before it. On 2026-10-25 the line read back began with that marker, and its stamp, cut from the start
    /// of the line, did not parse. So the line carries a message of its own, its stamp is read from the brackets just
    /// before that message, and a write without its newline goes in first, so that this case is always there.
    @Test func linesIntoAStderrWithoutAReaderLetTheProcessGoOn() throws {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        let (reading, writing) = (ends[0], ends[1])
        let saved = dup(STDERR_FILENO)
        try #require(saved >= 0)
        dup2(writing, STDERR_FILENO)
        close(writing)

        let message = "a line still read, \(UUID().uuidString)"
        DebugLog.writeToStandardError("another write, without its newline")
        DebugLog.emit(message)
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
        // The line is found by its message, wherever it starts: its stamp lies between the "] " just before the message
        // and the last "[" before that (a stamp has none).
        let end = try #require(received.range(of: "] \(message)\n"), "\(received.debugDescription)")
        let opening = try #require(received[..<end.lowerBound].lastIndex(of: "["), "\(received.debugDescription)")
        let stamp = String(received[received.index(after: opening)..<end.lowerBound])
        // The format is unchanged: the milliseconds since the log's start, on nine characters or more, one decimal. And
        // never below zero, even in the first line a process logs, which this one is in a plain run of the tests.
        let ms = try #require(Double(stamp.trimmingCharacters(in: .whitespaces)), "\(received.debugDescription)")
        #expect(stamp == String(format: "%9.1f", ms))
        #expect(!stamp.contains("-"), "\(stamp)")
    }
}
