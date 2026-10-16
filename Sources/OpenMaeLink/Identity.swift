import CryptoKit
import Foundation
import Security

/// A device's keys, made once and kept in its keychain: an X25519 key for Noise (end-to-end encryption) and an
/// Ed25519 key to prove to a relay that it is who it says (the Mac registers with it).
public struct DeviceIdentity: Sendable {
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey
    public let signingKey: Curve25519.Signing.PrivateKey

    public init(agreementKey: Curve25519.KeyAgreement.PrivateKey, signingKey: Curve25519.Signing.PrivateKey) {
        self.agreementKey = agreementKey
        self.signingKey = signingKey
    }

    public static func generate() -> DeviceIdentity {
        DeviceIdentity(agreementKey: .init(), signingKey: .init())
    }

    /// The Noise static key the other devices know this one by.
    public var publicKey: Data { agreementKey.publicKey.rawRepresentation }

    public var id: String { DeviceID.make(signingKey: signingKey.publicKey.rawRepresentation) }

    /// Both private keys, 64 bytes, for the keychain.
    var serialized: Data { agreementKey.rawRepresentation + signingKey.rawRepresentation }

    init?(serialized data: Data) {
        guard data.count == 64,
              let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data.prefix(32)),
              let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: data.suffix(32))
        else { return nil }
        self.init(agreementKey: agreement, signingKey: signing)
    }
}

/// Device ids: the first 16 bytes of SHA-256 of the Ed25519 public key, in base32 (26 characters).
public enum DeviceID {
    public static func make(signingKey: Data) -> String {
        Base32.encode(Data(SHA256.hash(data: signingKey).prefix(16)))
    }
}

/// RFC 4648 base32, lowercase, without padding.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    public static func encode(_ data: Data) -> String {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int(buffer >> UInt32(bits - 5) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }
}

/// base64url without padding (RFC 4648 §5), as the pairing link and the relay messages use it.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !base64.contains("=") else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

// MARK: - Where the keys are kept

public protocol IdentityStore: Sendable {
    func load() throws -> DeviceIdentity?
    func save(_ identity: DeviceIdentity) throws
    func delete() throws
}

extension IdentityStore {
    /// The device's identity, made on first use.
    public func loadOrCreate() throws -> DeviceIdentity {
        if let identity = try load() { return identity }
        let identity = DeviceIdentity.generate()
        try save(identity)
        return identity
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        "keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// The keychain, as one generic password item. On the iPhone it is readable after the first unlock (a conversation
/// continues with the screen locked) and never leaves this device (no backup, no iCloud Keychain).
public struct KeychainIdentityStore: IdentityStore {
    public let service: String
    public let account: String

    public init(service: String, account: String = "device-identity") {
        self.service = service
        self.account = account
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func load() throws -> DeviceIdentity? {
        var result: CFTypeRef?
        var search = query
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return DeviceIdentity(serialized: data)
    }

    public func save(_ identity: DeviceIdentity) throws {
        try delete()
        var item = query
        item[kSecValueData] = identity.serialized
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel] = "OpenMaé device keys"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// A file readable only by the user: for the command-line tool, which plays a fake iPhone.
public struct FileIdentityStore: IdentityStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> DeviceIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DeviceIdentity(serialized: data)
    }

    public func save(_ identity: DeviceIdentity) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try identity.serialized.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete() throws {
        try? FileManager.default.removeItem(at: url)
    }
}
