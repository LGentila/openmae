import Darwin
import Foundation
import MLX
import Synchronization

/// The memory of MLX arrays, page by page: read from the CPU, or (diagnostics, `VOICE_DEBUG_MEMORY=1`) counted.
///
/// When the Mac runs short of memory, macOS compresses (then writes to swap) the memory nobody used lately, the model's
/// weights included: on the reference Mac, 87% of Gemma 4 26B's weights were out of RAM 30 s after an answer, and 61 to
/// 97% right after loading. The GPU's own passes then took seconds to bring them back (the next request: 4.3 s for 32
/// tokens instead of 0.3 s; a keep-warm sum: 3.3 to 5.3 s). Read from several CPU threads at once, they came back in
/// 0.57 to 1.7 s, and macOS counts the pages read as used again (`mincore`'s "referenced").
enum MemoryResidency {
    static let enabled = ProcessInfo.processInfo.environment["VOICE_DEBUG_MEMORY"] == "1"
    private static let page = UInt(getpagesize())

    /// The pages the arrays' memory spans, overlapping ranges merged (copies of the cache share their memory until it
    /// changes). The arrays are evaluated already; nothing is read.
    ///
    /// Arrays smaller than a page are left out: for the tiniest ones, `asData(access: .noCopy)` can hand over a copy on
    /// the stack (`Data` keeps up to 14 bytes inline) rather than the array's memory, and reading the page around it
    /// later crashed voice-cli in a test. A range whose first or last page is not mapped is left out too.
    static func ranges(_ arrays: [MLXArray]) -> [Range<UInt>] {
        var ranges: [Range<UInt>] = []
        for array in arrays where array.nbytes >= Int(page) {
            let data = array.asData(access: .noCopy)
            let elements = zip(data.shape, data.strides).reduce(1) { $0 + ($1.0 - 1) * $1.1 }
            data.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress.map({ UInt(bitPattern: $0) }) else { return }
                let end = base + UInt(elements * array.itemSize)
                ranges.append((base & ~(page - 1))..<((end + page - 1) & ~(page - 1)))
            }
        }
        var merged: [Range<UInt>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.filter { mapped($0.lowerBound) && mapped($0.upperBound - page) }
    }

    /// Whether the page at this address is mapped in the process (`mincore` fails otherwise).
    private static func mapped(_ address: UInt) -> Bool {
        var flag: CChar = 0
        return mincore(UnsafeRawPointer(bitPattern: address), Int(page), &flag) == 0
    }

    /// Reads one byte of every page, from several threads at once: what macOS compressed or wrote to swap comes back
    /// now, and the pages count as used. For the 26B's 14.2 GB of weights: 1.7 s with 4 threads when 87% of them were
    /// out of RAM, 0.15 to 0.3 s when all were in. The memory must stay allocated meanwhile (the caller keeps its arrays).
    static func touch(_ ranges: [Range<UInt>], threads: Int) {
        let parts = split(ranges, into: threads)
        DispatchQueue.concurrentPerform(iterations: parts.count) { i in
            var sum: UInt64 = 0
            for range in parts[i] {
                for address in stride(from: range.lowerBound, to: range.upperBound, by: Int(page)) {
                    sum &+= UInt64(UnsafePointer<UInt8>(bitPattern: address)!.pointee)
                }
            }
            sink.add(sum, ordering: .relaxed)  // so that the compiler cannot leave the reads out
        }
    }

    private static let sink = Atomic<UInt64>(0)

    /// The ranges cut into `count` parts of about as many pages each.
    private static func split(_ ranges: [Range<UInt>], into count: Int) -> [[Range<UInt>]] {
        let total = ranges.reduce(0) { $0 + $1.count }
        guard count > 1, total > 0 else { return [ranges] }
        let share = ((UInt(total) / UInt(count)) + page - 1) & ~(page - 1)
        var parts: [[Range<UInt>]] = [[]]
        var room = share
        for var range in ranges {
            while !range.isEmpty {
                let take = min(UInt(range.count), room)
                parts[parts.count - 1].append(range.lowerBound..<range.lowerBound + take)
                range = range.lowerBound + take..<range.upperBound
                room -= take
                if room == 0, parts.count < count {
                    parts.append([])
                    room = share
                } else if room == 0 {
                    room = UInt.max  // the last part takes what is left
                }
            }
        }
        return parts
    }

    struct Count {
        var bytes = 0
        var resident = 0
        /// Pages macOS compressed or wrote to swap. A page neither in RAM nor there was never written.
        var pagedOut = 0
        /// Pages macOS counts as used since it last looked (what decides which memory it compresses first).
        var referenced = 0

        var text: String {
            func share(_ part: Int, empty: Double = 100) -> Double { bytes > 0 ? 100 * Double(part) / Double(bytes) : empty }
            return String(format: "%.0f%% of %.2f GB in RAM, %.0f%% compressed or in swap, %.0f%% used lately",
                          share(resident), Double(bytes) / 1e9, share(pagedOut, empty: 0), share(referenced))
        }
    }

    /// How many of the pages are in RAM, how many macOS compressed or wrote to swap, and how many it counts as used lately
    /// (`mincore`).
    static func count(_ ranges: [Range<UInt>]) -> Count {
        var total = Count()
        for range in ranges {
            var flags = [CChar](repeating: 0, count: range.count / Int(page))
            guard mincore(UnsafeRawPointer(bitPattern: range.lowerBound), range.count, &flags) == 0 else { continue }
            total.bytes += range.count
            for flag in flags {
                if Int32(flag) & MINCORE_INCORE != 0 { total.resident += Int(page) }
                if Int32(flag) & MINCORE_PAGED_OUT != 0 { total.pagedOut += Int(page) }
                if Int32(flag) & MINCORE_REFERENCED != 0 { total.referenced += Int(page) }
            }
        }
        return total
    }
}
