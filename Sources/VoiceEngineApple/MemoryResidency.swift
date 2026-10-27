import Darwin
import Foundation
import MLX
import Synchronization
import VoiceCore

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
    /// `stop`, asked every `stopCheck` pages (64 MB), ends the reads early once it says so.
    static func touch(_ ranges: [Range<UInt>], threads: Int, stop: (@Sendable () -> Bool)? = nil) {
        let parts = split(ranges, into: threads)
        DispatchQueue.concurrentPerform(iterations: parts.count) { i in
            var sum: UInt64 = 0
            var pages = 0
            reading: for range in parts[i] {
                for address in stride(from: range.lowerBound, to: range.upperBound, by: Int(page)) {
                    sum &+= UInt64(UnsafePointer<UInt8>(bitPattern: address)!.pointee)
                    pages += 1
                    if pages % stopCheck == 0, stop?() == true { break reading }
                }
            }
            sink.add(sum, ordering: .relaxed)  // so that the compiler cannot leave the reads out
        }
    }

    /// How many pages `touch` reads between two questions to its `stop`.
    private static let stopCheck = 4096

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

    /// Diagnostics: the process's memory as macOS counts it (`task_info`): its footprint, what of it is in RAM, what macOS
    /// compressed or wrote to swap, the same for its GPU memory alone (Metal's buffers: the weights, the cache and its
    /// copies, MLX's free buffers, the voice's), then the swap in use on the whole Mac.
    static var processText: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "process: unknown" }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Double(swap.xsu_used) / 1e9 : -1
        return String(format: "process: footprint %.2f GB, %.2f GB in RAM, %.2f GB compressed or in swap (GPU memory: "
                      + "%.2f GB, %.2f GB of it compressed or in swap); the Mac's swap in use: %.2f GB, its wired "
                      + "memory %.2f GB, memory pressure %@",
                      Double(info.phys_footprint) / 1e9, Double(info.resident_size) / 1e9,
                      Double(info.compressed) / 1e9, Double(info.ledger_tag_graphics_footprint) / 1e9,
                      Double(info.ledger_tag_graphics_footprint_compressed) / 1e9, swapUsed,
                      Double(wiredBytes) / 1e9, pressure)
    }

    /// The memory wired on the whole Mac (`host_statistics64`): the GPU's driver wires the memory a computation uses (macOS
    /// can then neither compress it nor write it to swap), and lets it go again once the GPU no longer uses it.
    static var wiredBytes: UInt64 {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard withUnsafeMutablePointer(to: &vm, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }) == KERN_SUCCESS else { return 0 }
        return UInt64(vm.wire_count) * UInt64(page)
    }

    /// Diagnostics: the memory pressure macOS reports for the whole Mac (`kern.memorystatus_vm_pressure_level`).
    static var pressure: String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "unknown" }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "level \(level)"
        }
    }

    /// Diagnostics (`VOICE_DEBUG_MEMORY=1`): from the first call on, looks at the Mac's wired memory and memory pressure
    /// every 100 ms, and logs each move of the wired memory by 1 GB or more and each change of pressure: when the GPU's
    /// driver wires the weights for a computation, and when it lets them go.
    static func watchWiring() {
        guard enabled else { return }
        _ = wiringWatch
    }

    private static let wiringWatch: Void = {
        Thread.detachNewThread {
            var logged = wiredBytes
            var level = pressure
            DebugLog.log(String(format: "Mac memory: wired %.2f GB, pressure %@", Double(logged) / 1e9, level))
            while true {
                Thread.sleep(forTimeInterval: 0.1)
                let wired = wiredBytes
                let now = pressure
                guard max(wired, logged) - min(wired, logged) >= 1_000_000_000 || now != level else { continue }
                DebugLog.log(String(format: "Mac memory: wired %.2f → %.2f GB, pressure %@",
                                    Double(logged) / 1e9, Double(wired) / 1e9, now))
                logged = wired
                level = now
            }
        }
    }()

    /// Diagnostics: the paging of the whole Mac since it started (`host_statistics64`) and this process's page faults
    /// (`task_info`), to tell what a computation waited for: the pages macOS brought back from its compressor or from swap
    /// meanwhile, and what it compressed or wrote to swap to make room; and the memory wired on the whole Mac (the GPU's
    /// driver wires the memory a computation uses, and lets it go again when the Mac runs short).
    struct Paging {
        var decompressions: UInt64 = 0
        var compressions: UInt64 = 0
        var swapins: UInt64 = 0
        var swapouts: UInt64 = 0
        var faults: Int64 = 0
        var wired: UInt64 = 0

        /// What happened between `earlier` and this one.
        func text(since earlier: Paging) -> String {
            let pageGB = Double(page) / 1e9
            return String(format: "the Mac decompressed %.2f GB and compressed %.2f GB, read %.2f GB from swap and wrote "
                          + "%.2f GB to it, its wired memory went from %.2f to %.2f GB; %lld page faults in this process",
                          Double(decompressions &- earlier.decompressions) * pageGB,
                          Double(compressions &- earlier.compressions) * pageGB,
                          Double(swapins &- earlier.swapins) * pageGB, Double(swapouts &- earlier.swapouts) * pageGB,
                          Double(earlier.wired) * pageGB, Double(wired) * pageGB, faults - earlier.faults)
        }
    }

    static var paging: Paging {
        var result = Paging()
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        if withUnsafeMutablePointer(to: &vm, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }) == KERN_SUCCESS {
            result.decompressions = vm.decompressions
            result.compressions = vm.compressions
            result.swapins = vm.swapins
            result.swapouts = vm.swapouts
            result.wired = UInt64(vm.wire_count)
        }
        mach_port_deallocate(mach_task_self_, host)
        var events = task_events_info_data_t()
        var eventsCount = mach_msg_type_number_t(MemoryLayout<task_events_info_data_t>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &events, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(eventsCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &eventsCount)
            }
        }) == KERN_SUCCESS {
            result.faults = Int64(events.faults)
        }
        return result
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
