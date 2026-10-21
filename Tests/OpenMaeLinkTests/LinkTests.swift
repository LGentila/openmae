import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

@Suite("Identities and pairing link")
struct IdentityTests {
    @Test func base32() {
        // RFC 4648 test vectors, lowercase and unpadded.
        #expect(Base32.encode(Data("".utf8)) == "")
        #expect(Base32.encode(Data("f".utf8)) == "my")
        #expect(Base32.encode(Data("fo".utf8)) == "mzxq")
        #expect(Base32.encode(Data("foo".utf8)) == "mzxw6")
        #expect(Base32.encode(Data("foob".utf8)) == "mzxw6yq")
        #expect(Base32.encode(Data("fooba".utf8)) == "mzxw6ytb")
        #expect(Base32.encode(Data("foobar".utf8)) == "mzxw6ytboi")
    }

    @Test func deviceIDIsTwentySixCharacters() {
        let identity = DeviceIdentity.generate()
        #expect(identity.id.count == 26)
        #expect(identity.id == DeviceID.make(signingKey: identity.signingKey.publicKey.rawRepresentation))
        #expect(DeviceIdentity(serialized: identity.serialized)?.id == identity.id)
    }

    @Test func pairingLinkRoundTrip() throws {
        let link = PairingLink(macID: DeviceIdentity.generate().id, macKey: Data(repeating: 7, count: 32),
                               relay: URL(string: "https://relay.openmae.com")!, code: Data(repeating: 9, count: 32),
                               macName: "MacBook Pro de Camille & co")
        let url = link.url
        #expect(url.absoluteString.hasPrefix("https://openmae.com/p#v=1&id="))
        #expect(url.query == nil)  // nothing before the #: the server never sees the keys
        #expect(PairingLink(url: url) == link)
        var noRelay = link
        noRelay.relay = nil
        #expect(PairingLink(url: noRelay.url) == noRelay)
    }

    @Test func foreignLinksAreRefused() {
        #expect(PairingLink(string: "https://example.com/p#v=1") == nil)
        #expect(PairingLink(string: "https://openmae.com/p#v=2&id=x") == nil)
        #expect(PairingLink(string: "not a link") == nil)
    }

    @Test func pairingCodeExpiresAndServesOnce() {
        let start = Date()
        var code = PairingCode(now: start)
        #expect(code.code.count == 32)
        #expect(code.isValid(at: start.addingTimeInterval(299)))
        #expect(!code.isValid(at: start.addingTimeInterval(301)))
        code.use()
        #expect(!code.isValid(at: start))
    }
}

@Suite("Frames and datagrams")
struct FramingTests {
    @Test func framesSurviveAnyChunking() throws {
        let frames = [Data("one".utf8), Data(), Data(repeating: 0xAB, count: 70_000 / 2)]
        let stream = frames.reduce(Data()) { $0 + Frame.encode($1) }
        for chunk in [1, 3, 7, 1000, stream.count] {
            var reader = FrameReader()
            var out: [Data] = []
            var offset = 0
            while offset < stream.count {
                reader.append(stream[offset..<min(offset + chunk, stream.count)])
                offset += chunk
                while let frame = try reader.next() { out.append(frame) }
            }
            #expect(out == frames)
        }
    }

    @Test func oversizedFrameIsRefused() {
        var reader = FrameReader(maxSize: 10)
        reader.append(Data([0, 0, 0, 11]))
        #expect(throws: FramingError.self) { try reader.next() }
    }

    @Test func replayWindow() {
        var window = ReplayWindow()
        // Counter, and whether it is new.
        let script: [(UInt64, Bool)] = [
            (5, true), (5, false),  // replayed
            (3, true), (3, false),  // late but new, then replayed
            (100, true), (36, false),  // older than the 64 most recent
            (37, true), (37, false), (99, true), (1_000, true), (100, false),
        ]
        for (counter, isNew) in script {
            let accepted = window.accept(counter)
            #expect(accepted == isNew, "counter \(counter)")
        }
    }

    @Test func datagramsAreSealedAndReplaysDropped() throws {
        let cipher = NoiseCipher(key: SymmetricKey(size: .bits256))
        var sender = DatagramCipher(deriveFrom: cipher)
        var receiver = DatagramCipher(deriveFrom: cipher)
        let first = try sender.seal(Data("hello".utf8))
        let second = try sender.seal(Data("world".utf8))
        var tampered = second
        tampered[tampered.count - 1] ^= 1
        let opened = [receiver.open(second), receiver.open(first), receiver.open(first), receiver.open(tampered)]
        // In order: accepted, reordered but accepted, replayed, tampered with.
        #expect(opened == [Data("world".utf8), Data("hello".utf8), nil, nil])
        // A datagram key is not the reliable channel's key.
        var reliable = cipher
        let reliableCiphertext = try reliable.encrypt(Data("hello".utf8))
        #expect(reliableCiphertext != first.dropFirst(9))
    }

    @Test func audioPacket() {
        let packet = AudioPacket(stream: 3, sequence: 70_000, payload: Data([1, 2, 3]))
        #expect(AudioPacket(packet.encoded) == packet)
        #expect(AudioPacket(Data([1, 2])) == nil)
    }
}

@Suite("Messages")
struct MessageTests {
    @Test func roundTrip() throws {
        let messages: [LinkMessage] = [
            .command(.talkKey(pressed: true)), .command(.stopSpeaking), .event(.state(.speaking)),
            .event(.assistantPiece("Bonjour !")), .audio(.start), .audio(.stop), .audio(.released),
            .audio(.end(stream: 4, frames: 120)), .audio(.stopPlayback(stream: 4)), .audio(.finished(stream: 4)),
            .ping, .pong, .paired, .removed,
            .mac(HandshakePayload.Mac(name: "Mac de Camille", relay: URL(string: "https://relay.example.com"))),
            .mac(HandshakePayload.Mac(name: "Mac de Camille")), .device(station: true), .device(station: false),
        ]
        for message in messages {
            let decoded = try LinkMessage(decoding: message.encoded)
            #expect(String(describing: decoded) == String(describing: message))
        }
        let json = String(decoding: LinkMessage.audio(.end(stream: 4, frames: 120)).encoded, as: UTF8.self)
        #expect(json.contains("\"type\":\"audio\"") && json.contains("\"op\":\"end\""))
        // No relay: the key is left out, as in the handshake.
        let noRelay = String(decoding: LinkMessage.mac(HandshakePayload.Mac(name: "Mac")).encoded, as: UTF8.self)
        #expect(!noRelay.contains("relay"))
    }

    @Test func onlyTheIPhoneCommandsAreAccepted() {
        #expect(RemoteCommandPolicy.isAllowed(.stopSpeaking))
        #expect(RemoteCommandPolicy.isAllowed(.newConversation))
        #expect(RemoteCommandPolicy.isAllowed(.talkKey(pressed: false)))
        #expect(RemoteCommandPolicy.isAllowed(.updateSettings(AssistantSettings())))
        #expect(!RemoteCommandPolicy.isAllowed(.start(AssistantSettings())))
        #expect(!RemoteCommandPolicy.isAllowed(.downloadModels))
        #expect(!RemoteCommandPolicy.isAllowed(.deleteModels))
        #expect(!RemoteCommandPolicy.isAllowed(.deleteUnusedModels))
        #expect(!RemoteCommandPolicy.isAllowed(.shutdown))
        #expect(!RemoteCommandPolicy.isAllowed(.typedTurn("hello")))
    }

    @Test func relayedEvents() {
        #expect(RemoteCommandPolicy.relayed(.levels(input: 1, output: 0)) == nil)
        #expect(RemoteCommandPolicy.relayed(.diagnostics(EngineDiagnostics())) == nil)
        // The Mac's own: an iPhone app from before it would not understand it.
        #expect(RemoteCommandPolicy.relayed(.conversationCleared) == nil)
        var metrics = TurnMetrics()
        metrics.userText = "Salut"
        metrics.latencyMs = 1234
        guard case .turnFinished(let relayed)? = RemoteCommandPolicy.relayed(.turnFinished(metrics)) else {
            Issue.record("turnFinished not relayed")
            return
        }
        #expect(relayed.userText == "Salut")
        #expect(relayed.latencyMs == nil)  // without the measurements
    }
}

@Suite("Jitter buffer")
struct JitterBufferTests {
    func packet(_ sequence: UInt32, stream: UInt32 = 1) -> AudioPacket {
        AudioPacket(stream: stream, sequence: sequence, payload: Data([UInt8(sequence & 0xFF)]))
    }

    @Test func waitsForTheTargetThenPlaysInOrder() {
        var buffer = VoiceJitterBuffer()
        let outputs = [buffer.insert(packet(0), scheduled: 0, now: 0), buffer.insert(packet(1), scheduled: 0, now: 0.02),
                       buffer.insert(packet(2), scheduled: 0, now: 0.04), buffer.insert(packet(3), scheduled: 2, now: 0.06)]
        let expected: [[VoiceJitterBuffer.Output]] = [[], [], [.packet(Data([0])), .packet(Data([1])), .packet(Data([2]))],
                                                      [.packet(Data([3]))]]
        #expect(outputs == expected)
    }

    @Test func lostFrameIsConcealedOnceLaterOnesArrive() {
        var buffer = VoiceJitterBuffer()
        for i in 0..<3 { _ = buffer.insert(packet(UInt32(i)), scheduled: 0, now: 0) }
        // 3 is lost: after 4 it may only be late; after 5 it is lost; when it comes at last, its turn is gone.
        let outputs = [buffer.insert(packet(4), scheduled: 3, now: 0.1), buffer.insert(packet(5), scheduled: 3, now: 0.12),
                       buffer.insert(packet(3), scheduled: 3, now: 0.14)]
        let expected: [[VoiceJitterBuffer.Output]] = [[], [.conceal, .packet(Data([4])), .packet(Data([5]))], []]
        #expect(outputs == expected)
        #expect(buffer.concealed == 1)
    }

    @Test func runningDryRaisesTheTarget() {
        var buffer = VoiceJitterBuffer()
        for i in 0..<3 { _ = buffer.insert(packet(UInt32(i)), scheduled: 0, now: 0) }
        #expect(buffer.target == 3)
        let dry = buffer.playerNeedsMore(scheduled: 0, now: 1)
        #expect(dry.isEmpty)
        #expect(buffer.target == 4)
        #expect(buffer.underruns == 1)
        // Now four frames are gathered before playing again.
        let gathering = (3..<6).map { buffer.insert(packet(UInt32($0)), scheduled: 0, now: 1) }
        #expect(gathering.flatMap { $0 }.isEmpty)
        let released = buffer.insert(packet(6), scheduled: 0, now: 1)
        #expect(released.count == 4)
        // Ten calm seconds later, the target comes down again.
        _ = buffer.insert(packet(7), scheduled: 3, now: 12)
        #expect(buffer.target == 3)
    }

    @Test func endOfAShortStreamPlaysWithoutWaiting() {
        var buffer = VoiceJitterBuffer()
        let outputs = [buffer.insert(packet(0), scheduled: 0, now: 0), buffer.end(stream: 1, frames: 1, scheduled: 0, now: 0)]
        let expected: [[VoiceJitterBuffer.Output]] = [[], [.packet(Data([0]))]]
        #expect(outputs == expected)
        #expect(buffer.isComplete)
    }

    @Test func missingLastFramesAreConcealedWhenThePlayerRunsDry() {
        var buffer = VoiceJitterBuffer()
        for i in 0..<3 { _ = buffer.insert(packet(UInt32(i)), scheduled: 0, now: 0) }
        let outputs = [buffer.end(stream: 1, frames: 5, scheduled: 3, now: 0.1),
                       buffer.playerNeedsMore(scheduled: 1, now: 0.14)]
        let expected: [[VoiceJitterBuffer.Output]] = [[], [.conceal, .conceal]]
        #expect(outputs == expected)
        #expect(buffer.isComplete)
    }

    @Test func stoppedStreamDropsEverything() {
        var buffer = VoiceJitterBuffer()
        for i in 0..<3 { _ = buffer.insert(packet(UInt32(i)), scheduled: 0, now: 0) }
        buffer.stop(stream: 1)
        #expect(buffer.isComplete)
        let late = buffer.insert(packet(3), scheduled: 0, now: 0.1)
        #expect(late.isEmpty)
        // The next stream starts fresh.
        _ = buffer.insert(packet(0, stream: 2), scheduled: 0, now: 0.2)
        _ = buffer.insert(packet(1, stream: 2), scheduled: 0, now: 0.2)
        let next = buffer.insert(packet(2, stream: 2), scheduled: 0, now: 0.2)
        #expect(next.count == 3)
    }

    @Test func simulatedLossAndJitterPlaysEveryFrameOnce() {
        // 500 frames, 5 % lost, delivered with up to 3 frames of reordering: every frame is either played or
        // concealed, once, in order.
        var buffer = VoiceJitterBuffer()
        var generator = SplitMix(seed: 42)
        var arrivals: [(Double, UInt32)] = []
        for i in 0..<500 where generator.next() % 100 >= 5 {
            arrivals.append((Double(i) * 0.02 + Double(generator.next() % 60) / 1000, UInt32(i)))
        }
        arrivals.sort { $0.0 < $1.0 }
        var played: [VoiceJitterBuffer.Output] = []
        var scheduled = 0
        for (time, sequence) in arrivals {
            let out = buffer.insert(packet(sequence), scheduled: scheduled, now: time)
            played += out
            scheduled = min(scheduled + out.count, 6)
        }
        played += buffer.end(stream: 1, frames: 500, scheduled: scheduled, now: 11)
        played += buffer.playerNeedsMore(scheduled: 0, now: 11.1)
        #expect(played.count == 500)
        #expect(buffer.isComplete)
        // In order: each played frame is the one of its position (the payload is the sequence number's low byte).
        for (position, output) in played.enumerated() {
            if case .packet(let data) = output { #expect(data.first == UInt8(position & 0xFF)) }
        }
        let concealed = played.filter { $0 == .conceal }.count
        #expect(concealed == buffer.concealed)
        #expect(concealed >= 500 - arrivals.count)  // every lost frame, and the few that came too late
    }

    @Test func microphoneReorder() {
        var reorder = MicrophoneReorder()
        let outputs = [0, 2, 1, 4, 5, 3].map { reorder.insert(packet(UInt32($0))) } + [reorder.insert(packet(0, stream: 2))]
        let expected: [[MicrophoneReorder.Output]] = [
            [.newStream, .packet(Data([0]))],
            [],  // 1 may still come
            [.packet(Data([1])), .packet(Data([2]))],
            [],
            [.conceal, .packet(Data([4])), .packet(Data([5]))],  // 3 lost
            [],  // 3 too late
            [.newStream, .packet(Data([0]))],
        ]
        #expect(outputs == expected)
    }
}

/// A small deterministic random generator for the simulations.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Opus")
struct OpusTests {
    @Test(arguments: [(LinkAudio.microphoneRate, LinkAudio.microphoneBitRate), (LinkAudio.voiceRate, LinkAudio.voiceBitRate)])
    func roundTrip(_ settings: (rate: Double, bitRate: Int)) throws {
        let encoder = try OpusEncoder(sampleRate: settings.rate, bitRate: settings.bitRate)
        let decoder = try OpusDecoder(sampleRate: settings.rate)
        let second = (0..<Int(settings.rate)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / settings.rate)) }
        let packets = encoder.encode(second) + encoder.flush()
        #expect(packets.count == 50)
        let bytes = packets.reduce(0) { $0 + $1.count }
        #expect(Double(bytes * 8) < Double(settings.bitRate) * 1.3)  // about the bit rate asked for
        var decoded: [Float] = []
        for (i, packet) in packets.enumerated() { decoded += decoder.decode(i == 25 ? nil : packet) }
        #expect(abs(decoded.count - Int(settings.rate)) <= encoder.frameSamples)
        // The concealed frame is not silence.
        let frame = encoder.frameSamples
        let concealed = decoded[(25 * frame)..<(26 * frame)]
        #expect(concealed.map { $0 * $0 }.reduce(0, +) / Float(frame) > 0.001)
    }
}
