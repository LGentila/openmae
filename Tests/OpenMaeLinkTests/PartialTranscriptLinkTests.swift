import CryptoKit
import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// The user's words while they speak (`AssistantEvent.partialTranscript`) go to the iPhones and iPads that say they
/// understand them: an app from before them closed the session on an event it did not know.
@Suite("The user's words over the link", .serialized)
struct PartialTranscriptLinkTests {
    @Test func theyAreRelayedToDevicesThatListThem() {
        let words = AssistantEvent.partialTranscript("Quelle heure")
        #expect(RemoteCommandPolicy.isRelayed(words))
        #expect(RemoteCommandPolicy.neededFeature(words) == LinkMessage.partialTranscriptFeature)
        #expect(RemoteCommandPolicy.neededFeature(.userTranscript("Quelle heure est-il ?", .french)) == nil)
        #expect(RemoteCommandPolicy.neededFeature(.state(.userSpeaking)) == nil)
    }

    /// This version's app lists them when it opens a session; one from before sent `{"v":1}`.
    @Test func theAppSaysItUnderstandsThem() throws {
        let old = try JSONDecoder().decode(HandshakePayload.Session.self, from: Data(#"{"v":1}"#.utf8))
        #expect(old.features == nil)
        #expect(!old.understands(LinkMessage.partialTranscriptFeature))
        let sent = try JSONDecoder().decode(HandshakePayload.Session.self,
                                            from: HandshakePayload.encode(HandshakePayload.Session.current))
        #expect(sent.v == 1)
        #expect(sent.understands(LinkMessage.partialTranscriptFeature))
    }

    /// The Mac sends them to the iPhone that understands them, not to the one from before; both get everything else.
    @Test func onlyDevicesThatUnderstandThemGetThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "partial-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = EventSource()
        let host = LinkHost(engine: engine, audio: nil, identityStore: NoIdentity(),
                            storeURL: folder.appending(path: "link.json"), macName: "Mac de test")
        let macKey = Data(repeating: 7, count: 32)
        // This version's iPhone, and one from before.
        let phones: [(key: Data, hello: HandshakePayload.Session?)] = [(Data(repeating: 21, count: 32), .current),
                                                                       (Data(repeating: 22, count: 32), nil)]
        let received = [Received(), Received()]
        for (phone, log) in zip(phones, received) {
            let wire = MemoryWire(path: .direct)
            let (mac, phoneEnd) = wire.sessions(phoneKey: phone.key, macKey: macKey, hello: phone.hello)
            Task { for await message in phoneEnd.messages { if case .event(let event) = message { log.add(event) } } }
            await host.open(mac, device: PairedDevice(publicKey: phone.key, name: "iPhone", model: "iPhone17,3"))
        }
        engine.emit(.state(.userSpeaking))
        engine.emit(.partialTranscript("Quelle heure"))
        engine.emit(.partialTranscript("Quelle heure est-il"))
        engine.emit(.userTranscript("Quelle heure est-il ?", .french))
        engine.emit(.state(.thinking))
        await waitFor { received.allSatisfy { $0.events.last == "state thinking" } }
        #expect(received[0].events == ["state listening", "state userSpeaking", "words Quelle heure",
                                       "words Quelle heure est-il", "sentence Quelle heure est-il ?", "state thinking"])
        #expect(received[1].events == ["state listening", "state userSpeaking", "sentence Quelle heure est-il ?",
                                       "state thinking"])
    }

    /// An event of a kind this version does not know (sent by a newer Mac) is skipped, and the session goes on.
    @Test func anEventOfAnUnknownKindIsIgnored() async throws {
        let toPhone = SymmetricKey(size: .bits256)
        let wire = MemoryWire(path: .direct)
        let phone = LinkSession(transport: wire.phone, inbox: FrameInbox(wire.phone),
                                keys: SessionKeys((send: NoiseCipher(key: SymmetricKey(size: .bits256)),
                                                   receive: NoiseCipher(key: toPhone))),
                                peerKey: Data(repeating: 7, count: 32), peerMac: HandshakePayload.Mac(name: "Mac de test"))
        var mac = NoiseCipher(key: toPhone)
        wire.mac.send(Frame.encode(try mac.encrypt(Data(#"{"type":"event","event":{"futureEvent":{"_0":"x"}}}"#.utf8))))
        wire.mac.send(Frame.encode(try mac.encrypt(LinkMessage.event(.state(.thinking)).encoded)))
        var received: LinkMessage?
        for await message in phone.messages {
            received = message
            break
        }
        guard case .event(.state(.thinking))? = received else {
            Issue.record("the event after the unknown one was not received")
            return
        }
        #expect(phone.isOpen)
        phone.close()
    }
}

/// The engine, as far as the link sees it: events, sent when the test says.
private final class EventSource: AssistantConnection, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    private let sink: AsyncStream<AssistantEvent>.Continuation

    init() { (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded) }

    func emit(_ event: AssistantEvent) { sink.yield(event) }
    func send(_ command: AssistantCommand) {}
}

/// What one iPhone received, written short.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    var events: [String] { lock.withLock { list } }

    func add(_ event: AssistantEvent) {
        let short: String? = switch event {
        case .state(let state): "state \(state.rawValue)"
        case .partialTranscript(let text): "words \(text)"
        case .userTranscript(let text, _): "sentence \(text)"
        default: nil
        }
        if let short { lock.withLock { list.append(short) } }
    }
}
