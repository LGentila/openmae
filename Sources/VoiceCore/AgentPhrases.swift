import Foundation

/// What the app says about the tasks handed to agents, and the notifications at their end. Same rules as
/// ActionPhrases: French (and English for conversations in English), "tu", non-breaking spaces before « : ? ! » and
/// inside guillemets, typographic apostrophes, and at least five words per sentence (the voice renders shorter texts
/// as silence) — which is why the questions are one sentence: "Je confie « … » à Claude Code, on y va ?".
public enum AgentPhrases {
    private static let nb = "\u{00A0}"

    private static func quoted(_ text: String, _ language: SpeechLanguage) -> String {
        language == .french ? "«\(nb)\(text)\(nb)»" : "“\(text)”"
    }

    // MARK: - Handing a task over

    /// The read-back before the "oui".
    public static func review(agent: String, title: String, folder: String?, _ language: SpeechLanguage) -> String {
        switch language {
        case .french:
            let place = folder.map { ", dans le dossier \($0)," } ?? ","
            return "Je confie \(quoted(title, language)) à \(agent)\(place) on y va\(nb)?"
        case .english:
            let place = folder.map { ", in the \($0) folder," } ?? ","
            return "I’ll hand \(quoted(title, language)) to \(agent)\(place) shall I go ahead?"
        }
    }

    public static func started(_ language: SpeechLanguage) -> String {
        language == .french ? "C’est parti\(nb): tu auras une notification quand ce sera fini."
            : "It’s started: you’ll get a notification when it’s done."
    }

    public static func followUpReview(agent: String, title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "J’ajoute ta demande à \(quoted(title, language)) pour \(agent), on y va\(nb)?"
            : "I’ll add this to \(quoted(title, language)) for \(agent), shall I go ahead?"
    }

    public static func followUpSent(agent: String, title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "C’est envoyé\(nb): \(agent) reprend \(quoted(title, language))."
            : "Sent: \(agent) is picking up \(quoted(title, language)) again."
    }

    public static func followUpQueued(agent: String, _ language: SpeechLanguage) -> String {
        language == .french ? "C’est noté\(nb): \(agent) le recevra dès qu’il aura fini ce qu’il fait."
            : "Noted: \(agent) will get it as soon as it finishes what it’s doing."
    }

    public static func cancelReview(agent: String, title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "J’arrête \(quoted(title, language)) chez \(agent), on y va\(nb)?"
            : "I’ll stop \(quoted(title, language)) at \(agent), shall I go ahead?"
    }

    public static func cancelled(agent: String, title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "C’est fait, \(agent) a arrêté \(quoted(title, language))."
            : "Done, \(agent) stopped \(quoted(title, language))."
    }

    /// "annule" right after a task was handed over.
    public static func undone(agent: String, _ language: SpeechLanguage) -> String {
        language == .french ? "C’est annulé, j’ai arrêté la tâche de \(agent)."
            : "Cancelled, I stopped the task \(agent) was doing."
    }

    /// A task stopped by « annule » after a request that did several things (`ActionPhrases.undone`).
    public static func undoneName(agent: String, _ language: SpeechLanguage) -> String {
        language == .french ? "la tâche de \(agent)" : "the \(agent) task"
    }

    public static func alreadyOver(_ language: SpeechLanguage) -> String {
        language == .french ? "Cette tâche est déjà terminée, il n’y a rien à arrêter."
            : "That task is already over, there’s nothing to stop."
    }

    // MARK: - Where tasks stand

    public static func noTask(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai confié aucune tâche pour l’instant." : "I haven’t handed over any task yet."
    }

    public static func unknownTask(_ language: SpeechLanguage) -> String {
        language == .french ? "Je ne retrouve pas cette tâche. Tu peux me redire son nom\(nb)?"
            : "I can’t find that task. Can you tell me its name again?"
    }

    public static func running(agent: String, for seconds: TimeInterval, step: AgentStep?,
                               _ language: SpeechLanguage) -> String
    {
        let since = elapsed(seconds, language)
        switch language {
        case .french:
            return "\(agent) y travaille depuis \(since)" + (step.map { ", dernière étape\(nb): \(describe($0, language))" } ?? "") + "."
        case .english:
            return "\(agent) has been working on it for \(since)" + (step.map { ", latest step: \(describe($0, language))" } ?? "") + "."
        }
    }

    public static func severalRunning(agent: String, titles: [String], _ language: SpeechLanguage) -> String {
        let list = ActionPhrases.list(titles.map { quoted($0, language) }, language)
        let count = ActionPhrases.count(titles.count, feminine: true, english: language == .english)
        return language == .french ? "\(agent) travaille sur \(count) tâches\(nb): \(list)."
            : "\(agent) is working on \(count) tasks: \(list)."
    }

    /// Said when the model gives nothing to say about a finished task.
    public static func finished(agent: String, title: String, ago seconds: TimeInterval, _ language: SpeechLanguage) -> String {
        let ago = elapsed(seconds, language)
        return language == .french ? "\(agent) a fini \(quoted(title, language)) il y a \(ago)."
            : "\(agent) finished \(quoted(title, language)) \(ago) ago."
    }

    public static func failed(agent: String, title: String, _ failure: AgentTask.Failure?, _ language: SpeechLanguage) -> String {
        let task = quoted(title, language)
        switch (failure, language) {
        case (.notLoggedIn, .french): return "\(agent) n’a pas pu faire \(task)\(nb): il n’est pas connecté à ton compte."
        case (.notLoggedIn, .english): return "\(agent) couldn’t do \(task): it isn’t signed in to your account."
        case (.couldNotStart, .french): return "Je n’ai pas réussi à lancer \(agent) pour \(task)."
        case (.couldNotStart, .english): return "I couldn’t start \(agent) for \(task)."
        case (.stoppedWithoutResult, .french): return "\(agent) s’est arrêté sans finir \(task)."
        case (.stoppedWithoutResult, .english): return "\(agent) stopped without finishing \(task)."
        case (_, .french): return "\(agent) n’a pas pu finir \(task), tu trouveras son message dans l’historique."
        case (_, .english): return "\(agent) couldn’t finish \(task), its message is in the history."
        }
    }

    public static func stoppedByUser(title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "La tâche \(quoted(title, language)) a été arrêtée à ta demande."
            : "The task \(quoted(title, language)) was stopped at your request."
    }

    public static func interrupted(title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "La tâche \(quoted(title, language)) s’est arrêtée quand OpenMaé a été quitté."
            : "The task \(quoted(title, language)) stopped when OpenMaé was quit."
    }

    public static func awaitingYes(title: String, _ language: SpeechLanguage) -> String {
        language == .french ? "La tâche \(quoted(title, language)) attend encore ton oui."
            : "The task \(quoted(title, language)) is still waiting for your yes."
    }

    // MARK: - Problems

    public static func notInstalled(_ agent: String, _ language: SpeechLanguage) -> String {
        language == .french ? "\(agent) n’est pas installé sur ce Mac, je ne peux pas lui confier de tâche."
            : "\(agent) isn’t installed on this Mac, so I can’t hand it a task."
    }

    public static func notLoggedIn(_ agent: String, _ language: SpeechLanguage) -> String {
        language == .french
            ? "\(agent) n’est pas connecté à ton compte. Ouvre-le une fois dans le Terminal pour te connecter."
            : "\(agent) isn’t signed in to your account. Open it once in Terminal to sign in."
    }

    public static func notUnderstood(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas bien compris ce qu’il faut confier, tu peux préciser\(nb)?"
            : "I didn’t quite get what to hand over, can you tell me more?"
    }

    public static func unknownFolder(_ name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Je ne connais pas le dossier \(quoted(name, language)), tu peux me redire son nom\(nb)?"
            : "I don’t know the folder \(quoted(name, language)), can you tell me its name again?"
    }

    public static func couldNotStart(_ agent: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas réussi à lancer \(agent), tu peux réessayer\(nb)?"
            : "I couldn’t start \(agent), can you try again?"
    }

    // MARK: - Notifications

    /// The notification at the end of a task: its title and its text.
    public static func notification(for task: AgentTask) -> (title: String, body: String) {
        let language = task.language
        let french = language == .french
        let denials = task.permissionDenials.isEmpty ? "" : " " + notAllowed(task.permissionDenials, language)
        if task.status == .finished {
            let text = plainText(task.resultText ?? "")
            let first = text.isEmpty ? (french ? "Le résultat est dans le dossier de la tâche." : "The result is in the task’s folder.")
                : firstSentence(text)
            return (french ? "\(task.agentName) a fini\(nb): \(task.title)" : "\(task.agentName) is done: \(task.title)",
                    first + denials)
        }
        let reason: String = switch (task.failure, language) {
        case (.notLoggedIn, .french): "Il n’est pas connecté à ton compte\(nb): ouvre-le une fois dans le Terminal."
        case (.notLoggedIn, .english): "It isn’t signed in to your account: open it once in Terminal."
        case (.agent(let message), _): firstSentence(plainText(message))
        case (.couldNotStart, .french): "Sa commande n’a pas pu être lancée."
        case (.couldNotStart, .english): "Its command could not be started."
        case (_, .french): "Il s’est arrêté sans donner de résultat."
        case (_, .english): "It stopped without giving a result."
        }
        return (french ? "\(task.agentName) n’a pas pu finir\(nb): \(task.title)" : "\(task.agentName) couldn’t finish: \(task.title)",
                reason + denials)
    }

    /// For the conversation's history, with the user's next message (`Conversation.noteForNextMessage`): a task ended on
    /// its own and its notification told the user, so the model no longer takes it for one still running. Written for the
    /// model, in French like the other notes (a timer's, received information's), whatever the conversation's language.
    /// Its state only, never the agent's words: they come from outside, and the calls the model writes after the user's
    /// message are carried out; etat_taches gives them, to be summed up without any call carried out.
    public static func historyNote(for task: AgentTask) -> String {
        let ending = task.status == .finished ? "s'est terminée" : "s'est arrêtée sans aboutir"
        return "(Entre-temps, la tâche \(task.reference) « \(task.title) » confiée à \(task.agentName) \(ending) ; "
            + "l'utilisateur l'a appris par une notification.)"
    }

    /// "Pas autorisé sans ton accord : npm install."
    public static func notAllowed(_ denials: [String], _ language: SpeechLanguage) -> String {
        let list = denials.prefix(3).joined(separator: ", ") + (denials.count > 3 ? "…" : "")
        return language == .french ? "Pas autorisé sans ton accord\(nb): \(list)." : "Not allowed without your OK: \(list)."
    }

    // MARK: - Helpers

    /// "moins d’une minute", "12 minutes", "1 heure et 5 minutes".
    static func elapsed(_ seconds: TimeInterval, _ language: SpeechLanguage) -> String {
        let minutes = Int(max(0, seconds) / 60)
        guard minutes >= 1 else { return language == .french ? "moins d’une minute" : "less than a minute" }
        return ActionPhrases.duration(seconds: minutes * 60, language)
    }

    /// What an agent is doing, as a few words that follow "dernière étape :".
    public static func describe(_ step: AgentStep, _ language: SpeechLanguage) -> String {
        let french = language == .french
        switch step {
        case .creates(let file): return french ? "création de \(file)" : "creating \(file)"
        case .edits(let file): return french ? "modification de \(file)" : "editing \(file)"
        case .reads(let file): return french ? "lecture de \(file)" : "reading \(file)"
        case .runsCommand: return french ? "une commande dans le terminal" : "a command in the terminal"
        case .searchesFiles: return french ? "une recherche dans les fichiers" : "a search through the files"
        case .browsesWeb: return french ? "une recherche sur le web" : "a search on the web"
        case .step(let text):
            // "Création de la page" → "création de la page", but "API REST" stays as it is.
            guard let first = text.first, first.isUppercase, text.dropFirst().first?.isLowercase == true else { return text }
            return first.lowercased() + text.dropFirst()
        }
    }

    /// An agent's message without its Markdown: no code marks, emphasis, headings or list bullets.
    public static func plainText(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var l = line.trimmingCharacters(in: .whitespaces)
            l = l.replacingOccurrences(of: #"^(#{1,6}|[-*+•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
            if !l.isEmpty { lines.append(l) }
        }
        return lines.joined(separator: " ")
    }

    /// The first sentence, at most about 180 characters.
    static func firstSentence(_ text: String) -> String {
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?…".contains(text[index]), next == text.endIndex || text[next] == " " {
                end = next
                break
            }
            index = next
        }
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespaces)
        guard sentence.count > 180 else { return sentence }
        let cut = sentence.prefix(180)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
}
