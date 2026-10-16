import Foundation

/// The iPhone's jitter buffer for the assistant's voice.
///
/// The Mac sends the voice as fast as it is produced, usually ahead of real time, so most of the time frames simply
/// queue up in the player. What this decides is when to hand frames to the player:
///
/// - at the start of a voice stream, and again whenever the player ran dry in the middle of one, frames wait until
///   `target` of them are there (60 ms at first), so that the next ones have time to arrive;
/// - each time the player runs dry in the middle of a stream, the target grows by 20 ms (up to 200 ms), and it
///   comes back down by 20 ms (to 40 ms) after 10 s without running dry;
/// - a frame that does not come while later ones do is lost: once two later frames are there, or the player is
///   about to run dry, it is concealed (the decoder makes it up from the previous ones) and playback goes on;
/// - a frame that comes after its turn is dropped.
public struct VoiceJitterBuffer: Sendable {
    public enum Output: Sendable, Equatable {
        case packet(Data)
        /// A lost frame, to be concealed by the decoder.
        case conceal
    }

    public static let frameMs = 20.0
    public static let minTarget = 2
    public static let maxTarget = 10

    /// Frames to gather before playing, at the start of a stream and after running dry.
    public private(set) var target = 3
    public private(set) var stream: UInt32?
    /// Next frame to hand to the player.
    private var cursor: UInt32 = 0
    private var waiting: [UInt32: Data] = [:]
    /// The stream's length, once the Mac said it.
    private var totalFrames: UInt32?
    private var gathering = true
    private var stopped: Set<UInt32> = []
    private var calmSince: Double = 0
    /// Lost frames concealed so far, for the measurements.
    public private(set) var concealed = 0
    public private(set) var underruns = 0

    public init() {}

    /// A frame arrived. Returns what the player can have now. `scheduled`: frames still queued in the player.
    public mutating func insert(_ packet: AudioPacket, scheduled: Int, now: Double) -> [Output] {
        guard !stopped.contains(packet.stream) else { return [] }
        if packet.stream != stream {
            // A newer stream replaces the previous one (the previous one ended or was stopped).
            guard stream.map({ packet.stream > $0 }) ?? true else { return [] }
            begin(packet.stream)
        }
        guard packet.sequence >= cursor, waiting[packet.sequence] == nil else { return [] }
        if let totalFrames, packet.sequence >= totalFrames { return [] }
        waiting[packet.sequence] = packet.payload
        return release(scheduled: scheduled, now: now)
    }

    /// The Mac said how many frames stream `stream` has.
    public mutating func end(stream: UInt32, frames: UInt32, scheduled: Int, now: Double) -> [Output] {
        guard !stopped.contains(stream) else { return [] }
        if self.stream != stream {
            guard self.stream.map({ stream > $0 }) ?? true else { return [] }
            begin(stream)
        }
        totalFrames = frames
        waiting = waiting.filter { $0.key < frames }
        gathering = false  // nothing more to wait for than what is missing
        return release(scheduled: scheduled, now: now)
    }

    /// The player ran dry, or is about to (`scheduled` frames left): conceal what is missing rather than wait.
    public mutating func playerNeedsMore(scheduled: Int, now: Double) -> [Output] {
        guard let stream, !stopped.contains(stream) else { return [] }
        if scheduled == 0, !gathering, !isComplete, waiting.isEmpty {
            // Ran dry in the middle of a stream: the voice (or the network) is slower than real time right now.
            underruns += 1
            target = min(target + 1, Self.maxTarget)
            calmSince = now
            gathering = true
            return []
        }
        return release(scheduled: scheduled, now: now, urgent: scheduled <= 1)
    }

    /// The user interrupted: everything of `stream` is dropped, and its late frames will be.
    public mutating func stop(stream: UInt32) {
        stopped.insert(stream)
        if self.stream == stream {
            waiting = [:]
            totalFrames = cursor
        }
    }

    /// Every frame of the current stream has been handed over (or the stream was stopped).
    public var isComplete: Bool {
        guard let stream else { return true }
        if stopped.contains(stream) { return true }
        return totalFrames.map { cursor >= $0 } ?? false
    }

    private mutating func begin(_ newStream: UInt32) {
        stream = newStream
        cursor = 0
        waiting = [:]
        totalFrames = nil
        gathering = true
    }

    private mutating func release(scheduled: Int, now: Double, urgent: Bool = false) -> [Output] {
        if now - calmSince > 10, target > Self.minTarget {
            target -= 1
            calmSince = now
        }
        if gathering {
            // Enough frames in a row, or the end of a short stream: start.
            var run = 0
            while waiting[cursor + UInt32(run)] != nil { run += 1 }
            let ended = totalFrames.map { cursor + UInt32(run) >= $0 } ?? false
            guard run >= target || ended || (urgent && waiting.count >= target) else { return [] }
            gathering = false
        }
        var out: [Output] = []
        while !isComplete {
            if let payload = waiting.removeValue(forKey: cursor) {
                out.append(.packet(payload))
                cursor += 1
                continue
            }
            // The next frame is missing (every waiting frame is a later one). Lost when two later frames are there, or
            // one and the player is about to run dry, or when the stream has ended and the player is about to run dry.
            let later = waiting.count
            let aboutToRunDry = urgent || scheduled + out.count <= 1
            guard later >= 2 || (later >= 1 && aboutToRunDry) || (totalFrames != nil && aboutToRunDry) else { break }
            out.append(.conceal)
            concealed += 1
            cursor += 1
        }
        return out
    }
}

/// The Mac's side of the microphone: frames delivered in order, a lost one concealed once the next ones arrived.
/// The microphone runs in real time, so frames are not held long: at most two frames wait for a missing one.
public struct MicrophoneReorder: Sendable {
    public enum Output: Sendable, Equatable {
        case packet(Data)
        case conceal
        /// A new microphone stream started (the iPhone restarted its microphone): reset the decoder.
        case newStream
    }

    private var stream: UInt32?
    private var expected: UInt32 = 0
    private var waiting: [UInt32: Data] = [:]
    public private(set) var concealed = 0

    public init() {}

    public mutating func insert(_ packet: AudioPacket) -> [Output] {
        var out: [Output] = []
        if packet.stream != stream {
            guard stream.map({ packet.stream > $0 }) ?? true else { return [] }
            stream = packet.stream
            expected = 0
            waiting = [:]
            out.append(.newStream)
        }
        guard packet.sequence >= expected else { return out }  // too late: its turn is gone
        waiting[packet.sequence] = packet.payload
        while true {
            if let payload = waiting.removeValue(forKey: expected) {
                out.append(.packet(payload))
                expected += 1
            } else if let first = waiting.keys.min(), first > expected, waiting.count >= 2 || first - expected > 2 {
                // Missing while later frames arrived: lost. Big gaps (the network stalled) are not filled frame by
                // frame beyond 100 ms: the rest is skipped.
                let gap = first - expected
                for _ in 0..<min(gap, 5) {
                    out.append(.conceal)
                    concealed += 1
                }
                expected = first
            } else {
                break
            }
        }
        return out
    }
}
