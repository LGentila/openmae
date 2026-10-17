import Foundation

/// The conversation history sent to the language model.
///
/// Design choices:
/// - The system prompt never changes during a session: the model keeps it pre-computed in memory,
///   and changing it would force recomputing the whole conversation.
/// - When the user switches to English, the hint goes into *their message* (and stays in history)
///   rather than into the system prompt, for the same reason.
/// - The context window is managed by dropping the oldest exchanges once the history exceeds a token
///   budget. Voice conversations are short; a small budget keeps the model fast and light.
/// - The default prompt is written in French on purpose: the assistant is French-first, and the model
///   follows the language of its instructions. In short: be a kind voice assistant, answer in one to three
///   short spoken sentences (longer for a story), open with a 5-to-8-word sentence (the voice renders shorter
///   ones as silence), no lists, markdown, emojis or links, use "tu" unless the user says "vous", and answer
///   in the user's language, French by default.
public struct Conversation: Sendable {
    public static let defaultSystemPrompt = """
        Tu es un assistant vocal bienveillant. Tu parles avec l'utilisateur à voix haute. \
        Par défaut, réponds en une à trois phrases courtes et naturelles, comme à l'oral ; \
        si l'utilisateur demande une histoire ou des détails, tu peux parler plus longtemps. \
        Commence toujours par une première phrase courte, de cinq à huit mots. \
        Pas de listes, pas de markdown, pas d'emojis, pas de liens. \
        Tutoie l'utilisateur, sauf s'il te vouvoie. \
        Réponds dans la langue de l'utilisateur, en français par défaut.
        """

    static let englishHint = "\n(The user is speaking English: answer in English.)"

    public var systemPrompt: String
    /// Extra sentences contributed by extensions, appended to the system prompt.
    public var systemAddenda: [String] = []
    /// Exchanges shown to the model right after the system prompt, as if they had happened (`ActionCatalog.examples`).
    /// Constant like the system prompt, so the model keeps them pre-computed too. They are not `exchanges`: shortening
    /// the history or starting a new conversation keeps them, and they are never the user's words.
    public var examples: [ChatMessage] = []
    public private(set) var exchanges: [ChatMessage] = []

    public init(systemPrompt: String = Conversation.defaultSystemPrompt) {
        self.systemPrompt = systemPrompt
    }

    public var systemMessage: ChatMessage {
        ChatMessage(.system, ([systemPrompt] + systemAddenda).joined(separator: " "))
    }

    /// The user's message as stored in history (with the language hint when needed). With actions on, it ends
    /// with the date and time (`ActionCatalog.dateLine`): in the message rather than in the system prompt, so the
    /// prompt stays constant, and kept in history so the model's memory of the conversation stays valid.
    public static func userMessage(_ text: String, language: SpeechLanguage, dateLine: String? = nil) -> ChatMessage {
        var content = text
        if let dateLine { content += "\n" + dateLine }
        if language == .english { content += englishHint }
        return ChatMessage(.user, content)
    }

    /// Messages to send for a new user turn (history is not modified: the turn may be speculative).
    public func messages(addingUser text: String, language: SpeechLanguage) -> [ChatMessage] {
        messages(adding: Self.userMessage(text, language: language))
    }

    public func messages(adding userMessage: ChatMessage) -> [ChatMessage] {
        beginning + exchanges + [userMessage]
    }

    public var messages: [ChatMessage] { beginning + exchanges }

    /// What every conversation starts with, before the user's first message: the system prompt and the examples.
    public var beginning: [ChatMessage] { [systemMessage] + examples }

    /// Records a completed (or interrupted) exchange.
    public mutating func record(user text: String, language: SpeechLanguage, assistant answer: String,
                                interrupted: Bool)
    {
        record(user: Self.userMessage(text, language: language), steps: [], assistant: answer, interrupted: interrupted)
    }

    /// Records an exchange with the tool calls made on the way (`steps`: call, result, possibly a second try).
    public mutating func record(user message: ChatMessage, steps: [ChatMessage], assistant answer: String,
                                interrupted: Bool)
    {
        exchanges.append(message)
        exchanges += steps
        // Tell the model it was cut off, so it does not assume the user heard everything.
        exchanges.append(ChatMessage(.assistant, interrupted ? answer + " […]" : answer))
    }

    /// Drops the oldest exchange: a user message and everything up to the next one. Returns false when nothing
    /// is left to drop.
    @discardableResult
    public mutating func dropOldestExchange() -> Bool {
        guard exchanges.count >= 2 else { return false }
        let next = exchanges.dropFirst().firstIndex { $0.role == .user } ?? exchanges.endIndex
        exchanges.removeSubrange(..<next)
        return true
    }

    /// Drops the `count` oldest exchanges.
    public mutating func dropOldestExchanges(_ count: Int) {
        for _ in 0..<count {
            guard dropOldestExchange() else { return }
        }
    }

    public mutating func clear() { exchanges.removeAll() }
}
