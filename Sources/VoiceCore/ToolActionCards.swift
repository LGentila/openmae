import Foundation

/// The cards under Maé's sentence, as a screen keeps them from the engine's events (`AssistantEvent.connectedToolAction`):
/// the connected tools' actions of the request under way, those that wait for the user's "oui", then what came of them.
/// They stay until the user's next turn; one that still waits stays until it is carried out, refused or dropped. The
/// Mac's window, the iPhone and iPad app, and the Mac's link (to tell a device that comes back what it missed) keep them
/// the same way.
public struct ToolActionCards: Sendable, Equatable {
    /// In the order they came, each one at its latest status (never `dropped`: a dropped one goes).
    public private(set) var actions: [ConnectedToolAction] = []
    /// A card's "Oui" or "Non" was tapped: its buttons wait for what comes of it.
    public private(set) var isAnswering = false

    public init() {}

    public var isEmpty: Bool { actions.isEmpty }

    /// An action waits for the user's "oui".
    public var waits: Bool { actions.contains { $0.status == .waiting } }

    /// Those that wait for the user's "oui": the card's first line.
    public var waiting: [ConnectedToolAction] { actions.filter { $0.status == .waiting } }

    /// Those carried out, refused or failed: the card's second line, or its only one.
    public var finished: [ConnectedToolAction] { actions.filter { $0.status != .waiting } }

    /// A card's new status, or a new card: an action of the same request joins those shown, one of a new request
    /// replaces what the one before left; a dropped one goes. An answer under way is over once an action waits anew or
    /// none waits any more.
    public mutating func show(_ action: ConnectedToolAction) {
        if let i = actions.firstIndex(where: { $0.id == action.id }) {
            if action.status == .dropped { actions.remove(at: i) } else { actions[i] = action }
        } else if action.status != .dropped {
            if action.status == .waiting { actions.removeAll { $0.status != .waiting } }
            actions.append(action)
        }
        if action.status == .waiting || !waits { isAnswering = false }
    }

    /// The user's new turn: what the request before did goes; what still waits for the "oui" stays (this may be the
    /// answer).
    public mutating func userSpoke() {
        actions.removeAll { $0.status != .waiting }
    }

    /// The conversation's state changed: once the turn of a card's answer is over, if the action still waits (the answer
    /// came too late, or was cut), its buttons work again.
    public mutating func stateChanged(from before: PipelineState, to state: PipelineState) {
        if state == .listening, before != .listening { isAnswering = false }
    }

    /// The card's "Oui" or "Non" is tapped: the action it answers (the most recent that waits,
    /// `AssistantCommand.answerAction`), its buttons greyed until what comes of it. nil when nothing waits, or while an
    /// answer is under way.
    public mutating func answer() -> UUID? {
        guard !isAnswering, let action = actions.last(where: { $0.status == .waiting }) else { return nil }
        isAnswering = true
        return action.id
    }

    /// A new conversation: no card.
    public mutating func clear() {
        actions = []
        isAnswering = false
    }
}
