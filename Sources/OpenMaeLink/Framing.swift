import CryptoKit
import Foundation

/// Frames on a byte stream: a 4-byte big-endian length, then the frame.
public enum Frame {
    public static let maxSize = 65_535

    public static func encode(_ body: Data) -> Data {
        precondition(body.count <= maxSize, "frame too large")
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }
}

public struct FramingError: Error, Equatable {
    public let size: Int
}

/// Cuts a byte stream, arriving in pieces of any size, back into frames.
public struct FrameReader: Sendable {
    private var buffer = Data()
    public let maxSize: Int

    public init(maxSize: Int = Frame.maxSize) {
        self.maxSize = maxSize
    }

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// The next complete frame, or nil until more bytes arrive. Throws when a length is beyond `maxSize` (the
    /// stream is then unusable).
    public mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxSize else { throw FramingError(size: length) }
        guard buffer.count >= 4 + length else { return nil }
        let frame = Data(buffer.dropFirst(4).prefix(length))
        buffer = Data(buffer.dropFirst(4 + length))
        return frame
    }

    /// What is left after the frames read so far: the bytes that follow them on the stream.
    public mutating func takeRemainder() -> Data {
        defer { buffer = Data() }
        return buffer
    }
}

// MARK: - Datagrams

/// A sliding window of the last 64 counters seen, as in WireGuard: a datagram whose counter was already seen, or
/// is older than the window, is a replay (or hopelessly late) and is dropped.
public struct ReplayWindow: Sendable {
    public static let size: UInt64 = 64
    private var highest: UInt64?
    /// Bit i: counter `highest - i` was seen.
    private var seen: UInt64 = 0

    public init() {}

    /// Records `counter` and tells whether it is new.
    public mutating func accept(_ counter: UInt64) -> Bool {
        guard let top = highest else {
            highest = counter
            seen = 1
            return true
        }
        if counter > top {
            let shift = counter - top
            seen = shift >= Self.size ? 1 : seen << shift | 1
            highest = counter
            return true
        }
        let age = top - counter
        guard age < Self.size else { return false }
        let bit: UInt64 = 1 << age
        guard seen & bit == 0 else { return false }
        seen |= bit
        return true
    }
}

/// One direction of the datagrams: `0xA0 | counter (8 bytes) | ChaCha20-Poly1305(plaintext)`, the 9 header bytes
/// authenticated too. Its key is derived from the reliable channel's key of the same direction, so the two never
/// share a key and nonce.
public struct DatagramCipher: Sendable {
    public static let kind: UInt8 = 0xA0
    public static let overhead = 9 + 16
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private var window = ReplayWindow()

    public init(deriveFrom cipher: NoiseCipher) {
        key = cipher.withKeyBytes { bytes in
            SymmetricKey(data: HMAC<SHA256>.authenticationCode(
                for: Data("openmae/1 datagrams".utf8), using: SymmetricKey(data: Data(bytes))))
        }
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard counter < .max else { throw NoiseError.nonceExhausted }
        defer { counter += 1 }
        var header = Data([Self.kind])
        withUnsafeBytes(of: counter.bigEndian) { header.append(contentsOf: $0) }
        return header + (try NoiseCipher.seal(plaintext, key: key, nonce: counter, ad: header))
    }

    /// The plaintext, or nil for a datagram that is not authentic, or already received.
    public mutating func open(_ datagram: Data) -> Data? {
        guard datagram.count >= Self.overhead, datagram.first == Self.kind else { return nil }
        let header = Data(datagram.prefix(9))
        let counter = header.dropFirst().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let plaintext = try? NoiseCipher.open(Data(datagram.dropFirst(9)), key: key, nonce: counter, ad: header)
        else { return nil }
        // Only an authentic datagram moves the window: forged ones cannot push real ones out of it.
        guard window.accept(counter) else { return nil }
        return plaintext
    }
}

/// Sound stream numbers: tenths of a second since 1970, so that a new stream (a new conversation, a microphone
/// restarted) is numbered above the previous ones without anything to remember. Wraps after 13 years.
public enum StreamNumber {
    public static var now: UInt32 { UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 10)) }
}

/// What a sound datagram carries: `stream (4 bytes) | sequence (4 bytes) | one Opus packet of 20 ms`.
public struct AudioPacket: Sendable, Equatable {
    public var stream: UInt32
    public var sequence: UInt32
    public var payload: Data

    public init(stream: UInt32, sequence: UInt32, payload: Data) {
        self.stream = stream
        self.sequence = sequence
        self.payload = payload
    }

    public var encoded: Data {
        var data = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: stream.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    public init?(_ data: Data) {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        stream = bytes[0..<4].reduce(0) { $0 << 8 | UInt32($1) }
        sequence = bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        payload = Data(data.dropFirst(8))
    }
}
