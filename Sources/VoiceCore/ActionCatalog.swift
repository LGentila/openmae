import Foundation

/// The built-in tools, as the model sees them, and the checks that need no access to the user's data.
/// The providers that carry them out (EventKit, the Shortcuts app) live in VoiceEngineApple; the timers are
/// in TimerTools.swift. The benchmark (`voice-cli actions-bench`) uses these same descriptions.
///
/// Names, descriptions and the prompt are written in French on purpose, like the system prompt: the model
/// follows the language of its instructions.
public enum ActionCatalog {
    // MARK: - The system prompt's part

    /// Appended to the system prompt when actions are on. In short: use a tool only for a clear request to
    /// create, read or change something; dates are local ISO, computed from the date line at the end of each
    /// user message (added by the app, never to be copied into answers); ask when the hour is ambiguous (1 to 7 o'clock) or something essential is missing; write
    /// nothing besides the call (the app confirms); never pretend an action was done without a call.
    public static let promptAddendum = """
        Tu peux agir grâce à des outils : rappels, calendrier, minuteurs et raccourcis. \
        Appelle un outil seulement quand l'utilisateur demande clairement de créer, de lire ou de modifier \
        quelque chose ; une question générale, un souvenir ou une remarque n'en demandent pas. \
        Chaque message de l'utilisateur se termine par la date et l'heure actuelles, entre parenthèses, \
        ajoutées par l'app : sers-t'en pour calculer les dates des outils, au format AAAA-MM-JJTHH:MM en heure \
        locale, mais ne les recopie jamais dans tes réponses. \
        Si l'heure est ambiguë, par exemple « à 3 h » sans préciser le matin ou l'après-midi, \
        ou s'il manque une information indispensable, pose d'abord une question courte. \
        Quand tu appelles un outil, n'écris rien d'autre : c'est l'app qui confirme à voix haute. \
        Ne dis jamais qu'une action est faite sans avoir appelé l'outil.
        """

    /// The line that ends every user message when actions are on, e.g.
    /// "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)". It stays in the history.
    public static func dateLine(_ now: Date, timeZone: TimeZone = .current) -> String {
        let context = ToolContext(now: now, timeZone: timeZone, language: .french)
        let c = context.calendar.dateComponents([.year, .hour, .minute], from: now)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let day = ActionPhrases.day(now, context)
        return "(Nous sommes le \(day) \(c.year ?? 0), il est \(time).)"
    }

    // MARK: - Reminders and calendar

    public static let createReminder = ToolSpec(
        name: "creer_rappel",
        description: "Crée un rappel dans l'app Rappels, quand l'utilisateur demande qu'on lui rappelle quelque chose "
            + "ou de noter une chose à faire.",
        parameters: [
            ToolParameter("titre", .string, "Ce qu'il faut faire, court, sans « rappelle-moi de ».", required: true),
            ToolParameter("echeance", .string, "Quand le rappeler : AAAA-MM-JJTHH:MM, ou AAAA-MM-JJ pour un jour "
                          + "sans heure. Absent si aucun moment n'est donné."),
            ToolParameter("liste", .string, "Nom de la liste, seulement si l'utilisateur en nomme une."),
        ],
        risk: .undoable)

    public static let listReminders = ToolSpec(
        name: "lister_rappels",
        description: "Dit les rappels pas encore faits, pour une période ou en tout.",
        parameters: [
            ToolParameter("debut", .string, "Début de la période : AAAA-MM-JJTHH:MM. Absent pour tous les rappels."),
            ToolParameter("fin", .string, "Fin de la période : AAAA-MM-JJTHH:MM."),
        ],
        risk: .read)

    public static let createEvent = ToolSpec(
        name: "creer_evenement",
        description: "Ajoute un événement au calendrier : rendez-vous, réunion, sortie, anniversaire…",
        parameters: [
            ToolParameter("titre", .string, "Nom de l'événement, court.", required: true),
            ToolParameter("debut", .string, "Début : AAAA-MM-JJTHH:MM, ou AAAA-MM-JJ pour toute la journée.",
                          required: true),
            ToolParameter("fin", .string, "Fin : AAAA-MM-JJTHH:MM, seulement si l'utilisateur la donne."),
            ToolParameter("duree_minutes", .integer, "Durée en minutes si elle est donnée (60 par défaut)."),
            ToolParameter("lieu", .string, "Lieu, s'il est donné."),
            ToolParameter("calendrier", .string, "Nom du calendrier, seulement si l'utilisateur en nomme un."),
            ToolParameter("journee_entiere", .boolean, "Vrai pour un événement sur toute la journée."),
        ],
        risk: .undoable)

    public static let readAgenda = ToolSpec(
        name: "lire_agenda",
        description: "Lit les événements du calendrier sur une période, par exemple « qu'est-ce que j'ai demain ? ».",
        parameters: [
            ToolParameter("debut", .string, "Début de la période : AAAA-MM-JJTHH:MM.", required: true),
            ToolParameter("fin", .string, "Fin de la période : AAAA-MM-JJTHH:MM.", required: true),
        ],
        risk: .read)

    public static let changeItem = ToolSpec(
        name: "modifier_element",
        description: "Modifie un rappel ou un événement créé plus tôt dans cette conversation : le décaler, le "
            + "renommer, changer sa durée ou son lieu.",
        parameters: [
            ToolParameter("reference", .string, "« dernier » pour le dernier élément créé, ou son identifiant "
                          + "donné par l'outil (par exemple e1 ou r2).", required: true),
            ToolParameter("titre", .string, "Nouveau nom."),
            ToolParameter("debut", .string, "Nouveau début d'un événement : AAAA-MM-JJTHH:MM."),
            ToolParameter("fin", .string, "Nouvelle fin d'un événement : AAAA-MM-JJTHH:MM."),
            ToolParameter("duree_minutes", .integer, "Nouvelle durée d'un événement, en minutes."),
            ToolParameter("echeance", .string, "Nouveau moment d'un rappel : AAAA-MM-JJTHH:MM."),
            ToolParameter("lieu", .string, "Nouveau lieu d'un événement."),
        ],
        risk: .undoable)

    public static let deleteItem = ToolSpec(
        name: "supprimer_element",
        description: "Supprime un rappel ou un événement créé plus tôt dans cette conversation.",
        parameters: [
            ToolParameter("reference", .string, "« dernier » pour le dernier élément créé, ou son identifiant "
                          + "donné par l'outil (par exemple e1 ou r2).", required: true),
        ],
        risk: .undoable)

    public static let calendarTools = [createReminder, listReminders, createEvent, readAgenda, changeItem, deleteItem]

    // MARK: - Timers and shortcuts

    public static let timer = ToolSpec(
        name: "minuteur",
        description: "Lance un minuteur, un compte à rebours qui sonne à la fin.",
        parameters: [
            ToolParameter("duree_secondes", .integer, "Durée en secondes.", required: true),
            ToolParameter("libelle", .string, "À quoi il sert, court (par exemple « les pâtes »), s'il est dit."),
        ],
        risk: .undoable)

    /// Shortcuts of the "OpenMaé" folder of the Shortcuts app; nil when there is none.
    public static func runShortcut(names: [String]) -> ToolSpec? {
        guard !names.isEmpty else { return nil }
        return ToolSpec(
            name: "lancer_raccourci",
            description: "Lance un raccourci de l'app Raccourcis, parmi ceux de la liste.",
            parameters: [
                ToolParameter("nom", .oneOf(names), "Nom exact du raccourci.", required: true),
                ToolParameter("entree", .string, "Texte à lui donner, seulement s'il en faut un."),
            ],
            risk: .undoable)
    }

    // MARK: - Checks shared by the app and the benchmark

    /// A non-empty title, or a refusal.
    public static func title(_ call: ToolCall, _ key: String = "titre", context: ToolContext) throws -> String {
        guard let title = call.text(key) else {
            throw ToolRefusal(forModel: "Il manque « \(key) ».", spoken: ActionPhrases.missingTitle(context.language))
        }
        return title
    }

    /// The event a `creer_evenement` call describes: start, end, all day.
    public static func eventTimes(_ call: ToolCall, context: ToolContext)
        throws -> (start: Date, end: Date, allDay: Bool)
    {
        guard let start = try DateCheck.upcoming(call, "debut", context: context, required: true) else {
            throw DateCheck.refusal(.missing, key: "debut", context: context)
        }
        let allDay = call.arguments["journee_entiere"]?.boolean == true || !start.hasTime
        let calendar = context.calendar
        if allDay {
            let day = calendar.startOfDay(for: start.date)
            var end = calendar.date(byAdding: .day, value: 1, to: day)!
            if let last = try DateCheck.any(call, "fin", context: context, required: false), last.date > day {
                end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last.date))!
            }
            return (day, end, true)
        }
        var end = start.date.addingTimeInterval(TimeInterval(60 * 60))
        if let minutes = call.arguments["duree_minutes"]?.integer {
            guard (1...(60 * 24 * 14)).contains(minutes) else {
                throw ToolRefusal(forModel: "« duree_minutes » doit être entre 1 et 20160.",
                                  spoken: ActionPhrases.badDuration(context.language))
            }
            end = start.date.addingTimeInterval(TimeInterval(minutes * 60))
        }
        if let fin = try DateCheck.any(call, "fin", context: context, required: false) {
            // "fin" without a day the model may give as the same day; a time alone is not accepted by the format.
            guard fin.date > start.date else {
                throw ToolRefusal(forModel: "« fin » doit être après « debut ».",
                                  spoken: ActionPhrases.badTime(context.language))
            }
            end = fin.date
        }
        return (start.date, end, false)
    }

    /// The period a reading covers. Without dates (reminders only): nil.
    public static func period(_ call: ToolCall, context: ToolContext, required: Bool) throws -> (Date, Date)? {
        let start = try DateCheck.any(call, "debut", context: context, required: required)
        let end = try DateCheck.any(call, "fin", context: context, required: required)
        guard let start else {
            // "fin" alone: from now on.
            guard let end else { return nil }
            return (context.now, endOfPeriod(end, context))
        }
        let calendar = context.calendar
        let from = start.hasTime ? start.date : calendar.startOfDay(for: start.date)
        guard let end else {
            // A start alone: that day.
            return (from, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from))!)
        }
        let to = endOfPeriod(end, context)
        guard to > from else {
            throw ToolRefusal(forModel: "« fin » doit être après « debut ».", spoken: ActionPhrases.badTime(context.language))
        }
        guard to.timeIntervalSince(from) <= 92 * 24 * 3600 else {
            throw ToolRefusal(forModel: "La période ne peut pas dépasser trois mois.",
                              spoken: ActionPhrases.badTime(context.language))
        }
        return (from, to)
    }

    /// A day alone, or 23:59, means the end of that day.
    private static func endOfPeriod(_ end: (date: Date, hasTime: Bool), _ context: ToolContext) -> Date {
        let calendar = context.calendar
        let c = calendar.dateComponents([.hour, .minute], from: end.date)
        if !end.hasTime || (c.hour == 23 && c.minute == 59) {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end.date))!
        }
        return end.date
    }

    /// The length of a `minuteur` call, in seconds (1 second to 24 hours).
    public static func timerSeconds(_ call: ToolCall, context: ToolContext) throws -> Int {
        guard let seconds = call.arguments["duree_secondes"]?.integer, (1...(24 * 3600)).contains(seconds) else {
            throw ToolRefusal(forModel: "« duree_secondes » doit être un nombre entier de secondes, entre 1 et 86400.",
                              spoken: ActionPhrases.badDuration(context.language))
        }
        return seconds
    }

    /// Checks a call against the static rules (the benchmark's "would the app accept it").
    public static func check(_ call: ToolCall, context: ToolContext, shortcuts: [String] = []) throws {
        switch call.name {
        case createReminder.name:
            _ = try title(call, context: context)
            _ = try DateCheck.upcoming(call, "echeance", context: context, required: false)
        case listReminders.name:
            _ = try period(call, context: context, required: false)
        case createEvent.name:
            _ = try title(call, context: context)
            _ = try eventTimes(call, context: context)
        case readAgenda.name:
            _ = try period(call, context: context, required: true)
        case changeItem.name:
            guard call.text("reference") != nil else {
                throw ToolRefusal(forModel: "Il manque « reference ».", spoken: ActionPhrases.nothingToChange(context.language))
            }
            _ = try DateCheck.upcoming(call, "debut", context: context, required: false)
            _ = try DateCheck.upcoming(call, "echeance", context: context, required: false)
        case deleteItem.name:
            guard call.text("reference") != nil else {
                throw ToolRefusal(forModel: "Il manque « reference ».", spoken: ActionPhrases.nothingToChange(context.language))
            }
        case timer.name:
            _ = try timerSeconds(call, context: context)
        case "lancer_raccourci":
            let name = call.text("nom") ?? ""
            guard shortcuts.contains(name) else {
                throw ToolRefusal(forModel: "Raccourci inconnu : « \(name) ».",
                                  spoken: ActionPhrases.unknownShortcut(name, context.language))
            }
        default:
            throw ToolRefusal(forModel: "Outil inconnu : \(call.name).", spoken: ActionPhrases.notUnderstood(context.language))
        }
    }
}
