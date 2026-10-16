import CryptoKit
import Foundation

// The Noise Protocol Framework (revision 34), with the only choices OpenMaé uses: Curve25519, ChaChaPoly, SHA-256,
// and two handshake patterns:
//
//   IK      the iPhone already knows the Mac's static key (sessions, after pairing)
//             <- s
//             ...
//             -> e, es, s, ss
//             <- e, ee, se
//
//   XXpsk3  neither side knows the other's key; a 32-byte code from the pairing link is mixed in (pairing)
//             -> e
//             <- e, ee, s, es
//             -> s, se, psk
//
// Built on CryptoKit and checked against the official test vectors (Tests/OpenMaeLinkTests/NoiseTests.swift).

public enum NoiseError: Error, Equatable, Sendable {
    /// A message could not be authenticated: wrong key, tampered with, or replayed.
    case decryptionFailed
    case malformedMessage
    /// A message written or read when the handshake expects the other side to speak, or after it ended.
    case outOfTurn
    case handshakeIncomplete
    /// 2^64 − 1 messages were sent with the same key.
    case nonceExhausted
    /// The pattern needs a key or a pre-shared key that was not given.
    case missingKey
}

public enum NoisePattern: String, Sendable {
    case IK
    case XXpsk3

    fileprivate enum Token { case e, s, ee, es, se, ss, psk }

    fileprivate var messages: [[Token]] {
        switch self {
        case .IK: [[.e, .es, .s, .ss], [.e, .ee, .se]]
        case .XXpsk3: [[.e], [.e, .ee, .s, .es], [.s, .se, .psk]]
        }
    }

    /// `<- s`: the responder's static key is known to the initiator before the handshake.
    fileprivate var responderStaticIsPreMessage: Bool { self == .IK }

    fileprivate var usesPreSharedKey: Bool { self == .XXpsk3 }

    var protocolName: String { "Noise_\(rawValue)_25519_ChaChaPoly_SHA256" }
}

/// One direction of an established Noise session: a key and a counter used as the nonce.
public struct NoiseCipher: Sendable {
    let key: SymmetricKey
    public private(set) var nonce: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    public mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        defer { nonce += 1 }
        return try Self.seal(plaintext, key: key, nonce: nonce, ad: ad)
    }

    public mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let plaintext = try Self.open(ciphertext, key: key, nonce: nonce, ad: ad)
        nonce += 1
        return plaintext
    }

    /// The raw key, to derive the keys of other channels from (the datagrams).
    func withKeyBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try key.withUnsafeBytes(body)
    }

    // ChaChaPoly as Noise defines it: the 96-bit nonce is 32 zero bits then the counter in little-endian; the
    // output is the ciphertext followed by the 16-byte tag.

    static func nonceBytes(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)  // 12 bytes: cannot fail
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonceBytes(nonce), authenticating: ad)
        return box.ciphertext + box.tag
    }

    static func open(_ ciphertext: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw NoiseError.decryptionFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonceBytes(nonce), ciphertext: ciphertext.dropLast(16),
                                               tag: ciphertext.suffix(16))
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseError.decryptionFailed
        }
    }
}

/// The symmetric state of a handshake: chaining key, handshake hash and the current cipher.
private struct SymmetricState {
    var chainingKey: Data
    var hash: Data
    var cipher: NoiseCipher?

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        hash = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        chainingKey = hash
    }

    mutating func mixKey(_ input: Data) {
        let (ck, key) = Self.hkdf2(chainingKey, input)
        chainingKey = ck
        cipher = NoiseCipher(key: SymmetricKey(data: key))
    }

    mutating func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    mutating func mixKeyAndHash(_ input: Data) {
        let (ck, tempHash, key) = Self.hkdf3(chainingKey, input)
        chainingKey = ck
        mixHash(tempHash)
        cipher = NoiseCipher(key: SymmetricKey(data: key))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher?.encrypt(plaintext, ad: hash) ?? plaintext
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher?.decrypt(ciphertext, ad: hash) ?? ciphertext
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipher, NoiseCipher) {
        let (k1, k2) = Self.hkdf2(chainingKey, Data())
        return (NoiseCipher(key: SymmetricKey(data: k1)), NoiseCipher(key: SymmetricKey(data: k2)))
    }

    var hasKey: Bool { cipher != nil }

    // HKDF as Noise defines it (with HMAC-SHA256).

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hkdf2(_ chainingKey: Data, _ input: Data) -> (Data, Data) {
        let temp = hmac(chainingKey, input)
        let one = hmac(temp, Data([1]))
        return (one, hmac(temp, one + Data([2])))
    }

    static func hkdf3(_ chainingKey: Data, _ input: Data) -> (Data, Data, Data) {
        let temp = hmac(chainingKey, input)
        let one = hmac(temp, Data([1]))
        let two = hmac(temp, one + Data([2]))
        return (one, two, hmac(temp, two + Data([3])))
    }
}

/// A Noise handshake, from either side. Write and read its messages in turn; once `isComplete`, `split()` gives
/// the two ciphers of the session.
public struct NoiseHandshake: Sendable {
    public let pattern: NoisePattern
    public let isInitiator: Bool
    private var symmetric: SymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private var localEphemeral: Curve25519.KeyAgreement.PrivateKey?
    /// The peer's static key: known beforehand (IK, initiator) or learnt during the handshake.
    public private(set) var remoteStaticKey: Data?
    private var remoteEphemeralKey: Data?
    private let preSharedKey: Data?
    private var messageIndex = 0

    /// `remoteStaticKey`: the responder's key, for an IK initiator. `preSharedKey`: the 32-byte code (XXpsk3).
    /// `ephemeral`: for the test vectors only; a fresh key is made otherwise.
    public init(pattern: NoisePattern, initiator: Bool, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
                remoteStaticKey: Data? = nil, preSharedKey: Data? = nil,
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws
    {
        self.pattern = pattern
        isInitiator = initiator
        self.localStatic = localStatic
        self.remoteStaticKey = remoteStaticKey
        self.preSharedKey = preSharedKey
        localEphemeral = ephemeral
        if pattern.usesPreSharedKey, preSharedKey?.count != 32 { throw NoiseError.missingKey }
        symmetric = SymmetricState(protocolName: pattern.protocolName)
        symmetric.mixHash(prologue)
        if pattern.responderStaticIsPreMessage {
            if initiator {
                guard let remoteStaticKey, remoteStaticKey.count == 32 else { throw NoiseError.missingKey }
                symmetric.mixHash(remoteStaticKey)
            } else {
                symmetric.mixHash(localStatic.publicKey.rawRepresentation)
            }
        }
    }

    public var isComplete: Bool { messageIndex == pattern.messages.count }

    /// Whether the next message is ours to write.
    public var isOurTurn: Bool { !isComplete && (messageIndex % 2 == 0) == isInitiator }

    /// The handshake hash: identical on both sides once complete (channel binding).
    public var handshakeHash: Data { symmetric.hash }

    public mutating func writeMessage(payload: Data = Data()) throws -> Data {
        guard isOurTurn else { throw NoiseError.outOfTurn }
        var message = Data()
        for token in pattern.messages[messageIndex] {
            switch token {
            case .e:
                let ephemeral = localEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
                localEphemeral = ephemeral
                let key = ephemeral.publicKey.rawRepresentation
                message += key
                symmetric.mixHash(key)
                if pattern.usesPreSharedKey { symmetric.mixKey(key) }
            case .s:
                message += try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)
            case .ee, .es, .se, .ss:
                symmetric.mixKey(try diffieHellman(token))
            case .psk:
                guard let preSharedKey else { throw NoiseError.missingKey }
                symmetric.mixKeyAndHash(preSharedKey)
            }
        }
        message += try symmetric.encryptAndHash(payload)
        messageIndex += 1
        return message
    }

    /// Reads the peer's message and returns its payload.
    public mutating func readMessage(_ message: Data) throws -> Data {
        guard !isComplete, !isOurTurn else { throw NoiseError.outOfTurn }
        var rest = message[...]
        func take(_ count: Int) throws -> Data {
            guard rest.count >= count else { throw NoiseError.malformedMessage }
            defer { rest = rest.dropFirst(count) }
            return Data(rest.prefix(count))
        }
        for token in pattern.messages[messageIndex] {
            switch token {
            case .e:
                let key = try take(32)
                remoteEphemeralKey = key
                symmetric.mixHash(key)
                if pattern.usesPreSharedKey { symmetric.mixKey(key) }
            case .s:
                let encrypted = try take(symmetric.hasKey ? 48 : 32)
                remoteStaticKey = try symmetric.decryptAndHash(encrypted)
            case .ee, .es, .se, .ss:
                symmetric.mixKey(try diffieHellman(token))
            case .psk:
                guard let preSharedKey else { throw NoiseError.missingKey }
                symmetric.mixKeyAndHash(preSharedKey)
            }
        }
        let payload = try symmetric.decryptAndHash(Data(rest))
        messageIndex += 1
        return payload
    }

    /// The session's ciphers once the handshake is complete: `send` for our messages, `receive` for the peer's.
    public func split() throws -> (send: NoiseCipher, receive: NoiseCipher) {
        guard isComplete else { throw NoiseError.handshakeIncomplete }
        let (initiatorToResponder, responderToInitiator) = symmetric.split()
        return isInitiator ? (initiatorToResponder, responderToInitiator)
            : (responderToInitiator, initiatorToResponder)
    }

    /// The token's Diffie-Hellman, seen from our side: `es` is the initiator's ephemeral with the responder's
    /// static, whoever computes it.
    private func diffieHellman(_ token: NoisePattern.Token) throws -> Data {
        let (localIsEphemeral, remoteIsEphemeral): (Bool, Bool) = switch token {
        case .ee: (true, true)
        case .ss: (false, false)
        case .es: isInitiator ? (true, false) : (false, true)
        case .se: isInitiator ? (false, true) : (true, false)
        default: preconditionFailure("not a Diffie-Hellman token")
        }
        guard let local = localIsEphemeral ? localEphemeral : localStatic,
              let remote = remoteIsEphemeral ? remoteEphemeralKey : remoteStaticKey
        else { throw NoiseError.missingKey }
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote),
              let shared = try? local.sharedSecretFromKeyAgreement(with: publicKey)
        else { throw NoiseError.malformedMessage }
        return shared.withUnsafeBytes { Data($0) }
    }
}
