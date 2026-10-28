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
///   its words: the model read such a mark as part of how it writes, and copied it. A note says so instead
///   (`cutOffNote`), where the tier puts it (`cutOffPlacement(on:)`). An answer cut by a drop (the device that has the
///   conversation went out of reach) is kept as the model wrote it, with a note of its own that says where the user
///   stopped hearing it (`dropNote`).
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

    /// What the history says after an answer cut off, where the tier puts it (`cutOffPlacement(on:)`).
    ///
    /// The cut used to be marked in the answer itself (" […]" at its end). The model took that mark for part of how it
    /// writes: after a few answers cut off in a row it ended its own answers with it, more of them each time, until runs
    /// of dozens that the voice read for 20 s (Gemma 4 26B, ten answers cut off in a row in the app). Said outside the
    /// answer instead, the model never sees it in its own words; and an answer the voice had been given to its end, then
    /// cut while it was said, is kept exactly as the model wrote it, which its memory (the KV cache) still matches.
    ///
    /// The note says what the user did, not what became of the answer: told that the user had not heard the end of its
    /// answer, Gemma 4 26B answered « Attends, attends. » by saying its answer again (59 times out of 60 in `voice-cli
    /// cut-off-bench`), told that its answer had been interrupted or had stopped before its end, by finishing it or
    /// offering to (14 and 15 times out of 24), where it used to answer « Je t'écoute » (0 out of 60). Told that the user
    /// cut it off: « Je t'écoute » again (0 out of 24), while it still knows it had not finished (« Tu avais fini ? » :
    /// « Non, je n'avais pas fini »).
    public static let cutOffNote = "(L'utilisateur t'a coupé la parole.)"

    /// `cutOffNote` read ahead (`CutOffPlacement.ahead`): a message of its own, the app's (the system's role), right after
    /// the answer cut off. The model computes it with the rest of the history as soon as the cut is recorded, while the
    /// user is still speaking (`LanguageModel.catchUp`): their request then has only their own message left to read. The
    /// note goes with the exchange it is about when the history is shortened.
    public static let cutOffMessage = ChatMessage(.system, cutOffNote)

    /// What the history says after an answer cut by a drop (`Ending.dropped`): the device that has the conversation (an
    /// iPhone) went out of reach in the middle of the answer and was not back in time to hear the rest; `lastHeard`, the
    /// last piece of it the device heard (nil: none). Where the tier puts the note of an answer cut off
    /// (`cutOffPlacement(on:)`).
    ///
    /// Such an answer used to be kept as far as the device heard it, as one the user had cut off (`cutOffNote`),
    /// although nobody had. After three of them, cut after their first piece, Gemma 4 26B answered the next
    /// « Raconte-moi … » with a single whole sentence 10 times out of 10 (`voice-cli cut-off-bench`, with
    /// Tests/Fixtures/drops-fr.json), often then a few words and nothing more, as its answers in the history: imitating
    /// them, not the note. Kept as far as the device heard it with a note that the link dropped: 3 times out of 10;
    /// without a note: 5. The pipeline keeps it as the model wrote it instead (`VoicePipeline.recordHeard`): 0 times out
    /// of 10, with as many sentences as with no drop, on the 26B, E4B and E2B. And the note says where the user stopped
    /// hearing it: told only that they had heard its beginning, the 26B asked « Qu'est-ce que tu disais ? » gave the end
    /// of its story, which the user had not heard (10 times out of 10); told up to where, it took the story up from
    /// there (9 times out of 10).
    public static func dropNote(lastHeard: String?) -> String {
        guard let lastHeard = lastHeard.map(quoted), !lastHeard.isEmpty else {
            return dropNotePrefix + " : l'utilisateur n'a pas entendu ta réponse.)"
        }
        return dropNotePrefix + " : l'utilisateur n'a entendu ta réponse que jusqu'à « \(lastHeard) ».)"
    }

    /// How every `dropNote` begins.
    static let dropNotePrefix = "(La liaison avec l'appareil a coupé"

    /// What the app tells the model, as a message of its own, before it sums up what came from outside (a search's
    /// results, an agent's report) when the app already said something in the turn (an action's sentence, said at once):
    /// the model's answer so far ends with what the app said, as the user heard it, then this note asks for the rest, in
    /// a turn of its own (`summingUpSteps`).
    ///
    /// Without them, the model summed up every result of the request, the action's too, which the user had heard already:
    /// « C’est parti pour 5 minutes. Je te préviens à la fin. C'est parti pour le minuteur de cinq minutes. Pour l'action
    /// Apple, … » (Gemma 4 26B, 8 and 10 summaries in 10 in voice-cli actions-bench with
    /// Tests/Fixtures/actions-search-fr.json). A note in the action's result saying that it had been said, with or
    /// without the sentence, or in the search's results, or a rule in the system prompt: still 3 to 6 summaries in 5 to
    /// 8. The model's answer going on after the app's sentence (that sentence as the start of its answer): never said
    /// again, but half the summaries were then empty or only « Je cherche le cours de l'action Apple. ». Asked to « dis-lui
    /// maintenant ce que tu as trouvé », it answered at once from the snippets, opening a page 2 times in 8. With this
    /// note: 0 summaries in 30 (the corpus's three requests, ten times each: a timer before or after the search, a
    /// reminder), each one the search's, a page opened as often as before.
    public static let summingUpNote = "(L'utilisateur a entendu ta réponse ci-dessus. Continue avec le reste de sa demande.)"

    /// What goes into the history before the model sums up what came from outside, after `said`, what the app already
    /// said in the turn: the answer so far, that sentence, which the template ends there, then `summingUpNote`, as the
    /// app's message. The answer the history keeps after them is the rest of what was said.
    public static func summingUpSteps(after said: String) -> [ChatMessage] {
        [ChatMessage(.assistant, said), ChatMessage(.system, summingUpNote)]
    }

    /// A piece of an answer on one line, without the white space around it.
    private static func quoted(_ piece: String) -> String {
        piece.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `dropNote` read ahead (`CutOffPlacement.ahead`), as `cutOffMessage`.
    public static func dropMessage(lastHeard: String?) -> ChatMessage {
        ChatMessage(.system, dropNote(lastHeard: lastHeard))
    }

    /// How an answer the history keeps ended.
    public enum Ending: Sendable, Equatable {
        /// Heard to its end.
        case whole
        /// The user cut it off (they spoke over it, the stop button, a typed turn): kept as far as it went to the voice,
        /// and `cutOffNote` says so.
        case cutOff
        /// Cut by a drop: the device that has the conversation went out of reach in the middle of it, after it heard
        /// `lastHeard` (nil: nothing), and `dropNote` says so. The pipeline keeps it as the model wrote it.
        case dropped(lastHeard: String?)

        /// What the history says after the answer.
        var note: String? {
            switch self {
            case .whole: nil
            case .cutOff: Conversation.cutOffNote
            case .dropped(let lastHeard): Conversation.dropNote(lastHeard: lastHeard)
            }
        }
    }

    /// Where the history tells the model that an answer was cut off (`cutOffNote`), or cut by a drop (`dropNote`).
    /// Either way the user's words begin their message (`ToolContext.userSaid` reads its first line), and the date line
    /// still ends it (`ActionCatalog.dateLineRule`).
    public enum CutOffPlacement: String, Sendable, CaseIterable {
        /// Read ahead, while the user is still speaking: a message of its own right after the answer (`cutOffMessage`).
        case ahead
        /// In the user's next message, after their words: the model reads it with them, once they have stopped.
        case afterUserWords = "after-user-words"
    }

    /// Where the note goes on each tier. Gemma 4 26B (comfort and max) reads it ahead: the request right after an answer
    /// cut off then reads 12 tokens fewer, 414 ms instead of 506 (median of 12, `voice-cli cache-check` on the reference
    /// Mac), and the model still listens to « Attends, attends. » (60 times out of 60, `voice-cli cut-off-bench`) and
    /// knows it had not finished (« Tu avais fini ? » taken for an answer that was over: 0 or 1 time out of 10). E4B and
    /// E2B (standard and minimum) keep it after the user's words: read before them, it made them take that answer for
    /// one that was over 4 and 10 times out of 10, against 0 or 1 and 1 or 2 after them (in the user's role, the same);
    /// and with their words it costs them little (E4B: 190 ms instead of 186).
    public static func cutOffPlacement(on tier: HardwareTier) -> CutOffPlacement {
        switch tier {
        case .comfort, .max: .ahead
        case .unsupported, .minimum, .standard: .afterUserWords
        }
    }

    public var systemPrompt: String
    /// Extra sentences contributed by extensions, appended to the system prompt.
    public var systemAddenda: [String] = []
    /// Exchanges shown to the model right after the system prompt, as if they had happened (`ActionCatalog.examples`).
    /// Constant like the system prompt, so the model keeps them pre-computed too. They are not `exchanges`: shortening
    /// the history or starting a new conversation keeps them, and they are never the user's words.
    public var examples: [ChatMessage] = []
    public private(set) var exchanges: [ChatMessage] = []
    /// Where this conversation tells the model that an answer was cut off: the tier's (`cutOffPlacement(on:)`), which
    /// the pipeline sets from `PipelineConfig.cutOffPlacement`.
    public var cutOffPlacement = CutOffPlacement.ahead
    /// The answer the history ends with was cut off or cut by a drop, and its note waits for the next message
    /// (`CutOffPlacement.afterUserWords`): `nextUserMessage` and `nextNoteMessage` add it.
    private var dueNote: String?
    /// What happened meanwhile that the user learnt elsewhere (`noteForNextMessage`), waiting for the next message of the
    /// user's role.
    private var meanwhile: [String] = []

    public init(systemPrompt: String = Conversation.defaultSystemPrompt) {
        self.systemPrompt = systemPrompt
    }

    public var systemMessage: ChatMessage {
        ChatMessage(.system, ([systemPrompt] + systemAddenda).joined(separator: " "))
    }

    /// The user's message as stored in history (with the language hint when needed). With actions on, it ends
    /// with the date and time (`ActionCatalog.dateLine`): in the message rather than in the system prompt, so the
    /// prompt stays constant, and kept in history so the model's memory of the conversation stays valid.
    /// `note`: the note of an answer cut off or cut by a drop, which follows the user's words
    /// (`CutOffPlacement.afterUserWords`). `meanwhile`: what happened since that the user learnt elsewhere
    /// (`noteForNextMessage`), after it.
    public static func userMessage(_ text: String, language: SpeechLanguage, dateLine: String? = nil,
                                   note: String? = nil, meanwhile: [String] = []) -> ChatMessage
    {
        var content = text
        if let note { content += "\n" + note }
        for event in meanwhile { content += "\n" + event }
        if let dateLine { content += "\n" + dateLine }
        if language == .english { content += englishHint }
        return ChatMessage(.user, content)
    }

    /// The user's next message as the history will keep it (`userMessage`): after an answer cut off or cut by a drop,
    /// with its note after their words when it goes there (`CutOffPlacement.afterUserWords`); then what happened
    /// meanwhile (`noteForNextMessage`).
    public func nextUserMessage(_ text: String, language: SpeechLanguage, dateLine: String? = nil) -> ChatMessage {
        Self.userMessage(text, language: language, dateLine: dateLine, note: dueNote, meanwhile: meanwhile)
    }

    /// The note of what the app says on its own next (`VoicePipeline.announce`) as the history will keep it: as the
    /// user's message, before what was said; after an answer cut off or cut by a drop, followed by its note when it goes
    /// there; then what happened meanwhile (`noteForNextMessage`).
    public func nextNoteMessage(_ note: String) -> ChatMessage {
        ChatMessage(.user, ([note] + (dueNote.map { [$0] } ?? []) + meanwhile).joined(separator: "\n"))
    }

    /// Tells the model something that happened meanwhile, which the user learnt elsewhere: a task handed to an agent
    /// ended, and a notification told them (`AgentPhrases.historyNote`), never the voice. It goes with the next message
    /// of the user's role (`nextUserMessage`, `nextNoteMessage`), after their words (`ToolContext.userSaid` reads its
    /// first line), and stays in the history with it, until that message is recorded (`record`): a message made before
    /// it came, for a turn already under way, goes without it, and the note waits for the next one.
    ///
    /// Without it, the history ended with the task handed over (« C’est parti : tu auras une notification quand ce sera
    /// fini. »): asked for the same work again after the notification, Gemma 4 26B answered « C'est déjà en cours. Je te
    /// préviens dès que Claude Code a terminé son travail. », without a call. In voice-cli dialogue-bench
    /// (Tests/Fixtures/agents-dialogues-fr.json), where that request must then be handed over again or answered with the
    /// task over: without the note, 7, 8 and 10 times out of 10 on Gemma 4 26B, E4B and E2B; with it, 10, 8 and 10 (the
    /// 26B and E2B ask etat_taches, then say the task is over). E4B stays near 85 % whatever the note's place or words
    /// (17 of 20 after the user's words, 35 of 40 before them, 15 of 20 as the app's own message read just before
    /// theirs): it then answers the note rather than the request (« J'ai bien compris la situation. »). A sentence in the
    /// note on how to do the work again made it take the note for the user's words (« Je vois que tu veux refaire cette
    /// tâche… », 8 of 20), and a rule in the prompt did not help (15 of 20).
    public mutating func noteForNextMessage(_ note: String) {
        meanwhile.append(note)
    }

    /// Messages to send for a new user turn (history is not modified: the turn may be speculative).
    public func messages(addingUser text: String, language: SpeechLanguage) -> [ChatMessage] {
        messages(adding: nextUserMessage(text, language: language))
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
        record(user: nextUserMessage(text, language: language), steps: [], assistant: answer, interrupted: interrupted)
    }

    /// Records an exchange with the tool calls made on the way (`steps`: call, result, possibly a second try).
    /// `interrupted`: the user cut the answer off, as far as `answer` goes (`Ending.cutOff`).
    public mutating func record(user message: ChatMessage, steps: [ChatMessage], assistant answer: String,
                                interrupted: Bool)
    {
        record(user: message, steps: steps, assistant: answer, ending: interrupted ? .cutOff : .whole)
    }

    /// Records an exchange with the tool calls made on the way (`steps`), and how its answer ended. An answer cut off or
    /// cut by a drop goes as far as `answer` goes, and its note says so, so that the model does not take it for one the
    /// user heard to its end: right after it (`cutOffMessage`, `dropMessage`), or in the next message
    /// (`cutOffPlacement`).
    public mutating func record(user message: ChatMessage, steps: [ChatMessage], assistant answer: String,
                                ending: Ending)
    {
        exchanges.append(message)
        meanwhile.removeAll { message.content.contains($0) }  // told with this message; the others wait for the next
        exchanges += steps
        exchanges.append(ChatMessage(.assistant, answer))
        switch cutOffPlacement {
        case .ahead:
            if let note = ending.note { exchanges.append(ChatMessage(.system, note)) }
            dueNote = nil
        case .afterUserWords:
            dueNote = ending.note
        }
    }

    /// Drops the oldest exchange: a user message and everything up to the next one (the note after its answer, when it
    /// was cut off or cut by a drop and the note read ahead). Returns false when nothing is left to drop. A note on the
    /// next message about that exchange's answer goes with it.
    @discardableResult
    public mutating func dropOldestExchange() -> Bool {
        guard exchanges.count >= 2 else { return false }
        let next = exchanges.dropFirst().firstIndex { $0.role == .user } ?? exchanges.endIndex
        exchanges.removeSubrange(..<next)
        if var first = exchanges.first, first.role == .user, let note = Self.noteRange(in: first.content) {
            first.content.removeSubrange(note)
            exchanges[0] = first
        }
        if exchanges.isEmpty { dueNote = nil }
        return true
    }

    /// Where a note about the answer before (`cutOffNote`, `dropNote`) is in a user's message, with the line break before
    /// it.
    private static func noteRange(in content: String) -> Range<String.Index>? {
        if let range = content.range(of: "\n" + cutOffNote) { return range }
        guard let start = content.range(of: "\n" + dropNotePrefix) else { return nil }
        let end = content[start.upperBound...].firstIndex(of: "\n") ?? content.endIndex
        return start.lowerBound..<end
    }

    /// Drops the `count` oldest exchanges.
    public mutating func dropOldestExchanges(_ count: Int) {
        for _ in 0..<count {
            guard dropOldestExchange() else { return }
        }
    }

    public mutating func clear() {
        exchanges.removeAll()
        dueNote = nil
        meanwhile.removeAll()
    }
}
