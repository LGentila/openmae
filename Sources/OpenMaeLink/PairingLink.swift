import Foundation
import Security

/// What the Mac's QR code says, as a universal link:
///
///     https://openmae.com/p#v=1&id=<Mac id>&pk=<Mac key>&relay=<relay URL>&code=<32-byte code>&name=<Mac name>
///
/// Everything is after the `#`: a browser never sends that part to the server, so openmae.com sees neither the key
/// nor the code. The camera opens the app with it (or the page invites to install the app); the app's own scanner
/// reads the same link. The relay travels in it, so the iPhone follows the relay its Mac chose.
public struct PairingLink: Sendable, Equatable {
    public static let base = URL(string: "https://openmae.com/p")!

    public var macID: String
    /// The Mac's Noise static key (X25519), 32 bytes.
    public var macKey: Data
    /// nil: the Mac uses no relay (reachable at home only).
    public var relay: URL?
    /// The pre-shared key of the pairing handshake, 32 bytes. Valid 5 minutes, once.
    public var code: Data
    public var macName: String

    public init(macID: String, macKey: Data, relay: URL?, code: Data, macName: String) {
        self.macID = macID
        self.macKey = macKey
        self.relay = relay
        self.code = code
        self.macName = macName
    }

    public var url: URL {
        var fields = [("v", "1"), ("id", macID), ("pk", Base64URL.encode(macKey))]
        if let relay { fields.append(("relay", relay.absoluteString)) }
        fields += [("code", Base64URL.encode(code)), ("name", macName)]
        let fragment = fields.map { "\($0)=\(Self.escape($1))" }.joined(separator: "&")
        return URL(string: Self.base.absoluteString + "#" + fragment)!
    }

    /// Reads a link from the QR code; nil if it is not one of ours (or from a version this app does not know).
    public init?(url: URL) {
        guard url.scheme == "https", url.host?.lowercased() == Self.base.host, url.path == Self.base.path,
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
        else { return nil }
        var fields: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = parts[1].removingPercentEncoding else { return nil }
            fields[parts[0]] = value
        }
        guard fields["v"] == "1", let id = fields["id"], id.count == 26,
              let key = fields["pk"].flatMap(Base64URL.decode), key.count == 32,
              let code = fields["code"].flatMap(Base64URL.decode), code.count == 32
        else { return nil }
        var relay: URL?
        if let text = fields["relay"] {
            guard let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") else { return nil }
            relay = url
        }
        self.init(macID: id, macKey: key, relay: relay, code: code, macName: fields["name"] ?? "Mac")
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The Mac's side of a pairing in progress: one code at a time, valid 5 minutes, used once.
public struct PairingCode: Sendable, Equatable {
    public static let lifetime: TimeInterval = 5 * 60

    public let code: Data
    public let expires: Date
    public private(set) var isUsed = false

    public init(now: Date = Date()) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        code = Data(bytes)
        expires = now.addingTimeInterval(Self.lifetime)
    }

    public func isValid(at now: Date = Date()) -> Bool { !isUsed && now < expires }

    public mutating func use() { isUsed = true }
}
