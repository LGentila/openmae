import CryptoKit
import Foundation
import VoiceCore

/// The keys of an open session: the reliable channel's two ciphers and the datagrams' two.
public struct SessionKeys: Sendable {
    var send: NoiseCipher
    var receive: NoiseCipher
    var sendDatagrams: DatagramCipher
    var receiveDatagrams: DatagramCipher

    init(_ ciphers: (send: NoiseCipher, receive: NoiseCipher)) {
        send = ciphers.send
        receive = ciphers.receive
        sendDatagrams = DatagramCipher(deriveFrom: ciphers.send)
        receiveDatagrams = DatagramCipher(deriveFrom: ciphers.receive)
    }

    mutating func seal(_ message: LinkMessage) throws -> Data {
        try send.encrypt(message.encoded)
    }

    mutating func open(_ frame: Data) throws -> LinkMessage {
        try LinkMessage(decoding: try receive.decrypt(frame))
    }
}

/// Why a handshake did not end with an open session.
public enum HandshakeFailure: Error, Equatable, Sendable {
    /// The Mac refused, before keys were agreed (relay/PROTOCOL.md): `expired`, `unknown_device`, `busy`.
    case refused(String)
    /// The Mac's key is not the one of the pairing link: someone else answered.
    case wrongMac
    /// The connection closed, or timed out, during the handshake.
    case closed
    case protocolError(String)
}

/// The first byte of the iPhone's first frame.
enum HandshakeKind: UInt8 {
    case pairing = 0x50  // "P"
    case session = 0x53  // "S"
    /// A refusal from the Mac, in clear, followed by an ASCII code.
    static let refusal: UInt8 = 0x45  // "E"
}

enum Prologue {
    static let session = Data("openmae/1".utf8)
    static let pairing = Data("openmae/1 pairing".utf8)
}

/// Reads frames off a transport, with a deadline for the whole handshake.
final class FrameInbox: @unchecked Sendable {
    // Only used by the one task that drives the handshake, then the session.
    private var iterator: AsyncStream<TransportInput>.Iterator
    private var reader = FrameReader()
    private var pending: [TransportInput] = []

    init(_ transport: any LinkTransport) {
        iterator = transport.incoming.makeAsyncIterator()
    }

    /// The next frame, datagram or end of the connection.
    func next() async -> ChannelInput {
        while true {
            do {
                if let frame = try reader.next() { return .frame(frame) }
            } catch {
                return .closed("frame too large")
            }
            guard let input = await iterator.next() else { return .closed(nil) }
            switch input {
            case .bytes(let bytes): reader.append(bytes)
            case .datagram(let datagram): return .datagram(datagram)
            case .closed(let reason): return .closed(reason)
            }
        }
    }

    /// The next frame; datagrams that arrive before the handshake is over are dropped.
    func nextFrame() async throws -> Data {
        while true {
            switch await next() {
            case .frame(let frame): return frame
            case .datagram: continue
            case .closed: throw HandshakeFailure.closed
            }
        }
    }
}

public enum ChannelInput: Sendable {
    case frame(Data)
    case datagram(Data)
    case closed(String?)
}

// MARK: - iPhone side

/// The iPhone's side of the two handshakes. The iPhone always starts.
public enum PhoneHandshake {
    /// Pairs with the Mac of the link; returns the Mac's name. The Mac closes the connection afterwards.
    static func pair(over transport: any LinkTransport, inbox: FrameInbox, link: PairingLink, identity: DeviceIdentity,
                     phone: HandshakePayload.Phone) async throws -> String
    {
        var noise = try NoiseHandshake(pattern: .XXpsk3, initiator: true, prologue: Prologue.pairing,
                                       localStatic: identity.agreementKey, preSharedKey: link.code)
        transport.send(Frame.encode(Data([HandshakeKind.pairing.rawValue]) + (try noise.writeMessage())))
        let second = try await answer(inbox)
        let mac = HandshakePayload.decode(HandshakePayload.Mac.self, try noise.readMessage(second))
        // The pre-shared code already rules out a stranger in the middle; the key of the link is checked as well.
        guard noise.remoteStaticKey == link.macKey else { throw HandshakeFailure.wrongMac }
        transport.send(Frame.encode(try noise.writeMessage(payload: HandshakePayload.encode(phone))))
        var keys = SessionKeys(try noise.split())
        // The Mac's verdict: "paired", or a refusal if the code was wrong or expired (the third message then could
        // not be read).
        let verdict = try await answer(inbox)
        guard case .paired = try keys.open(verdict) else { throw HandshakeFailure.protocolError("no pairing verdict") }
        return mac?.name ?? link.macName
    }

    /// Opens a session with a paired Mac; returns its keys and what the Mac said about itself (its name and relay).
    static func openSession(over transport: any LinkTransport, inbox: FrameInbox, macKey: Data,
                            identity: DeviceIdentity) async throws -> (keys: SessionKeys, mac: HandshakePayload.Mac?)
    {
        var noise = try NoiseHandshake(pattern: .IK, initiator: true, prologue: Prologue.session,
                                       localStatic: identity.agreementKey, remoteStaticKey: macKey)
        let hello = HandshakePayload.encode(HandshakePayload.Session())
        transport.send(Frame.encode(Data([HandshakeKind.session.rawValue]) + (try noise.writeMessage(payload: hello))))
        let second = try await answer(inbox)
        let mac = HandshakePayload.decode(HandshakePayload.Mac.self, try noise.readMessage(second))
        return (SessionKeys(try noise.split()), mac)
    }

    /// The Mac's next frame: a handshake message, or a refusal.
    private static func answer(_ inbox: FrameInbox) async throws -> Data {
        let frame = try await inbox.nextFrame()
        if frame.first == HandshakeKind.refusal {
            throw HandshakeFailure.refused(String(decoding: frame.dropFirst(), as: UTF8.self))
        }
        return frame
    }
}

// MARK: - Mac side

/// What the Mac's side of a handshake ended with.
public enum HostHandshakeOutcome: Sendable {
    /// A new iPhone, paired: its key and what it said about itself. The connection is to be closed.
    case paired(publicKey: Data, phone: HandshakePayload.Phone)
    /// A paired iPhone opened a session.
    case session(SessionKeys, publicKey: Data)
}

public enum HostHandshake {
    /// Answers the iPhone's handshake. `mac` is what the Mac says about itself; `pairingCode` is the code shown on the
    /// Mac, if any; `completePairing` adds the new iPhone, and says false if the code was used or expired meanwhile;
    /// `isPaired` tells whether an iPhone key belongs to the paired list.
    static func respond(over transport: any LinkTransport, inbox: FrameInbox, identity: DeviceIdentity,
                        mac: HandshakePayload.Mac, pairingCode: @Sendable () async -> Data?,
                        completePairing: @Sendable (Data, HandshakePayload.Phone) async -> Bool,
                        isPaired: @Sendable (Data) async -> Bool) async throws -> HostHandshakeOutcome
    {
        let first = try await inbox.nextFrame()
        guard let kindByte = first.first, let kind = HandshakeKind(rawValue: kindByte) else {
            throw HandshakeFailure.protocolError("unknown handshake")
        }
        let macPayload = HandshakePayload.encode(mac)
        switch kind {
        case .pairing:
            guard let code = await pairingCode() else { try refuse(transport, "expired") }
            var noise = try NoiseHandshake(pattern: .XXpsk3, initiator: false, prologue: Prologue.pairing,
                                           localStatic: identity.agreementKey, preSharedKey: code)
            _ = try noise.readMessage(first.dropFirst())
            transport.send(Frame.encode(try noise.writeMessage(payload: macPayload)))
            let third = try await inbox.nextFrame()
            let payload: Data
            do {
                payload = try noise.readMessage(third)
            } catch {
                try refuse(transport, "expired")  // a wrong code: the message cannot be read
            }
            guard let phoneKey = noise.remoteStaticKey,
                  let phone = HandshakePayload.decode(HandshakePayload.Phone.self, payload)
            else { throw HandshakeFailure.protocolError("pairing payload") }
            // Added before the verdict, so that the iPhone's first session is never refused.
            guard await completePairing(phoneKey, phone) else { try refuse(transport, "expired") }
            var keys = SessionKeys(try noise.split())
            transport.send(Frame.encode(try keys.seal(.paired)))
            return .paired(publicKey: phoneKey, phone: phone)
        case .session:
            var noise = try NoiseHandshake(pattern: .IK, initiator: false, prologue: Prologue.session,
                                           localStatic: identity.agreementKey)
            _ = try noise.readMessage(first.dropFirst())
            guard let phoneKey = noise.remoteStaticKey, await isPaired(phoneKey) else {
                try refuse(transport, "unknown_device")
            }
            transport.send(Frame.encode(try noise.writeMessage(payload: macPayload)))
            return .session(SessionKeys(try noise.split()), publicKey: phoneKey)
        }
    }

    private static func refuse(_ transport: any LinkTransport, _ code: String) throws -> Never {
        transport.send(Frame.encode(Data([HandshakeKind.refusal]) + Data(code.utf8)))
        throw HandshakeFailure.refused(code)
    }
}
