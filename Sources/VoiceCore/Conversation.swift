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
/// - An answer cut off (the user spoke over it) is kept as far as it went to the voice, never with a mark of the cut in
///   its words: the model read such a mark as part of how it writes, and copied it (`cutOffNote`).
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

    /// What the message after an answer cut off tells the model, after the user's words: their first line stays their
    /// words alone (`ToolContext.userSaid`), and the date line still ends the message (`ActionCatalog.dateLineRule`).
    ///
    /// The cut used to be marked in the answer itself (" […]" at its end). The model took that mark for part of how it
    /// writes: after a few answers cut off in a row it ended its own answers with it, more of them each time, until runs
    /// of dozens that the voice read for 20 s (Gemma 4 26B, ten answers cut off in a row in the app). Said in the next
    /// message instead, the model never sees it in its own words; and an answer the voice had been given to its end, then
    /// cut while it was said, is kept exactly as the model wrote it, which its memory (the KV cache) still matches.
    ///
    /// The note says what the user did, not what became of the answer: told that the user had not heard the end of its
    /// answer, Gemma 4 26B answered « Attends, attends. » by saying its answer again (59 times out of 60 in `voice-cli
    /// cut-off-bench`), told that its answer had been interrupted or had stopped before its end, by finishing it or
    /// offering to (14 and 15 times out of 24), where it used to answer « Je t'écoute » (0 out of 60). Told that the user
    /// cut it off: « Je t'écoute » again (0 out of 24), while it still knows it had not finished (« Tu avais fini ? » :
    /// « Non, je n'avais pas fini »).
    public static let cutOffNote = "(L'utilisateur t'a coupé la parole.)"

    public var systemPrompt: String
    /// Extra sentences contributed by extensions, appended to the system prompt.
    public var systemAddenda: [String] = []
    /// Exchanges shown to the model right after the system prompt, as if they had happened (`ActionCatalog.examples`).
    /// Constant like the system prompt, so the model keeps them pre-computed too. They are not `exchanges`: shortening
    /// the history or starting a new conversation keeps them, and they are never the user's words.
    public var examples: [ChatMessage] = []
    public private(set) var exchanges: [ChatMessage] = []
    /// The answer the history ends with was cut off (`record(…, interrupted: true)`): the next message says so
    /// (`cutOffNote`).
    public private(set) var endsCutOff = false

    public init(systemPrompt: String = Conversation.defaultSystemPrompt) {
        self.systemPrompt = systemPrompt
    }

    public var systemMessage: ChatMessage {
        ChatMessage(.system, ([systemPrompt] + systemAddenda).joined(separator: " "))
    }

    /// The user's message as stored in history (with the language hint when needed). With actions on, it ends
    /// with the date and time (`ActionCatalog.dateLine`): in the message rather than in the system prompt, so the
    /// prompt stays constant, and kept in history so the model's memory of the conversation stays valid.
    /// `afterCutOff`: the answer before it was cut off (`endsCutOff`), which the message then says (`cutOffNote`).
    public static func userMessage(_ text: String, language: SpeechLanguage, dateLine: String? = nil,
                                   afterCutOff: Bool = false) -> ChatMessage
    {
        var content = text
        if afterCutOff { content += "\n" + cutOffNote }
        if let dateLine { content += "\n" + dateLine }
        if language == .english { content += englishHint }
        return ChatMessage(.user, content)
    }

    /// The note of what the app says on its own (`VoicePipeline.announce`) as the history keeps it: as the user's message,
    /// before what was said; after an answer cut off, followed by `cutOffNote`.
    public static func noteMessage(_ note: String, afterCutOff: Bool = false) -> ChatMessage {
        ChatMessage(.user, afterCutOff ? note + "\n" + cutOffNote : note)
    }

    /// Messages to send for a new user turn (history is not modified: the turn may be speculative).
    public func messages(addingUser text: String, language: SpeechLanguage) -> [ChatMessage] {
        messages(adding: Self.userMessage(text, language: language, afterCutOff: endsCutOff))
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
        record(user: Self.userMessage(text, language: language, afterCutOff: endsCutOff), steps: [], assistant: answer,
               interrupted: interrupted)
    }

    /// Records an exchange with the tool calls made on the way (`steps`: call, result, possibly a second try).
    /// `interrupted`: the answer was cut off, as far as `answer` goes; the next message tells the model, so that it does
    /// not take the answer for one the user heard to its end (`cutOffNote`).
    public mutating func record(user message: ChatMessage, steps: [ChatMessage], assistant answer: String,
                                interrupted: Bool)
    {
        exchanges.append(message)
        exchanges += steps
        exchanges.append(ChatMessage(.assistant, answer))
        endsCutOff = interrupted
    }

    /// Drops the oldest exchange: a user message and everything up to the next one. Returns false when nothing
    /// is left to drop. A note on the next message about that exchange's answer cut off goes with it.
    @discardableResult
    public mutating func dropOldestExchange() -> Bool {
        guard exchanges.count >= 2 else { return false }
        let next = exchanges.dropFirst().firstIndex { $0.role == .user } ?? exchanges.endIndex
        exchanges.removeSubrange(..<next)
        if var first = exchanges.first, first.role == .user, let note = first.content.range(of: "\n" + Self.cutOffNote) {
            first.content.removeSubrange(note)
            exchanges[0] = first
        }
        if exchanges.isEmpty { endsCutOff = false }
        return true
    }

    /// Drops the `count` oldest exchanges.
    public mutating func dropOldestExchanges(_ count: Int) {
        for _ in 0..<count {
            guard dropOldestExchange() else { return }
        }
    }

    public mutating func clear() {
        exchanges.removeAll()
        endsCutOff = false
    }
}
