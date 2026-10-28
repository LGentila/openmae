import Foundation

/// The lines another program writes into a pipe (its output, its error output), each handed over as soon as it is
/// written.
///
/// Not `FileHandle.bytes.lines`: those reads take turns on one reader that the whole process shares, and a read waits
/// there until its pipe has something. So while one pipe stays open and says nothing (a program's error output, as a
/// rule), every other pipe read that way waits with it: Claude Code's reports, read next to its error output, all came
/// at once when it ended. Here each pipe is read with read(2) on a thread of its own.
public enum PipeLines {
    /// The lines `handle` gives until its end, without their line feed (nor a carriage return just before it); the last
    /// one even without a line feed. Only a line feed ends a line: a JSON line may hold U+2028 or U+2029 as they are
    /// (FileHandle's lines broke there, and the two halves were lost). `handle` is closed at its end.
    public static func lines(of handle: FileHandle) -> AsyncStream<Data> {
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        Thread.detachNewThread {
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var line = Data()
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    let why = errno
                    if why == EINTR { continue }
                    DebugLog.log("pipe: reading failed (\(String(cString: strerror(why))))")
                }
                guard count > 0 else { break }
                var start = 0
                while let newline = buffer[start..<count].firstIndex(of: 0x0A) {
                    line.append(contentsOf: buffer[start..<newline])
                    continuation.yield(withoutCarriageReturn(line))
                    line = Data()
                    start = newline + 1
                }
                line.append(contentsOf: buffer[start..<count])
            }
            if !line.isEmpty { continuation.yield(withoutCarriageReturn(line)) }
            try? handle.close()
            continuation.finish()
        }
        return lines
    }

    private static func withoutCarriageReturn(_ line: Data) -> Data {
        line.last == 0x0D ? Data(line.dropLast()) : line
    }
}
