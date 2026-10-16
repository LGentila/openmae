import Foundation

/// Timers kept by the app ("mets un minuteur de 10 minutes pour les pâtes"). They keep running when the window
/// is closed, not when the app quits. At the end, `onFinish` gets what to say (the pipeline speaks it after a
/// chime, and the app shows a notification).
public actor TimerTools: ToolProvider {
    public nonisolated let identifier = "timers"

    public struct Finished: Sendable {
        public var text: String
        /// For the conversation history: what happened, as a note from the app.
        public var note: String
        public var language: SpeechLanguage
    }

    private var onFinish: @Sendable (Finished) -> Void = { _ in }
    private var onFirstTimer: @Sendable () async -> Void = {}
    private var running: [String: Task<Void, Never>] = [:]
    private var nextID = 0

    public init() {}

    /// `onFirstTimer` runs once, when the first timer starts (the app asks for notifications then).
    public func observe(onFinish: @escaping @Sendable (Finished) -> Void,
                        onFirstTimer: @escaping @Sendable () async -> Void = {})
    {
        self.onFinish = onFinish
        self.onFirstTimer = onFirstTimer
    }

    public func tools() -> [ToolSpec] { [ActionCatalog.timer] }

    public func check(_ call: ToolCall, context: ToolContext) throws {
        _ = try ActionCatalog.timerSeconds(call, context: context)
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        let seconds = try ActionCatalog.timerSeconds(call, context: context)
        let label = call.text("libelle")
        if nextID == 0 {
            // Not awaited: macOS's dialog must not hold up the confirmation.
            let first = onFirstTimer
            Task { await first() }
        }
        nextID += 1
        let id = "t\(nextID)"
        let language = context.language
        let finished = Finished(
            text: ActionPhrases.timerFinished(seconds: seconds, label: label, language),
            note: "(Le minuteur \(id)\(label.map { " « \($0) »" } ?? "") de \(seconds) secondes vient de sonner.)",
            language: language)
        running[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.fire(id, finished)
        }
        return ToolOutcome(
            spoken: ActionPhrases.timerStarted(seconds: seconds, label: label, language),
            forModel: ["id": .string(id), "duree_secondes": .int(seconds), "libelle": label.map(JSONValue.string) ?? .null,
                       "fin": .string(LocalDateTime.format(context.now.addingTimeInterval(TimeInterval(seconds)),
                                                           in: context.timeZone))],
            undo: UndoToken(provider: identifier, id: id))
    }

    public func undo(_ token: UndoToken, context: ToolContext) throws -> String {
        running.removeValue(forKey: token.id)?.cancel()
        return ActionPhrases.undone(.timer, context.language)
    }

    /// Timers still running.
    public var count: Int { running.count }

    private func fire(_ id: String, _ finished: Finished) {
        guard running.removeValue(forKey: id) != nil else { return }
        onFinish(finished)
    }
}
