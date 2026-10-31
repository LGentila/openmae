import FakeHomeAssistant
import Foundation
import Testing
import VoiceCore

@testable import OpenMaeLink

/// A connected tool's action card on the iPhones and iPads (`AssistantEvent.connectedToolAction`) and its "Oui" and "Non"
/// from them (`AssistantCommand.answerAction`), with the pretend Home Assistant behind the engine's real conversation
/// logic: the card goes only to the devices that list it (`LinkMessage.toolActionFeature`), with the tool's disc; its
/// buttons answer as a spoken « oui » or « non » does, only while its action waits; and a device that comes back after
/// a drop sees each card at its latest status.
@Suite("A connected tool's card over the link", .serialized)
struct ToolActionCardLinkTests {
    /// What the iPhone app from before this one said about itself.
    static let before = HandshakePayload.Session(features: [LinkMessage.partialTranscriptFeature,
                                                            LinkMessage.conversationClearedFeature])

    @Test func itGoesOnlyToDevicesThatListIt() throws {
        let card = ConnectedToolAction(toolID: UUID(), toolName: "Home Assistant",
                                       words: .init(verb: "Allumer", target: "Salon", result: "Salon allumé"),
                                       title: "Allumer le salon", status: .waiting,
                                       date: Date(timeIntervalSince1970: 1_800_000_000),
                                       disc: ConnectedToolDisc(kind: .homeAssistant, index: 0))
        #expect(RemoteCommandPolicy.isRelayed(.connectedToolAction(card)))
        #expect(RemoteCommandPolicy.neededFeature(.connectedToolAction(card)) == LinkMessage.toolActionFeature)
        #expect(RemoteCommandPolicy.isAllowed(.answerAction(true, action: card.id)))
        // This version's app lists it; the version before did not.
        let sent = try JSONDecoder().decode(HandshakePayload.Session.self,
                                            from: HandshakePayload.encode(HandshakePayload.Session.current))
        #expect(sent.understands(LinkMessage.toolActionFeature))
        #expect(sent.understands(LinkMessage.conversationClearedFeature))
        let before = try JSONDecoder().decode(HandshakePayload.Session.self,
                                              from: Data(#"{"v":1,"features":["partialTranscript","conversationCleared"]}"#.utf8))
        #expect(!before.understands(LinkMessage.toolActionFeature))
        // Decoded as sent: the card with its disc, and the answer with its card's action.
        guard case .event(.connectedToolAction(let decoded)) = try LinkMessage(decoding: LinkMessage.event(
            .connectedToolAction(card)).encoded)
        else {
            Issue.record("not decoded as a card")
            return
        }
        #expect(decoded == card)
        guard case .command(let answer) = try LinkMessage(decoding: LinkMessage.command(
            .answerAction(false, action: card.id)).encoded)
        else {
            Issue.record("not decoded as a command")
            return
        }
        #expect(answer == .answerAction(false, action: card.id))
    }

    /// « Allume le salon »: the card waits on the Mac and on the iPhone (with Home Assistant's disc, which the Mac's settings
    /// give), not on an app from before it. Its "Oui" from the iPhone turns the living room on, as a spoken « oui » does,
    /// and both cards show it done; « Allume la cuisine », then its "Non": refused, nothing reaches Home Assistant.
    @Test func theCardsButtonsOnAPhoneAnswerAsTheVoiceDoes() async throws {
        let mac = try await MacWithHomeAssistant()
        let phone = await mac.device(41, hello: .current)
        let old = await mac.device(42, hello: Self.before)

        mac.host.send(.typedTurn("Allume le salon"))
        await waitFor { phone.screen.cards.waits && mac.screen.cards.waits }
        let salon = try #require(phone.screen.cards.waiting.first)
        #expect(salon.toolName == "Home Assistant")
        #expect(salon.words == .init(verb: "Allumer", target: "Salon", result: "Salon allumé"))
        #expect(salon.disc == ConnectedToolDisc(kind: .homeAssistant, index: 0))
        #expect(mac.screen.cards.waiting.map(\.id) == [salon.id])
        #expect(mac.screen.cards.waiting.first?.disc == nil)  // the Mac's window looks the tool up in its settings

        // Its "Oui", from the iPhone.
        let yes = try #require(phone.screen.answer())
        #expect(yes == salon.id)
        phone.session.send(.command(.answerAction(true, action: yes)))
        await waitFor { phone.screen.cards.finished.first?.status == .done && mac.screen.cards.finished.first?.status == .done }
        #expect(mac.server.calls.map(\.name) == ["intent__HassTurnOn"])
        #expect(mac.server.calls.first?.arguments["area"]?.text == "salon")
        #expect(phone.screen.cards.actions.map(\.id) == [salon.id])
        #expect(mac.screen.cards.actions.map(\.id) == [salon.id])
        #expect(!phone.screen.cards.isAnswering)
        #expect(phone.screen.userTexts == ["Allume le salon", "Oui"])  // as if said
        #expect(mac.engine.answers == [true])

        // « Allume la cuisine »: the card of the request before goes; its "Non".
        mac.host.send(.typedTurn("Allume la cuisine"))
        await waitFor { phone.screen.cards.waits && mac.screen.cards.waits }
        let kitchen = try #require(phone.screen.cards.waiting.first)
        #expect(phone.screen.cards.actions.map(\.id) == [kitchen.id])
        phone.session.send(.command(.answerAction(false, action: try #require(phone.screen.answer()))))
        await waitFor {
            phone.screen.cards.finished.first?.status == .refusedByUser
                && mac.screen.cards.finished.first?.status == .refusedByUser
        }
        #expect(mac.server.calls.count == 1)
        #expect(phone.screen.userTexts.suffix(1) == ["Non"])
        #expect(mac.engine.answers == [true, false])

        // The app from before got the conversation, never a card (it would have closed the session on it).
        try await Task.sleep(for: .milliseconds(200))
        #expect(old.screen.cardsTold.isEmpty)
        #expect(old.screen.userTexts == ["Allume le salon", "Oui", "Allume la cuisine", "Non"])
        await mac.stop()
    }

    /// An answer counts only while its card's action waits: with nothing that waits, and from a card whose action was
    /// dropped meanwhile, even while another action waits, nothing reaches the engine (nor Home Assistant), and the device
    /// is told what became of that card.
    @Test func anAnswerCountsOnlyWhileItsActionWaits() async throws {
        let mac = try await MacWithHomeAssistant()
        let phone = await mac.device(43, hello: .current)
        phone.session.send(.command(.answerAction(true, action: UUID())))  // nothing waits

        mac.host.send(.typedTurn("Allume le salon"))
        await waitFor { phone.screen.cards.waits }
        let salon = try #require(phone.screen.cards.waiting.first)
        // A new conversation on the Mac drops it.
        mac.host.send(.newConversation)
        await waitFor { phone.screen.cards.isEmpty && mac.screen.cards.isEmpty }
        phone.session.send(.command(.answerAction(true, action: salon.id)))
        // Another action waits: the "Oui" of the card left on a screen does not answer it.
        mac.host.send(.typedTurn("Allume la cuisine"))
        await waitFor { phone.screen.cards.waits }
        let kitchen = try #require(phone.screen.cards.waiting.first)
        let told = phone.screen.cardsTold.count
        phone.session.send(.command(.answerAction(true, action: salon.id)))
        await waitFor { phone.screen.cardsTold.count > told }
        try await Task.sleep(for: .milliseconds(300))
        #expect(mac.engine.answers.isEmpty)
        #expect(mac.server.calls.isEmpty)
        #expect(mac.screen.userTexts == ["Allume le salon", "Allume la cuisine"])
        #expect(mac.screen.cards.waiting.map(\.id) == [kitchen.id])
        // What became of that card, sent again to the device that answered it.
        #expect(phone.screen.cardsTold.last?.id == salon.id)
        #expect(phone.screen.cardsTold.last?.status == .dropped)
        #expect(phone.screen.cards.waiting.map(\.id) == [kitchen.id])

        // The card that waits answers.
        phone.session.send(.command(.answerAction(true, action: kitchen.id)))
        await waitFor { mac.server.calls.count == 1 && phone.screen.cards.finished.first?.status == .done }
        #expect(mac.engine.answers == [true])
        #expect(mac.server.calls.first?.arguments["area"]?.text == "cuisine")
        await mac.stop()
    }

    /// The iPhone's network goes without a word reaching anyone (the link's grace period), and comes back on a new
    /// session: it sees each card at its latest status — done meanwhile by a « oui » said on the Mac; gone when dropped
    /// meanwhile, while another one waits now. Its "Oui" on the card it still showed answers nothing; on the new one, it
    /// does.
    @Test func aDeviceThatComesBackSeesEachCardAtItsLatestStatus() async throws {
        let mac = try await MacWithHomeAssistant()
        let screen = Screen()  // the app keeps its cards through a drop
        let first = await mac.device(44, hello: .current, screen: screen)
        mac.host.send(.typedTurn("Allume le salon"))
        await waitFor { screen.cards.waits }
        let salon = try #require(screen.cards.waiting.first)

        // Cut; « oui » said on the Mac.
        first.wire.cut()
        mac.host.send(.typedTurn("Oui"))
        await waitFor { mac.screen.cards.finished.first?.status == .done }
        #expect(screen.cards.waiting.map(\.id) == [salon.id])  // it did not hear of it
        let second = await mac.device(44, hello: .current, screen: screen)
        await waitFor { !screen.cards.waits }
        #expect(screen.cards.actions.map(\.id) == [salon.id])
        #expect(screen.cards.actions.map(\.status) == [.done])

        // Another request waits; cut; meanwhile a new conversation drops it, and another one waits.
        mac.host.send(.typedTurn("Allume la cuisine"))
        await waitFor { screen.cards.waits }
        let kitchen = try #require(screen.cards.waiting.first)
        second.wire.cut()
        mac.host.send(.newConversation)
        mac.host.send(.typedTurn("Allume la chambre"))
        await waitFor { mac.screen.cards.waiting.contains { $0.id != kitchen.id } }
        let bedroom = try #require(mac.screen.cards.waiting.first)
        #expect(bedroom.words.target == "Chambre")
        #expect(screen.cards.waiting.map(\.id) == [kitchen.id])
        let third = await mac.device(44, hello: .current, screen: screen)
        await waitFor { screen.cards.waiting.map(\.id) == [bedroom.id] }
        #expect(screen.cards.actions.map(\.id) == [bedroom.id])

        // A late tap on the kitchen's card (sent before it heard of it): nothing. The bedroom's: done.
        third.session.send(.command(.answerAction(true, action: kitchen.id)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(mac.server.calls.map { $0.arguments["area"]?.text } == ["salon"])
        third.session.send(.command(.answerAction(true, action: bedroom.id)))
        await waitFor { screen.cards.finished.first?.status == .done }
        #expect(mac.server.calls.map { $0.arguments["area"]?.text } == ["salon", "chambre"])
        #expect(screen.cards.actions.map(\.id) == [bedroom.id])
        await mac.stop()
    }
}

// MARK: - The Mac, with the pretend Home Assistant

/// The pretend Home Assistant as a connected tool that asks first, the engine with it, and the Mac's link with the
/// settings that list it; the Mac's window (`screen`).
private struct MacWithHomeAssistant {
    let server: FakeHomeAssistant
    let engine: ToolEngine
    let host: LinkHost
    let screen = Screen()
    private let folder: URL

    init() async throws {
        server = FakeHomeAssistant()
        try await server.start()
        let client = MCPClient(address: server.address, token: nil, timeout: .seconds(5))
        var tool = ConnectedToolSettings(name: "Home Assistant", address: server.address.absoluteString, access: .none)
        tool.actions = tool.merging(try await client.listTools())
        engine = try await ToolEngine(tool: tool, client: client)
        folder = FileManager.default.temporaryDirectory.appending(path: "tool-card-\(UUID().uuidString)")
        host = LinkHost(engine: engine, audio: nil, identityStore: NoIdentity(),
                        storeURL: folder.appending(path: "link.json"), macName: "Mac de test")
        var settings = AssistantSettings()
        settings.connectedTools = [tool]
        host.send(.updateSettings(settings))
        let screen = screen
        Task { [host] in for await event in host.events { screen.show(event) } }
    }

    /// An iPhone's session, opened (again, for one that comes back), with what it said about itself; its screen.
    func device(_ number: UInt8, hello: HandshakePayload.Session?, screen: Screen = Screen()) async
        -> (wire: MemoryWire, session: LinkSession, screen: Screen)
    {
        let key = Data(repeating: number, count: 32)
        let wire = MemoryWire(path: .direct)
        let (macEnd, phoneEnd) = wire.sessions(phoneKey: key, macKey: Data(repeating: 7, count: 32), hello: hello)
        Task { for await message in phoneEnd.messages { if case .event(let event) = message { screen.show(event) } } }
        await host.open(macEnd, device: PairedDevice(publicKey: key, name: "iPhone", model: "iPhone17,3"))
        return (wire, phoneEnd, screen)
    }

    func stop() async {
        await engine.stop()
        server.stop()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The engine, as `AssistantHost` is for what these tests look at: the real conversation logic (`VoicePipeline`, on
/// stages without models) with the connected tools, its events and the cards passed on, and a card's answer taken only
/// while its action waits. It notes the cards' answers that reach it.
private final class ToolEngine: AssistantConnection, @unchecked Sendable {
    let events: AsyncStream<AssistantEvent>
    private let pipeline: VoicePipeline
    private let commands: AsyncStream<AssistantCommand>.Continuation
    private let lock = NSLock()
    private var received: [Bool] = []

    /// The cards' answers that reached the engine, in order.
    var answers: [Bool] { lock.withLock { received } }

    init(tool: ConnectedToolSettings, client: MCPClient) async throws {
        let tools = ConnectedTools()
        await tools.configure([ConnectedTools.Connection(settings: tool, client: client)])
        let pipeline = VoicePipeline(detector: Silence(), transcriber: Deaf(), model: HomeRequests(),
                                     synthesizer: ToneVoice(), output: CountingSpeaker(),
                                     tools: ToolRunner(providers: [tools], actions: false))
        self.pipeline = pipeline
        let (events, emit) = AsyncStream<AssistantEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = events
        let (commandStream, commands) = AsyncStream<AssistantCommand>.makeStream(bufferingPolicy: .unbounded)
        self.commands = commands
        await tools.observe { report in
            if case .action(let card) = report { emit.yield(.connectedToolAction(card)) }
        }
        try await pipeline.start()
        Task {
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
        Task { [weak self] in
            for await command in commandStream {
                switch command {
                case .newConversation: try? await pipeline.resetConversation()
                case .typedTurn(let text): await pipeline.submit(text: text)
                case .answerAction(let yes, let action):
                    self?.lock.withLock { self?.received.append(yes) }
                    guard await tools.waits(action) else { continue }
                    await pipeline.submit(answer: yes)
                default: break
                }
            }
        }
    }

    func send(_ command: AssistantCommand) { commands.yield(command) }

    func stop() async { await pipeline.stop() }
}

/// Turns the room on with Home Assistant for « Allume le salon », « … la cuisine », « … la chambre »; « D’accord. » to
/// anything else.
private struct HomeRequests: LanguageModel {
    func reply(to conversation: [ChatMessage]) -> AsyncThrowingStream<ModelOutput, Error> {
        let said = conversation.last(where: { $0.role == .user })?.content ?? ""
        let room = ["salon", "cuisine", "chambre"].first { said.contains($0) }
        return AsyncThrowingStream {
            if let room {
                $0.yield(.toolCall(ToolCall(name: "intent__HassTurnOn", arguments: ["area": .string(room)])))
            } else {
                $0.yield(.text("D’accord."))
            }
            $0.finish()
        }
    }

    func prefill(_ conversation: [ChatMessage]) async throws {}
    func tokenCount(_ conversation: [ChatMessage]) async throws -> Int { conversation.count * 10 }
}

/// A screen, keeping the cards as the apps do (`ToolActionCards`), with what it was told of them and of the user's
/// words, in order.
private final class Screen: @unchecked Sendable {
    private let lock = NSLock()
    private var kept = ToolActionCards()
    private var state = PipelineState.listening
    private var told: [ConnectedToolAction] = []
    private var said: [String] = []

    var cards: ToolActionCards { lock.withLock { kept } }
    /// Every card it was sent, in order.
    var cardsTold: [ConnectedToolAction] { lock.withLock { told } }
    var userTexts: [String] { lock.withLock { said } }

    func show(_ event: AssistantEvent) {
        lock.withLock {
            switch event {
            case .state(let new):
                kept.stateChanged(from: state, to: new)
                state = new
            case .userTranscript(let text, _):
                said.append(text)
                kept.userSpoke()
            case .connectedToolAction(let card):
                told.append(card)
                kept.show(card)
            case .conversationCleared:
                kept.clear()
            default: break
            }
        }
    }

    /// The card's "Oui" or "Non" is tapped, as in the apps: the action it answers.
    func answer() -> UUID? { lock.withLock { kept.answer() } }
}
