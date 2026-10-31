import Foundation
import Testing

@testable import VoiceCore

/// How the screens keep a connected tool's cards from the engine's events (`ToolActionCards`): the Mac's window, the
/// iPhone and iPad app, and the Mac's link for a device that comes back. And the tool's disc, which the iPhone gets with
/// the card (`ConnectedToolDisc`).
@Suite("The cards of a connected tool's actions")
struct ToolActionCardsTests {
    private static let tool = UUID()

    private static func card(_ target: String, _ status: ConnectedToolAction.Status = .waiting,
                             id: UUID = UUID()) -> ConnectedToolAction
    {
        ConnectedToolAction(id: id, toolID: tool, toolName: "Home Assistant",
                            words: .init(verb: "Allumer", target: target, result: "\(target) allumé"),
                            title: "Allumer le \(target.lowercased())", status: status, date: Date())
    }

    private static func again(_ card: ConnectedToolAction, _ status: ConnectedToolAction.Status) -> ConnectedToolAction {
        var card = card
        card.status = status
        return card
    }

    /// The latest status for each id; a dropped card goes; a new request's card replaces what the request before left,
    /// while the actions of one request share the card; the user's next turn clears what is over.
    @Test func eachCardShowsItsLatestStatusUntilTheNextTurn() {
        var cards = ToolActionCards()
        let salon = Self.card("Salon")
        cards.show(salon)
        #expect(cards.waits)
        #expect(cards.waiting.map(\.id) == [salon.id])
        #expect(cards.finished.isEmpty)
        // The answer's own turn (« oui »): the card that waits stays.
        cards.userSpoke()
        #expect(cards.waiting.map(\.id) == [salon.id])
        cards.show(Self.again(salon, .done))
        #expect(!cards.waits)
        #expect(cards.actions.map(\.status) == [.done])
        #expect(cards.finished.map(\.id) == [salon.id])
        // A dropped card that is not shown changes nothing.
        cards.show(Self.card("Garage", .dropped))
        #expect(cards.actions.map(\.id) == [salon.id])

        // A new request that waits: what the one before left goes. Two actions of one request share the card.
        let kitchen = Self.card("Cuisine"), office = Self.card("Bureau")
        cards.show(kitchen)
        cards.show(office)
        #expect(cards.actions.map(\.id) == [kitchen.id, office.id])
        cards.show(Self.again(kitchen, .refusedByUser))
        #expect(cards.waiting.map(\.id) == [office.id])
        #expect(cards.finished.map(\.id) == [kitchen.id])
        // Dropped: it goes.
        cards.show(Self.again(office, .dropped))
        #expect(cards.actions.map(\.id) == [kitchen.id])
        // The next turn: what is over goes.
        cards.userSpoke()
        #expect(cards.isEmpty)

        // Done directly: only what came of it, which stays until the next turn.
        let direct = Self.card("Couloir", .done)
        cards.show(direct)
        #expect(cards.actions.map(\.id) == [direct.id])
        cards.clear()
        #expect(cards.isEmpty)
    }

    /// The card's "Oui" or "Non" answers the most recent action that waits, once: its buttons are greyed until what
    /// comes of it (a new status, or the end of the answer's turn).
    @Test func theButtonsAnswerOnceUntilWhatComesOfIt() {
        var cards = ToolActionCards()
        #expect(cards.answer() == nil)  // nothing waits
        #expect(!cards.isAnswering)
        let salon = Self.card("Salon")
        cards.show(salon)
        #expect(cards.answer() == salon.id)
        #expect(cards.isAnswering)
        #expect(cards.answer() == nil)  // a second tap: nothing more
        // The answer's turn: the buttons stay greyed while it runs…
        cards.stateChanged(from: .listening, to: .thinking)
        #expect(cards.isAnswering)
        cards.stateChanged(from: .thinking, to: .speaking)
        #expect(cards.isAnswering)
        // …and what came of it ends the answer.
        cards.show(Self.again(salon, .done))
        #expect(!cards.isAnswering)
        #expect(cards.answer() == nil)

        // An answer that came too late, or was cut: once its turn is over, the buttons work again.
        let kitchen = Self.card("Cuisine")
        cards.show(kitchen)
        #expect(cards.answer() == kitchen.id)
        cards.stateChanged(from: .listening, to: .listening)
        #expect(cards.isAnswering)
        cards.stateChanged(from: .speaking, to: .listening)
        #expect(!cards.isAnswering)
        // A new card that waits brings the buttons back too.
        #expect(cards.answer() == kitchen.id)
        let office = Self.card("Bureau")
        cards.show(office)
        #expect(!cards.isAnswering)
        #expect(cards.answer() == office.id)  // the most recent that waits
        // A new conversation: nothing to answer.
        cards.clear()
        #expect(!cards.isAnswering)
        #expect(cards.answer() == nil)
    }

    /// The disc as the Mac's settings draw it: Home Assistant by its name or its address, otherwise a service on the home
    /// network or on the internet; its place in the list. A tool removed meanwhile is drawn from its name.
    @Test func theToolsDisc() throws {
        let home = ConnectedToolSettings(name: "Maison", address: "http://homeassistant.local:8123/api/mcp", access: .token)
        let named = ConnectedToolSettings(name: "Home Assistant", address: "https://example.com/mcp", access: .token)
        let nas = ConnectedToolSettings(name: "NAS", address: "192.168.1.20:8080/mcp", access: .none)
        let notes = ConnectedToolSettings(name: "Notes", address: "https://notes.example.com/mcp", access: .token)
        let tools = [home, named, nas, notes]
        #expect(ConnectedToolDisc(home, index: 0) == ConnectedToolDisc(kind: .homeAssistant, index: 0))
        #expect(ConnectedToolDisc(named, index: 1).kind == .homeAssistant)
        #expect(ConnectedToolDisc(nas, index: 2) == ConnectedToolDisc(kind: .homeNetwork, index: 2))
        #expect(ConnectedToolDisc(notes, index: 3) == ConnectedToolDisc(kind: .internet, index: 3))

        func action(of tool: ConnectedToolSettings) -> ConnectedToolAction {
            ConnectedToolAction(toolID: tool.id, toolName: tool.name, words: .init(verb: "Créer", target: nil, result: nil),
                                title: "Créer", status: .waiting, date: Date())
        }
        #expect(ConnectedToolDisc(of: action(of: notes), among: tools) == ConnectedToolDisc(kind: .internet, index: 3))
        #expect(ConnectedToolDisc(of: action(of: nas), among: tools) == ConnectedToolDisc(kind: .homeNetwork, index: 2))
        // Removed meanwhile: from its name, first in the list.
        #expect(ConnectedToolDisc(of: action(of: named), among: []) == ConnectedToolDisc(kind: .homeAssistant, index: 0))

        // The card and its disc go as plain data; a card without a disc (the Mac's own) is read too.
        var card = action(of: notes)
        card.disc = ConnectedToolDisc(of: card, among: tools)
        let decoded = try JSONDecoder().decode(ConnectedToolAction.self, from: JSONEncoder().encode(card))
        #expect(decoded == card)
        card.disc = nil
        let bare = try JSONDecoder().decode(ConnectedToolAction.self, from: JSONEncoder().encode(card))
        #expect(bare.disc == nil)
        #expect(bare == card)
        let answer = AssistantCommand.answerAction(true, action: card.id)
        #expect(try JSONDecoder().decode(AssistantCommand.self, from: JSONEncoder().encode(answer)) == answer)
    }
}
