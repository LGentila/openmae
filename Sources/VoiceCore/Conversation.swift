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
    public private(set) var exchanges: [ChatMessage] = []

    public init(systemPrompt: String = Conversation.defaultSystemPrompt) {
        self.systemPrompt = systemPrompt
    }

    public var systemMessage: ChatMessage {
        ChatMessage(.system, ([systemPrompt] + systemAddenda).joined(separator: " "))
    }

    /// The user's message as stored in history (with the language hint when needed).
    public static func userMessage(_ text: String, language: SpeechLanguage) -> ChatMessage {
        ChatMessage(.user, language == .english ? text + englishHint : text)
    }

    /// Messages to send for a new user turn (history is not modified: the turn may be speculative).
    public func messages(addingUser text: String, language: SpeechLanguage) -> [ChatMessage] {
        [systemMessage] + exchanges + [Self.userMessage(text, language: language)]
    }

    public var messages: [ChatMessage] { [systemMessage] + exchanges }

    /// Records a completed (or interrupted) exchange.
    public mutating func record(user text: String, language: SpeechLanguage, assistant answer: String,
                                interrupted: Bool)
    {
        exchanges.append(Self.userMessage(text, language: language))
        // Tell the model it was cut off, so it does not assume the user heard everything.
        exchanges.append(ChatMessage(.assistant, interrupted ? answer + " […]" : answer))
    }

    /// Drops the oldest user/assistant pair. Returns false when nothing is left to drop.
    @discardableResult
    public mutating func dropOldestExchange() -> Bool {
        guard exchanges.count >= 2 else { return false }
        exchanges.removeFirst(2)
        return true
    }

    /// Drops the `count` oldest user/assistant pairs.
    public mutating func dropOldestExchanges(_ count: Int) {
        exchanges.removeFirst(min(count * 2, exchanges.count))
    }

    public mutating func clear() { exchanges.removeAll() }
}
