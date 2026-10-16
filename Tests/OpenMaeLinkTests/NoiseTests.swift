import CryptoKit
import Foundation
import Testing

@testable import OpenMaeLink

/// The official test vectors of the Noise Protocol Framework for the two patterns OpenMaé uses, from the cacophony
/// and snow implementations (Tests/Fixtures/noise-vectors.json, taken from their `vectors` files).
@Suite("Noise")
struct NoiseTests {
    struct Vector: Decodable {
        struct Message: Decodable {
            let payload: String
            let ciphertext: String
        }

        let source: String
        let protocol_name: String
        let init_prologue: String
        let resp_prologue: String
        let init_static: String?
        let init_ephemeral: String
        let init_remote_static: String?
        let init_psks: [String]?
        let resp_static: String?
        let resp_ephemeral: String?
        let resp_psks: [String]?
        let handshake_hash: String?
        let messages: [Message]
    }

    static let vectors: [Vector] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/noise-vectors.json")
        struct File: Decodable { let vectors: [Vector] }
        return (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).vectors) ?? []
    }()

    @Test func vectorsAreThere() {
        #expect(Self.vectors.count == 3)
    }

    @Test(arguments: vectors.indices)
    func officialVector(_ index: Int) throws {
        let vector = Self.vectors[index]
        let pattern: NoisePattern = vector.protocol_name.contains("XXpsk3") ? .XXpsk3 : .IK
        #expect(pattern.protocolName == vector.protocol_name)
        func key(_ hex: String?) throws -> Curve25519.KeyAgreement.PrivateKey {
            try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: try #require(hex)))
        }
        var initiator = try NoiseHandshake(
            pattern: pattern, initiator: true, prologue: Data(hex: vector.init_prologue),
            localStatic: try key(vector.init_static), remoteStaticKey: vector.init_remote_static.map { Data(hex: $0) },
            preSharedKey: vector.init_psks?.first.map { Data(hex: $0) }, ephemeral: try key(vector.init_ephemeral))
        var responder = try NoiseHandshake(
            pattern: pattern, initiator: false, prologue: Data(hex: vector.resp_prologue),
            localStatic: try key(vector.resp_static), preSharedKey: vector.resp_psks?.first.map { Data(hex: $0) },
            ephemeral: try key(vector.resp_ephemeral))

        var ciphers: (initiator: (send: NoiseCipher, receive: NoiseCipher),
                      responder: (send: NoiseCipher, receive: NoiseCipher))?
        for (i, message) in vector.messages.enumerated() {
            let payload = Data(hex: message.payload)
            let expected = Data(hex: message.ciphertext)
            let fromInitiator = i % 2 == 0
            if ciphers == nil {
                let written = fromInitiator ? try initiator.writeMessage(payload: payload)
                    : try responder.writeMessage(payload: payload)
                #expect(written == expected, "\(vector.source) message \(i)")
                let read = fromInitiator ? try responder.readMessage(written) : try initiator.readMessage(written)
                #expect(read == payload)
                if initiator.isComplete, responder.isComplete {
                    #expect(initiator.handshakeHash == responder.handshakeHash)
                    if let hash = vector.handshake_hash { #expect(initiator.handshakeHash == Data(hex: hash)) }
                    #expect(initiator.remoteStaticKey == (try key(vector.resp_static)).publicKey.rawRepresentation)
                    #expect(responder.remoteStaticKey == (try key(vector.init_static)).publicKey.rawRepresentation)
                    ciphers = (try initiator.split(), try responder.split())
                }
            } else if var pair = ciphers {
                let written = fromInitiator ? try pair.initiator.send.encrypt(payload)
                    : try pair.responder.send.encrypt(payload)
                #expect(written == expected, "\(vector.source) transport message \(i)")
                let read = fromInitiator ? try pair.responder.receive.decrypt(written)
                    : try pair.initiator.receive.decrypt(written)
                #expect(read == payload)
                ciphers = pair
            }
        }
        #expect(ciphers != nil)
    }

    @Test func wrongPreSharedKeyFailsAtTheThirdMessage() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseHandshake(pattern: .XXpsk3, initiator: true, prologue: Data(), localStatic: phone,
                                           preSharedKey: Data(repeating: 1, count: 32))
        var responder = try NoiseHandshake(pattern: .XXpsk3, initiator: false, prologue: Data(), localStatic: mac,
                                           preSharedKey: Data(repeating: 2, count: 32))
        _ = try responder.readMessage(try initiator.writeMessage())
        _ = try initiator.readMessage(try responder.writeMessage())
        let third = try initiator.writeMessage(payload: Data("hello".utf8))
        #expect(throws: NoiseError.decryptionFailed) { try responder.readMessage(third) }
    }

    @Test func unknownStaticKeyCannotImpersonateTheMac() throws {
        // The iPhone believes it talks to `mac`; an impostor with another key cannot answer the first message.
        let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        var initiator = try NoiseHandshake(pattern: .IK, initiator: true, prologue: Data("openmae/1".utf8),
                                           localStatic: phone, remoteStaticKey: mac.publicKey.rawRepresentation)
        var responder = try NoiseHandshake(pattern: .IK, initiator: false, prologue: Data("openmae/1".utf8),
                                           localStatic: impostor)
        #expect(throws: NoiseError.decryptionFailed) { try responder.readMessage(try initiator.writeMessage()) }
    }

    @Test func messagesOutOfTurnAreRefused() throws {
        var responder = try NoiseHandshake(pattern: .IK, initiator: false, prologue: Data(),
                                           localStatic: Curve25519.KeyAgreement.PrivateKey())
        #expect(throws: NoiseError.outOfTurn) { try responder.writeMessage() }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
