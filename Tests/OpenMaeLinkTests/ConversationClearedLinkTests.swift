import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// A new conversation, asked on an iPhone or on the Mac (`newConversation`): the engine starts it and says so
/// (`AssistantEvent.conversationCleared`), and the screens that show the conversation clear their transcript, whose
/// exchanges the model no longer has: the Mac's (the LinkHost's own events), and the iPhones and iPads that list the event
/// (`LinkMessage.conversationClearedFeature`). An app from before it is never sent it: the first versions closed the
/// session on an event they did not know.
@Suite("A new conversation over the link", .serialized)
struct ConversationClearedLinkTests {
    static let exchange = ["user Salut", "Maé Bonjour !"]

    @Test func itGoesOnlyToDevicesThatListIt() throws {
        #expect(RemoteCommandPolicy.isRelayed(.conversationCleared))
        #expect(RemoteCommandPolicy.neededFeature(.conversationCleared) == LinkMessage.conversationClearedFeature)
        // This version's app lists it, with the user's words; the version before listed only those.
        let sent = try JSONDecoder().decode(HandshakePayload.Session.self,
                                            from: HandshakePayload.encode(HandshakePayload.Session.current))
        #expect(sent.understands(LinkMessage.conversationClearedFeature))
        #expect(sent.understands(LinkMessage.partialTranscriptFeature))
        let before = try JSONDecoder().decode(HandshakePayload.Session.self,
                                              from: Data(#"{"v":1,"features":["partialTranscript"]}"#.utf8))
        #expect(!before.understands(LinkMessage.conversationClearedFeature))
    }

    /// « New conversation » on an iPhone: the Mac's screen is told after the exchange it showed, and nothing of that
    /// exchange comes after; so is the iPhone that asked (it cleared its own already). Then the Mac's own « New
    /// conversation »: that iPhone clears too. The apps that do not list the event never get it, and get the rest.
    @Test func theScreensThatShowTheConversationAreTold() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "conversation-cleared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try await ConversationEngine()
        let host = LinkHost(engine: engine, audio: nil, identityStore: NoIdentity(),
                            storeURL: folder.appending(path: "link.json"), macName: "Mac de test")
        let mac = Screen()
        Task { for await event in host.events { mac.show(event) } }
        // This version's iPhone, the version before (the user's words only), and one from before any optional event.
        let hellos: [HandshakePayload.Session?] = [.current,
                                                   HandshakePayload.Session(features: [LinkMessage.partialTranscriptFeature]),
                                                   nil]
        var phones: [(session: LinkSession, screen: Screen)] = []
        for (i, hello) in hellos.enumerated() {
            let key = Data(repeating: UInt8(41 + i), count: 32)
            let (macEnd, phoneEnd) = MemoryWire(path: .direct).sessions(phoneKey: key, macKey: Data(repeating: 7, count: 32),
                                                                        hello: hello)
            let screen = Screen()
            Task { for await message in phoneEnd.messages { if case .event(let event) = message { screen.show(event) } } }
            await host.open(macEnd, device: PairedDevice(publicKey: key, name: "iPhone", model: "iPhone17,3"))
            phones.append((phoneEnd, screen))
        }
        let screens = [mac] + phones.map(\.screen)

        host.send(.typedTurn("Salut"))  // as the Mac's debug tools do: a turn typed instead of spoken
        await waitFor { screens.allSatisfy { $0.lines == Self.exchange && $0.state == "listening" } }
        #expect(screens.allSatisfy { $0.lines == Self.exchange })

        // The iPhone's « New conversation »: the app clears its own transcript, then sends the command.
        phones[0].session.send(.command(.newConversation))
        await waitFor { mac.clears == 1 && phones[0].screen.clears == 1 }
        #expect(mac.clears == 1)
        #expect(mac.lines.isEmpty)  // the Mac's history
        #expect(mac.afterLastClear.isEmpty)  // nothing of the exchange came after it
        #expect(phones[0].screen.clears == 1)
        try await Task.sleep(for: .milliseconds(200))
        for phone in phones.dropFirst() {
            #expect(phone.screen.clears == 0)
            #expect(phone.screen.lines == Self.exchange)  // as before this version
        }

        // Another exchange, then the Mac's own « New conversation ».
        host.send(.typedTurn("Salut"))
        await waitFor { screens.allSatisfy { $0.lines.suffix(2) == Self.exchange[...] && $0.state == "listening" } }
        #expect(phones[0].screen.lines == Self.exchange)
        host.send(.newConversation)
        await waitFor { mac.clears == 2 && phones[0].screen.clears == 2 }
        #expect(mac.clears == 2)
        #expect(phones[0].screen.clears == 2)
        #expect(phones[0].screen.lines.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        for phone in phones.dropFirst() {
            #expect(phone.screen.clears == 0)
            #expect(phone.screen.lines == Self.exchange + Self.exchange)
        }
        await engine.stop()
    }
}

/// The engine, as `AssistantHost` is for what these tests look at: the real conversation logic (`VoicePipeline`, on
/// stages without models) behind the commands, handled one at a time and in order, and its events passed on.
private final class ConversationEngine: AssistantConnection, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    private let pipeline: VoicePipeline
    private let commands: AsyncStream<AssistantCommand>.Continuation

    init() async throws {
        pipeline = VoicePipeline(detector: Silence(), transcriber: Deaf(), model: Polite(), synthesizer: ToneVoice(),
                                 output: CountingSpeaker())
        let (events, emit) = AsyncStream<AssistantEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = events
        let (commandStream, commands) = AsyncStream<AssistantCommand>.makeStream(bufferingPolicy: .unbounded)
        self.commands = commands
        try await pipeline.start()
        Task { [pipeline] in
            for await event in pipeline.events {
                switch event {
                case .state(let state): emit.yield(.state(state))
                case .userTranscript(let text, let language): emit.yield(.userTranscript(text, language))
                case .assistantPiece(let piece): emit.yield(.assistantPiece(piece))
                case .conversationCleared: emit.yield(.conversationCleared)
                default: break
                }
            }
        }
        Task { [pipeline] in
            for await command in commandStream {
                switch command {
                case .newConversation: try? await pipeline.resetConversation()
                case .typedTurn(let text): await pipeline.submit(text: text)
                default: break
                }
            }
        }
    }

    func send(_ command: AssistantCommand) { commands.yield(command) }

    func stop() async { await pipeline.stop() }
}

/// Answers « Bonjour ! » to anything.
private struct Polite: LanguageModel {
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        AsyncThrowingStream {
            $0.yield(.text("Bonjour !"))
            $0.finish()
        }
    }

    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// A screen's transcript, as the apps keep it (one line per piece of an answer here, which has only one), and what it
/// was told, in order.
private final class Screen: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: [String] = []
    private var told: [String] = []
    private var lastState = ""

    /// The transcript's lines.
    var lines: [String] { lock.withLock { shown } }
    /// How many times it was told to clear its transcript.
    var clears: Int { lock.withLock { told.filter { $0 == "cleared" }.count } }
    /// What it was told since it was last told to clear.
    var afterLastClear: [String] { lock.withLock { told.lastIndex(of: "cleared").map { Array(told[($0 + 1)...]) } ?? [] } }
    var state: String { lock.withLock { lastState } }

    func show(_ event: AssistantEvent) {
        lock.withLock {
            switch event {
            case .state(let state):
                lastState = state.rawValue
                told.append("state \(state.rawValue)")
            case .userTranscript(let text, _):
                shown.append("user \(text)")
                told.append("user \(text)")
            case .assistantPiece(let piece):
                shown.append("Maé \(piece)")
                told.append("Maé \(piece)")
            case .conversationCleared:
                shown = []
                told.append("cleared")
            default: break
            }
        }
    }
}
