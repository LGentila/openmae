import Foundation
import Testing

@testable import VoiceCore

/// Reading another program's pipes (PipeLines). Claude Code's reports were read with FileHandle.bytes next to its error
/// output, which stays open and silent: they all came at once when it ended.
@Suite("Pipe lines")
struct PipeLinesTests {
    /// Two pipes read at once, as a program's output and error output are: a line written into one comes at once while
    /// the other stays open and says nothing. With FileHandle.bytes.lines, it only came when the other pipe got a line
    /// or closed.
    @Test func aLineComesWhileTheOtherPipeStaysSilent() async throws {
        let output = Pipe()
        let errors = Pipe()
        let errorLines = Lines.reading(PipeLines.lines(of: errors.fileHandleForReading))  // waiting first
        let outputLines = Lines.reading(PipeLines.lines(of: output.fileHandleForReading))
        try output.fileHandleForWriting.write(contentsOf: Data("first\n".utf8))
        #expect(await outputLines.first(1) == ["first"])
        try output.fileHandleForWriting.write(contentsOf: Data("second\n".utf8))
        #expect(await outputLines.first(2) == ["first", "second"])
        try errors.fileHandleForWriting.write(contentsOf: Data("a warning\n".utf8))
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        #expect(await outputLines.all() == ["first", "second"])
        #expect(await errorLines.all() == ["a warning"])
    }

    /// Only a line feed ends a line (a JSON line may hold U+2028 as it is; FileHandle.bytes.lines also broke lines there
    /// and at a lone carriage return), the carriage return just before it goes, a line longer than one read comes whole,
    /// an empty line comes, and the last one comes even without its line feed.
    @Test func aLineEndsOnlyAtALineFeed() async throws {
        let pipe = Pipe()
        let lines = Lines.reading(PipeLines.lines(of: pipe.fileHandleForReading))
        let long = String(repeating: "x", count: 200_000)
        let written = "{\"text\":\"a\u{2028}b\"}\r\nsecond\rstill second\n\(long)\n\nlast"
        // From a thread of its own: the pipe holds 64 KB, and only its reader makes room.
        let writer = pipe.fileHandleForWriting
        Thread.detachNewThread {
            try? writer.write(contentsOf: Data(written.utf8))
            try? writer.close()
        }
        #expect(await lines.all() == ["{\"text\":\"a\u{2028}b\"}", "second\rstill second", long, "", "last"])
    }
}

/// A stream's lines, taken in as they come.
private actor Lines {
    private var received: [String] = []
    private var ended = false

    static func reading(_ stream: AsyncStream<Data>) -> Lines {
        let lines = Lines()
        Task { await lines.take(stream) }
        return lines
    }

    private func take(_ stream: AsyncStream<Data>) async {
        for await line in stream { received.append(String(decoding: line, as: UTF8.self)) }
        ended = true
    }

    /// The lines received once there are `count` of them, or those that came within two seconds.
    func first(_ count: Int) async -> [String] {
        let deadline = ContinuousClock.now + .seconds(2)
        while received.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return received
    }

    /// All the lines once the stream has ended, or those that came within five seconds.
    func all() async -> [String] {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ended, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return received
    }
}
