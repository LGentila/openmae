import Foundation

/// The built-in tools, as the model sees them, and the checks that need no access to the user's data.
/// The providers that carry them out (EventKit, the Shortcuts app) live in VoiceEngineApple; the timers are
/// in TimerTools.swift. The benchmark (`voice-cli actions-bench`) uses these same descriptions.
///
/// Names, descriptions and the prompt are written in French on purpose, like the system prompt: the model
/// follows the language of its instructions.
///
/// Moments and lengths are never computed by the model: it copies the user's words ("samedi à 20 h", "une heure
/// et quart") into `quand` and `duree`, and the app works out the date (`FrenchDates`). A date the model writes
/// itself (ISO) is still read.
public enum ActionCatalog {
    // MARK: - The system prompt's part

    /// Appended to the system prompt when actions are on. In short: use a tool only when the user clearly asks
    /// for something to be done now (create, read or change), never for a question (even about what the
    /// assistant can do), a memory, a taste or a remark; for a moment or a length, copy the user's words without
    /// computing anything (the app does); the date line at the end of each user message (added by the app) is
    /// never to be copied, into a tool or an answer; ask when something essential is missing; for an action, say
    /// nothing before the call, not even the short opening sentence the main prompt asks for (the app confirms
    /// aloud); never pretend an action was done without a call. Then, when the model can write one
    /// (`LanguageModel.toolCallText`), a whole answer that is a call, for `example`.
    ///
    /// The exception to the opening sentence and the example are for the smaller models: without them they
    /// announce the action ("Je crée ton rendez-vous…") and stop there, without calling the tool. An hour that may
    /// be the morning or the afternoon ("à 3 h") is asked about by the app, and so is a moment already gone
    /// (`DateCheck`). Gemma 4 E4B sometimes refuses such a moment itself, without a call ("Je ne peux pas ajouter un
    /// événement passé.": 10 to 14 % of the time on the dentist of voice-cli dialogue-bench). A rule saying that the
    /// app checks the dates, and to write the call even for a moment that seems gone, brought that down to 3 to 5 %,
    /// but made E4B call tools for remarks too (« Demain, je vais au marché avec ma sœur » at 59 % instead of 34 %):
    /// left out.
    public static func promptAddendum(exampleCall: String?) -> String {
        let rules = """
            Tu peux agir grâce à des outils : rappels, calendrier, minuteurs et raccourcis. \
            Appelle un outil seulement quand l'utilisateur te demande clairement de faire quelque chose \
            maintenant : créer, lire ou modifier ; une question (même sur ce que tu sais faire), un souvenir, \
            un goût ou une remarque n'en demandent pas. \
            Pour un moment ou une durée, ne calcule rien : recopie les mots exacts de l'utilisateur \
            (« samedi soir », « dans 10 minutes »), c'est l'app qui calcule les dates. \
            \(dateLineRule) \
            S'il manque une information indispensable, pose d'abord une question courte ; \
            pour lire les rappels, rien ne manque : sans période, l'app les lit tous. \
            Pour une action, ne dis rien avant l'appel, pas même la première phrase courte : ta réponse commence \
            directement par l'appel de l'outil, et c'est l'app qui confirme à voix haute. \
            Ne dis jamais qu'une action est faite sans avoir appelé l'outil.
            """
        guard let exampleCall else { return rules }
        return rules + " Exemple : à « \(example.request) », ta réponse entière est \(exampleCall)"
    }

    /// The request and the call the prompt shows as an example: a timer, which is always there and has no date
    /// the model could copy.
    public static let example = (request: "Mets un minuteur de 5 minutes pour le thé",
                                 call: ToolCall(name: "minuteur", arguments: ["duree": "5 minutes", "libelle": "le thé"]))

    /// Whether conversations on this tier start with `examples`. Gemma 4 E2B (minimum) needs them: on its own it
    /// answers "Je note votre rendez-vous" without calling anything (9 to 13 requests right out of 66 in
    /// `voice-cli actions-bench`), with them 61 to 63. E4B (standard) does better without them (65 or 66, against 60
    /// to 62: it asks more questions), and the larger models do not need them. The price, on E2B: asked what was said
    /// or done earlier, it tells the examples as if they had happened; no instruction tried stopped that.
    public static func showsExamples(on tier: HardwareTier) -> Bool { tier == .minimum }

    /// The most actions carried out in one request on this tier (the user asked for several at once), in the order the
    /// model wrote their calls: 3 where the model writes them right (`voice-cli actions-bench` on
    /// Tests/Fixtures/actions-multi-fr.json: every action right in at least 90 % of the requests with several, no worse
    /// on the requests with one, at most one action too many on the ten that sound like two), 1 elsewhere, and on the
    /// tiers that could not be measured.
    public static func actionsPerRequest(on tier: HardwareTier) -> Int {
        switch tier {
        case .comfort: 3
        default: 1
        }
    }

    /// Four exchanges for the start of a conversation, as if they had happened: a timer, a reminder without a date,
    /// then an event asked for in a calendar the user names, at a moment the app cannot place (`vagueMoment`), and the
    /// user's answer. Each request gets its call at once, with the user's words, then its result and what was said:
    /// the app's sentence, or, after the event refused, the question of a second try about the day and the hour alone.
    /// At the answer, the event's call again, with the request's title and calendar. As the benchmark measured them: no
    /// date line in their messages. The event is on the Tuesday the app would choose at `now`, and the ids ("t0", "r0",
    /// "e0") are ones the app never gives: a call that refers to one of these items is refused, never taken for
    /// something of the user's.
    ///
    /// The event used to be asked for with its moment (« Ajoute un rendez-vous chez le kiné mardi à 18 h 15 »). Asked
    /// for an event at a moment the app cannot place (« Ajoute un rendez-vous chez le coiffeur après le travail. »),
    /// Gemma 4 E2B then wrote no call in 10 runs of 10 of voice-cli dialogue-bench: it asked about something the request
    /// already said (« Quel est le nom du coiffeur ? », « Quel est le nom de ton calendrier ? »), and again at the
    /// user's answer (« Demain à 18 h. »), so the appointment was saved in 0 to 2 runs of 10. With the event refused
    /// first, then created at the answer: 9 or 10 runs of 10 (the beginning grows from 1,847 to 2,070 tokens). Without a
    /// calendar named in that request, E2B also left out a calendar the user named after a reminder (« … dans mon
    /// calendrier Travail. »: 9 runs of 10). With every example of that kind tried, E2B leaves out the list of « Ajoute
    /// du pain à ma liste de courses. » (10 runs of 10, as E4B does in 4 to 6; it used to name it in 10): the app then
    /// finds the list in the user's words, when there is one of that name (`withCollectionSaid`). With the reminder
    /// example last, it named it, then named it again after « Mets-le dans tes rappels alors. » (7 runs of 10).
    public static func examples(now: Date, timeZone: TimeZone = .current) -> [ChatMessage] {
        let context = ToolContext(now: now, timeZone: timeZone, language: .french)
        var messages: [ChatMessage] = []
        func add(_ request: String, _ call: ToolCall, _ result: JSONValue, _ spoken: String) {
            messages += [Conversation.userMessage(request, language: .french), .call(call), .result(of: call, result),
                         ChatMessage(.assistant, spoken)]
        }
        add(example.request, example.call, ["id": "t0", "duree_secondes": 300, "libelle": "le thé"],
            ActionPhrases.timerStarted(seconds: 300, label: "le thé", .french))
        let reminder = ToolCall(name: createReminder.name, arguments: ["titre": "acheter du lait"])
        add("Rappelle-moi d'acheter du lait", reminder, ["id": "r0", "titre": "acheter du lait", "liste": "Rappels"],
            ActionPhrases.reminderCreated(title: "acheter du lait", due: nil, hasTime: false, listName: nil, context))
        let title = "Rendez-vous chez le kiné"
        let when = "mardi à 18 h 15"
        let calendarName = "Famille"
        if let start = try? FrenchDates.moment(when, now: now, calendar: context.calendar).start {
            let refused = ToolCall(name: createEvent.name, arguments: [
                "titre": .string(title), "quand": .string(vagueMoment), "calendrier": .string(calendarName),
            ])
            add("Ajoute un rendez-vous chez le kiné \(vagueMoment) dans mon calendrier \(calendarName)", refused,
                refusal(.notUnderstood, key: "quand", raw: vagueMoment, context: context).result(for: refused),
                "Quel jour et à quelle heure, pour ce rendez-vous\(ActionPhrases.nb)?")
            let end = start.addingTimeInterval(3600)
            let event = ToolCall(name: createEvent.name, arguments: [
                "titre": .string(title), "quand": .string(when), "calendrier": .string(calendarName),
            ])
            add(when.prefix(1).uppercased() + when.dropFirst() + ".", event,
                ["id": "e0", "titre": .string(title), "debut": .string(LocalDateTime.format(start, in: timeZone)),
                 "fin": .string(LocalDateTime.format(end, in: timeZone)), "calendrier": .string(calendarName)],
                ActionPhrases.eventCreated(title: title, start: start, end: end, allDay: false,
                                           calendarName: calendarName, context))
        }
        return messages
    }

    /// The moment of the examples' event request, which the app cannot place in time (`FrenchDates`).
    static let vagueMoment = "après la piscine"

    /// What the model is told of `dateLine`: part of the actions' prompt, and on its own when only the web search is on.
    public static let dateLineRule = "Chaque message de l'utilisateur se termine par la date et l'heure actuelles, entre "
        + "parenthèses, ajoutées par l'app : ne les recopie jamais, ni dans un outil ni dans tes réponses."

    /// The line that ends every user message when tools are on (actions or the web search), e.g.
    /// "(Nous sommes le jeudi 15 octobre 2026, il est 18:42.)". It stays in the history.
    public static func dateLine(_ now: Date, timeZone: TimeZone = .current) -> String {
        let context = ToolContext(now: now, timeZone: timeZone, language: .french)
        let c = context.calendar.dateComponents([.year, .hour, .minute], from: now)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let day = ActionPhrases.day(now, context)
        return "(Nous sommes le \(day) \(c.year ?? 0), il est \(time).)"
    }

    // MARK: - Reminders and calendar

    // The examples in the descriptions are not phrases of the benchmark's corpus: a model that copied one instead
    // of the user's words must not be counted right.

    public static let createReminder = ToolSpec(
        name: "creer_rappel",
        description: "Crée un rappel dans l'app Rappels, quand l'utilisateur demande qu'on lui rappelle quelque chose "
            + "ou de noter une chose à faire.",
        parameters: [
            ToolParameter("titre", .string, "Ce qu'il faut faire, court, sans « rappelle-moi de ».", required: true),
            ToolParameter("quand", .string, "Quand le rappeler, avec les mots exacts de l'utilisateur (par exemple "
                          + "« jeudi à 14 h 30 », « dans 2 heures »). Absent si aucun moment n'est donné."),
            ToolParameter("liste", .string, "Nom de la liste, seulement si l'utilisateur en nomme une."),
        ],
        risk: .undoable)

    public static let listReminders = ToolSpec(
        name: "lister_rappels",
        description: "Dit les rappels pas encore faits. Sans période, l'app les lit tous : n'en demande pas.",
        parameters: [
            ToolParameter("quand", .string, "La période, seulement si l'utilisateur en dit une, avec ses mots exacts "
                          + "(par exemple « ce week-end »). Absent sinon : l'app lit alors tous les rappels."),
        ],
        risk: .read)

    public static let createEvent = ToolSpec(
        name: "creer_evenement",
        description: "Ajoute un événement au calendrier : rendez-vous, réunion, sortie, anniversaire…",
        parameters: [
            ToolParameter("titre", .string, "Nom de l'événement, court.", required: true),
            ToolParameter("quand", .string, "Quand, avec les mots exacts de l'utilisateur, fin comprise si elle est "
                          + "dite (par exemple « jeudi à 14 h 30 », « lundi de 9 h à 11 h », « du 2 au 5 janvier »).",
                          required: true),
            ToolParameter("duree", .string, "La durée, avec les mots exacts de l'utilisateur (par exemple "
                          + "« 2 heures »), seulement si elle est dite."),
            ToolParameter("lieu", .string, "Lieu, s'il est donné."),
            ToolParameter("calendrier", .string, "Nom du calendrier, seulement si l'utilisateur en nomme un."),
        ],
        risk: .undoable)

    public static let readAgenda = ToolSpec(
        name: "lire_agenda",
        description: "Lit les événements du calendrier sur une période, par exemple « qu'est-ce que j'ai demain ? ».",
        parameters: [
            ToolParameter("quand", .string, "La période, avec les mots exacts de l'utilisateur (par exemple "
                          + "« ce week-end », « jeudi prochain »).", required: true),
        ],
        risk: .read)

    /// What a change gives besides the calendar and the list.
    private static let changeParameters = [
        ToolParameter("reference", .string, "« dernier » pour le dernier élément créé, ou son identifiant "
                      + "donné par l'outil (par exemple e1 ou r2).", required: true),
        ToolParameter("titre", .string, "Nouveau nom."),
        ToolParameter("quand", .string, "Nouveau moment, avec les mots exacts de l'utilisateur (par exemple "
                      + "« à 10 h », « lundi à la même heure », « une heure plus tard »)."),
        ToolParameter("duree", .string, "Nouvelle durée d'un événement, avec les mots exacts de l'utilisateur."),
        ToolParameter("lieu", .string, "Nouveau lieu d'un événement."),
    ]

    /// `modifier_element` on the tiers that do not move items (`movesItems(on:)`): a new title, moment, length or place.
    public static let changeItem = ToolSpec(
        name: "modifier_element",
        description: "Modifie un rappel ou un événement créé plus tôt dans cette conversation : le décaler, le "
            + "renommer, changer sa durée ou son lieu.",
        parameters: changeParameters,
        risk: .undoable)

    /// `modifier_element` on the tiers that move items to another calendar or list. Its calendar and its list are two
    /// words, as in the creations (`creer_evenement`'s « calendrier », `creer_rappel`'s « liste »): the model writes the
    /// word it already writes for the same thing, and Gemma 4 26B wrote « calendrier » for an event's even before the
    /// change had it. Either word is read for either kind of item (`collectionNamed`), as the model may still write the
    /// other one.
    public static let changeItemMoving = ToolSpec(
        name: changeItem.name,
        description: "Modifie un rappel ou un événement créé plus tôt dans cette conversation : le décaler, le "
            + "renommer, changer sa durée, son lieu, son calendrier ou sa liste.",
        parameters: changeParameters + [
            ToolParameter("calendrier", .string, "Nouveau calendrier d'un événement, seulement si l'utilisateur en "
                          + "nomme un."),
            ToolParameter("liste", .string, "Nouvelle liste d'un rappel, seulement si l'utilisateur en nomme une."),
        ],
        risk: .undoable)

    /// Whether `modifier_element` offers a calendar and a list, to move an item, on this tier: on Gemma 4 26B (comfort,
    /// max) only. Every wording tried made Gemma 4 E4B (standard) readier to call a tool for a remark, in
    /// `voice-cli actions-bench --watch-calls` (the chance of a call at the first token, which does not depend on the
    /// sampling): 3.4 % on average without them, 3.7 to 5.6 % with both or with one word for both, « Demain, je vais au
    /// marché avec ma sœur » 31 % against 44 to 75 %. On E2B (minimum), the two made it write again a reminder refused
    /// for its missing list (dialogue-bench's « a shopping list that does not exist »: 13 runs of 20 right, against 19 or
    /// 20 without them and 18 or 19 with one word). The 26B did as well with them as without.
    /// A calendar or a list the model writes all the same in a change is applied on every tier (`collectionNamed`), as
    /// other words it may write are read.
    public static func movesItems(on tier: HardwareTier) -> Bool { tier == .comfort || tier == .max }

    /// The reminders' and calendar's tools for this tier's model.
    public static func calendarTools(on tier: HardwareTier) -> [ToolSpec] { calendarTools(movingItems: movesItems(on: tier)) }

    /// The reminders' and calendar's tools, `modifier_element` with a calendar and a list or without (`movesItems(on:)`).
    public static func calendarTools(movingItems: Bool) -> [ToolSpec] {
        [createReminder, listReminders, createEvent, readAgenda, movingItems ? changeItemMoving : changeItem, deleteItem]
    }

    public static let deleteItem = ToolSpec(
        name: "supprimer_element",
        description: "Supprime un rappel ou un événement créé plus tôt dans cette conversation.",
        parameters: [
            ToolParameter("reference", .string, "« dernier » pour le dernier élément créé, ou son identifiant "
                          + "donné par l'outil (par exemple e1 ou r2).", required: true),
        ],
        risk: .undoable)

    /// Whether the `reference` of a change or a deletion is the last item created: « dernier », as the tools'
    /// descriptions say, or as the model may also write it.
    public static func meansLastItem(_ reference: String) -> Bool {
        ["dernier", "last", "derniere", "dernière"].contains(reference.lowercased())
    }

    // MARK: - Changes, shared by the providers (`CalendarTools`, and voice-cli's calendar in memory)

    /// What a `modifier_element` call can give besides its reference (with the words the model may still write): a
    /// call that gives none of them changes nothing.
    static let changeKeys = ["titre", "quand", "debut", "echeance", "fin", "duree", "duree_minutes", "lieu",
                             "calendrier", "liste"]

    /// An event or a reminder as saved, as a change sees it.
    public struct SavedItem: Equatable, Sendable {
        public var isEvent: Bool
        public var title: String
        /// An event's start, a reminder's due date (nil: none).
        public var date: Date?
        /// An event's end.
        public var end: Date?
        /// An event at a time (not for the whole day), a reminder due at a time.
        public var hasTime: Bool
        /// An event's place.
        public var place: String?
        /// Its calendar (an event's) or its list (a reminder's): what tells them apart for the provider (EventKit's
        /// identifier; the name for voice-cli's calendar in memory).
        public var collection: String

        public init(isEvent: Bool, title: String, date: Date?, end: Date? = nil, hasTime: Bool, place: String? = nil,
                    collection: String)
        {
            self.isEvent = isEvent
            self.title = title
            self.date = date
            self.end = end
            self.hasTime = hasTime
            self.place = place
            self.collection = collection
        }

        /// Whether a change moved it in time (not only its end).
        public func moved(from before: SavedItem) -> Bool { date != before.date || hasTime != before.hasTime }
    }

    /// The calendar (`event`) or the list a change names: the word of its kind of item, or the other one, as the model
    /// may write it ("calendrier" for a reminder's list).
    public static func collectionNamed(in call: ToolCall, event: Bool) -> String? {
        event ? call.text("calendrier") ?? call.text("liste") : call.text("liste") ?? call.text("calendrier")
    }

    /// Where among `names` (the calendars or the lists an item can go in) a name the model gave is, whatever the case and
    /// accents: the one of that name, else one whose name contains it or is contained in it; at the same rank, the
    /// item's own (`current`), which a change then leaves where it is. nil when none fits.
    public static func collectionIndex(named name: String, among names: [String], current: Int? = nil) -> Int? {
        let key = folded(name)
        guard !key.isEmpty else { return nil }
        let keys = names.map(folded)
        func fitting(_ fits: (String) -> Bool) -> Int? {
            if let current, keys.indices.contains(current), fits(keys[current]) { return current }
            return keys.firstIndex(where: fits)
        }
        return fitting { $0 == key } ?? fitting { !$0.isEmpty && ($0.contains(key) || key.contains($0)) }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A calendar (`event`) or a list that does not exist: the model reads the ones there are (`names`), the user is
    /// asked. For a creation, the answer gives that name again (`ToolRefusal.detailGivenAgain`).
    public static func unknownCollection(_ name: String, event: Bool, names: [String], context: ToolContext) -> ToolRefusal {
        var refusal = event
            ? ToolRefusal(forModel: "Aucun calendrier modifiable ne s'appelle « \(name) ». Calendriers : "
                              + names.joined(separator: ", ") + ".",
                          spoken: ActionPhrases.unknownCalendar(name, context.language))
            : ToolRefusal(forModel: "Aucune liste de rappels ne s'appelle « \(name) ». Listes : "
                              + names.joined(separator: ", ") + ".",
                          spoken: ActionPhrases.unknownList(name, context.language))
        refusal.detailGivenAgain = true
        return refusal
    }

    /// What a `modifier_element` call makes of `item`: a new title; a new moment, length or place for an event, a new
    /// due date for a reminder (the dates as `changedEvent` and `changedDue` read them); `collection`, the calendar or
    /// the list it names (as the provider found it). Refused when that changes nothing: what the call gives is already
    /// the item's, or does not apply to it (a place for a reminder), so that the app never says « C'est modifié » of an
    /// item it left as it was. `reference`: the item's, for the model.
    public static func changed(_ item: SavedItem, by call: ToolCall, collection: String?, reference: String,
                               context: ToolContext) throws -> SavedItem
    {
        var changed = item
        if let title = call.text("titre") { changed.title = title }
        if let collection { changed.collection = collection }
        if item.isEvent {
            if let place = call.text("lieu") { changed.place = place }
            let start = item.date ?? context.now
            if let times = try changedEvent(call, start: start, end: item.end ?? start.addingTimeInterval(3600),
                                            allDay: !item.hasTime, context: context)
            {
                (changed.date, changed.end, changed.hasTime) = (times.start, times.end, !times.allDay)
            }
        } else if let due = try changedDue(call, due: item.date.map { ($0, item.hasTime) }, context: context) {
            (changed.date, changed.hasTime) = (due.date, due.hasTime)
        }
        guard changed != item else { throw unchanged(event: item.isEvent, reference: reference, context: context) }
        return changed
    }

    /// A change that changes nothing, given nothing (`event` nil: the kind of the item is not known yet) or only what the
    /// item already is. The model reads what a change can give it, then gets its second try; if that try says nothing,
    /// the user is asked what to change.
    static func unchanged(event: Bool?, reference: String?, context: ToolContext) -> ToolRefusal {
        let item = reference.map { " : « \($0) » est déjà comme il le demande" } ?? ""
        let what: String
        switch event {
        case true?:
            what = "son titre (titre), son moment (quand), sa durée (duree), son lieu (lieu) ou son calendrier (calendrier)"
        case false?:
            what = "son titre (titre), son moment (quand) ou sa liste (liste)"
        case nil:
            what = "son titre (titre), son moment (quand), sa durée (duree), son lieu (lieu), son calendrier (calendrier) "
                + "ou la liste d'un rappel (liste)"
        }
        return ToolRefusal(forModel: "Cet appel ne change rien\(item). On peut changer \(what).",
                           spoken: ActionPhrases.nothingChanged(event: event, context.language))
    }

    // MARK: - Timers and shortcuts

    public static let timer = ToolSpec(
        name: "minuteur",
        description: "Lance un minuteur, un compte à rebours qui sonne à la fin.",
        parameters: [
            ToolParameter("duree", .string, "La durée, avec les mots exacts de l'utilisateur (par exemple "
                          + "« 2 heures », « 40 minutes »).", required: true),
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

    /// The moment a call gives in the first of `keys` it has (the user's words, or a date the model wrote): not
    /// past, less than a year ahead. nil when absent and not required. `base`: the item a change starts from.
    /// `orSaid`: when the call gives none, the moment the user's sentence says, if any (the model left it out).
    ///
    /// Words that say when relative to something the app cannot place and give no hour (« jeudi après le travail »:
    /// `FrenchDates.leavesTheHourOpen`) are refused as words it cannot place (`Problem.notUnderstood`), like « après
    /// le travail » alone: the model gets its second try and asks the user, and the refused creation is kept for the
    /// answer (`RefusedCreation`). Read without that part, they saved the event for the whole day. When the user's own
    /// sentence of this turn leaves the hour open, a moment is refused too unless the model's words give the hour, in
    /// the user's words: not a day taken from the date line, an hour the model chose, or the user's day alone. Asked
    /// « Ajoute un rendez-vous chez le coiffeur après le travail dans mon calendrier Perso. » on a Thursday, Gemma 4
    /// E4B wrote « jeudi après le travail » in 9 runs of 10 of voice-cli dialogue-bench: saved on the next Thursday,
    /// all day, and the appointment the user then gave (« Demain à 18 h. ») in 1 run of 10. Refused, the moment is
    /// asked (by the model's second try, or by the app when it says nothing) and the answer saves the appointment in 9
    /// runs of 10. With « jeudi » in the user's words, the three models saved the whole day in 10 runs of 10; refused,
    /// the user's answer (« À 18 h. ») saved Thursday at 18:00 in 59 runs of 60.
    static func moment(_ call: ToolCall, _ keys: [String], context: ToolContext, base: FrenchDates.Base? = nil,
                       required: Bool, orSaid: Bool = false) throws -> FrenchDates.Moment?
    {
        guard let key = keys.first(where: { call.text($0) != nil }), let raw = call.text(key) else {
            if orSaid, let said = context.userSaid.first, FrenchDates.saysWhen(said) {
                // The user's day, but not its hour: asked, as when the model gives these words.
                if FrenchDates.leavesTheHourOpen(said) {
                    throw DateCheck.refusal(.missing, key: keys[0], raw: "", context: context)
                }
                if let moment = try? FrenchDates.moment(said, now: context.now, calendar: context.calendar) {
                    try DateCheck.upcoming(moment, key: keys[0], raw: said, context: context, tool: call.name)
                    return moment
                }
            }
            if required { throw DateCheck.refusal(.missing, key: keys[0], raw: "", context: context) }
            return nil
        }
        func read(_ text: String) throws -> FrenchDates.Moment {
            if FrenchDates.leavesTheHourOpen(text) { throw FrenchDates.Problem.notUnderstood }
            return try FrenchDates.moment(text, now: context.now, calendar: context.calendar, base: base)
        }
        do {
            let moment = try readingTheUser(raw, context: context, read: read)
            if let said = context.userSaid.first, FrenchDates.leavesTheHourOpen(said),
               !(FrenchDates.saysTheHour(raw) && FrenchDates.wordsAreTheUser(raw, said: context.userSaid))
            {
                throw FrenchDates.Problem.notUnderstood
            }
            try DateCheck.upcoming(moment, key: key, raw: raw, context: context, tool: call.name)
            return moment
        } catch let problem as FrenchDates.Problem {
            throw refusal(problem, key: key, raw: raw, context: context)
        }
    }

    /// Reads the model's words about a moment — or the user's own sentence, when it says when by itself and the
    /// model changed the words ("demain" became "vendredi", a day taken from the date line, a date it worked out
    /// itself). When the model's words cannot be placed, the user's latest sentence may complete them: "demain matin
    /// à 7 h 30" copied "demain à 7 h 30", or "du matin", the answer to the app's question.
    private static func readingTheUser<Value>(_ raw: String, context: ToolContext,
                                              read: (String) throws -> Value) throws -> Value
    {
        guard let said = context.userSaid.first else { return try read(raw) }
        let theirs = FrenchDates.wordsAreTheUser(raw, said: context.userSaid)
        if !theirs, FrenchDates.saysWhen(said) {
            do {
                return try read(said)
            } catch FrenchDates.Problem.contradiction, FrenchDates.Problem.notUnderstood {
                // Two moments in the sentence, or none it can place without the model: the model's words.
            }
        }
        do {
            return try read(raw)
        } catch {
            if let completed = try? read(raw + " " + said) { return completed }
            if theirs, FrenchDates.saysWhen(said), let own = try? read(said) { return own }
            throw error
        }
    }

    /// What the app says, and tells the model, about words it cannot place in time.
    static func refusal(_ problem: FrenchDates.Problem, key: String, raw: String, context: ToolContext) -> ToolRefusal {
        let language = context.language
        switch problem {
        case .notUnderstood:
            var refusal = ToolRefusal(
                forModel: "Je ne comprends pas « \(key) » : « \(raw) ». Recopie les mots de l'utilisateur sur le moment, "
                    + "par exemple « samedi à 20 h » ou « dans 2 heures », ou écris la date au format AAAA-MM-JJTHH:MM.",
                spoken: ActionPhrases.badTime(language))
            refusal.detailGivenAgain = true
            return refusal
        case .ambiguousHour(let hour, let minute):
            // The words cannot tell: the user is asked, not the model.
            return ToolRefusal(
                forModel: "« \(raw) » : \(hour) h du matin ou de l'après-midi ? Rien n'est créé ni changé : l'app pose la "
                    + "question à l'utilisateur.",
                spoken: ActionPhrases.morningOrAfternoon(hour: hour, minute: minute, context), retryable: false)
        case .wrongWeekday(let date):
            return ToolRefusal(
                forModel: "« \(raw) » : le \(ActionPhrases.dayOfMonth(date, context)) est un "
                    + "\(ActionPhrases.weekday(date, context)).",
                spoken: ActionPhrases.wrongWeekday(date, context))
        case .contradiction:
            return ToolRefusal(
                forModel: "« \(raw) » donne deux moments différents : recopie seulement celui que l'utilisateur a dit.",
                spoken: ActionPhrases.badTime(language))
        case .noDirection:
            return ToolRefusal(
                forModel: "« \(raw) » : plus tôt ou plus tard ? Écris par exemple « une heure plus tard ».",
                spoken: ActionPhrases.earlierOrLater(language))
        }
    }

    /// A length in the user's words ("une heure et quart"), in seconds, within `range`.
    static func length(_ call: ToolCall, _ key: String, range: ClosedRange<Int>, context: ToolContext) throws -> Int? {
        guard let raw = call.text(key) else { return nil }
        // "Une heure et quart" written "1 h 30" by the model: the user's length.
        if let said = context.userSaid.first, !FrenchDates.wordsAreTheUser(raw, said: context.userSaid),
           let seconds = FrenchDates.lengthSaid(said), range.contains(seconds)
        {
            return seconds
        }
        guard let seconds = FrenchDates.duration(raw), range.contains(seconds) else {
            throw ToolRefusal(
                forModel: "Je ne comprends pas « \(key) » : « \(raw) ». Recopie la durée dite par l'utilisateur, avec "
                    + "son unité, par exemple « 40 minutes ».",
                spoken: ActionPhrases.badDuration(context.language))
        }
        return seconds
    }

    /// An event's length: `duree`, the words of `quand` ("pendant une heure et demie"), or minutes (`duree_minutes`,
    /// as the model may still write it).
    private static func eventLength(_ call: ToolCall, _ moment: FrenchDates.Moment?, context: ToolContext) throws -> Int? {
        let range = 60...(14 * 86_400)
        if let seconds = try length(call, "duree", range: range, context: context) { return seconds }
        if let seconds = moment?.duration, range.contains(seconds) { return seconds }
        if let minutes = call.arguments["duree_minutes"]?.integer {
            guard range.contains(minutes * 60) else {
                throw ToolRefusal(forModel: "« duree_minutes » doit être entre 1 et 20160.",
                                  spoken: ActionPhrases.badDuration(context.language))
            }
            return minutes * 60
        }
        return nil
    }

    /// An end the model gave on its own (`fin`), on the start's day unless it says another.
    private static func endArgument(_ call: ToolCall, start: Date, context: ToolContext) throws -> Date? {
        guard let raw = call.text("fin") else { return nil }
        do {
            return try FrenchDates.moment(raw, now: context.now, calendar: context.calendar,
                                          base: FrenchDates.Base(date: start, hasTime: true)).start
        } catch let problem as FrenchDates.Problem {
            throw refusal(problem, key: "fin", raw: raw, context: context)
        }
    }

    /// The event a `creer_evenement` call describes: start, end, all day. An hour by default; a day alone is the
    /// whole day.
    public static func eventTimes(_ call: ToolCall, context: ToolContext)
        throws -> (start: Date, end: Date, allDay: Bool)
    {
        guard let moment = try moment(call, ["quand", "debut"], context: context, required: true, orSaid: true) else {
            throw DateCheck.refusal(.missing, key: "quand", raw: "", context: context)
        }
        let calendar = context.calendar
        if !moment.hasTime || call.arguments["journee_entiere"]?.boolean == true {
            let day = calendar.startOfDay(for: moment.start)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            return (day, max(moment.end ?? next, next), true)
        }
        var end = moment.start.addingTimeInterval(3600)
        if let seconds = try eventLength(call, moment, context: context) {
            end = moment.start.addingTimeInterval(TimeInterval(seconds))
        }
        if let given = try moment.end ?? endArgument(call, start: moment.start, context: context) {
            guard given > moment.start else {
                throw ToolRefusal(forModel: "La fin doit être après le début.", spoken: ActionPhrases.badTime(context.language))
            }
            end = given
        }
        return (moment.start, end, false)
    }

    /// When a `creer_rappel` call's reminder is due; nil for a reminder without a date.
    public static func reminderDue(_ call: ToolCall, context: ToolContext) throws -> (date: Date, hasTime: Bool)? {
        try moment(call, ["quand", "echeance"], context: context, required: false, orSaid: true)
            .map { ($0.start, $0.hasTime) }
    }

    /// The new times of an event a `modifier_element` call changes, nil when it changes none of them: "à 16 h"
    /// keeps its day, "samedi" its time and its length, "une heure plus tard" moves it from where it is.
    public static func changedEvent(_ call: ToolCall, start: Date, end: Date, allDay: Bool, context: ToolContext)
        throws -> (start: Date, end: Date, allDay: Bool)?
    {
        let calendar = context.calendar
        let moment = try moment(call, ["quand", "debut", "echeance"], context: context,
                                base: FrenchDates.Base(date: start, hasTime: !allDay), required: false)
        let seconds = try eventLength(call, moment, context: context)
        guard moment != nil || seconds != nil || call.text("fin") != nil else { return nil }
        var newStart = start
        var newAllDay = allDay
        if let moment {
            newAllDay = !moment.hasTime
            newStart = newAllDay ? calendar.startOfDay(for: moment.start) : moment.start
        }
        var newEnd: Date
        if newAllDay {
            // Whole days: as many as before, one when it had a time.
            let count = allDay ? max(calendar.dateComponents([.day], from: start, to: end).day ?? 1, 1) : 1
            newEnd = calendar.date(byAdding: .day, value: count, to: newStart) ?? newStart.addingTimeInterval(86_400)
            if let given = moment?.end, given > newStart { newEnd = given }
        } else {
            let length = seconds.map { TimeInterval($0) } ?? (allDay ? 3600 : end.timeIntervalSince(start))
            newEnd = moment?.end ?? newStart.addingTimeInterval(length)
            if let given = try endArgument(call, start: newStart, context: context) { newEnd = given }
        }
        guard newEnd > newStart else {
            throw ToolRefusal(forModel: "La fin doit être après le début.", spoken: ActionPhrases.badTime(context.language))
        }
        return (newStart, newEnd, newAllDay)
    }

    /// The new due date of a reminder a `modifier_element` call changes, nil when it does not move it.
    public static func changedDue(_ call: ToolCall, due: (date: Date, hasTime: Bool)?, context: ToolContext)
        throws -> (date: Date, hasTime: Bool)?
    {
        let base = due.map { FrenchDates.Base(date: $0.date, hasTime: $0.hasTime) }
        return try moment(call, ["quand", "echeance", "debut"], context: context, base: base, required: false)
            .map { ($0.start, $0.hasTime) }
    }

    /// The period a reading covers ("demain", "cette semaine"). Without one (reminders only): nil.
    public static func period(_ call: ToolCall, context: ToolContext, required: Bool) throws -> (Date, Date)? {
        let range: (start: Date, end: Date)
        do {
            if let raw = call.text("quand") {
                func read(_ text: String) throws -> (start: Date, end: Date) {
                    try FrenchDates.period(text, now: context.now, calendar: context.calendar)
                }
                range = try readingTheUser(raw, context: context, read: read)
            } else if let raw = call.text("debut") ?? call.text("fin") {
                // The way the model may still write it: dates, a start and an end.
                let start = try FrenchDates.period(raw, now: context.now, calendar: context.calendar).start
                let end = try call.text("fin").map {
                    try FrenchDates.period($0, now: context.now, calendar: context.calendar).end
                } ?? context.calendar.date(byAdding: .day, value: 1, to: context.calendar.startOfDay(for: start)) ?? start
                range = call.text("debut") == nil ? (context.now, end) : (start, end)
            } else if let said = context.userSaid.first, FrenchDates.saysWhen(said),
                      let own = try? FrenchDates.period(said, now: context.now, calendar: context.calendar)
            {
                range = own  // the user said when, the model left it out
            } else {
                if required { throw DateCheck.refusal(.missing, key: "quand", raw: "", context: context) }
                return nil
            }
        } catch let problem as FrenchDates.Problem {
            throw refusal(problem, key: "quand", raw: call.text("quand") ?? call.text("debut") ?? "", context: context)
        }
        guard range.end > range.start else {
            throw ToolRefusal(forModel: "La fin doit être après le début.", spoken: ActionPhrases.badTime(context.language))
        }
        guard range.end.timeIntervalSince(range.start) <= 92 * 24 * 3600 else {
            throw ToolRefusal(forModel: "La période ne peut pas dépasser trois mois.",
                              spoken: ActionPhrases.badTime(context.language))
        }
        return range
    }

    /// The length of a `minuteur` call, in seconds (1 second to 24 hours): `duree` in the user's words, or
    /// `duree_secondes`, as the model may still write it.
    public static func timerSeconds(_ call: ToolCall, context: ToolContext) throws -> Int {
        let range = 1...(24 * 3600)
        if let seconds = try length(call, "duree", range: range, context: context) { return seconds }
        guard let seconds = call.arguments["duree_secondes"]?.integer, range.contains(seconds) else {
            throw ToolRefusal(forModel: "Il manque « duree » : la durée dite par l'utilisateur, par exemple « 40 minutes ».",
                              spoken: ActionPhrases.badDuration(context.language))
        }
        return seconds
    }

    /// The built-in tools' names, in the app's order (the shortcuts' tool only when there are shortcuts).
    static func names(shortcuts: [String] = []) -> [String] {
        (calendarTools(movingItems: true) + [timer] + [runShortcut(names: shortcuts)].compactMap { $0 }).map(\.name)
    }

    /// Checks a call against the static rules (the benchmark's "would the app accept it"). The dates of a change
    /// are checked when it is carried out: they depend on the item ("à la même heure"). The caller reads a misspelled
    /// tool name first (`ToolNames`), as the app does; a name that stands for no tool is refused with the real ones.
    public static func check(_ call: ToolCall, context: ToolContext, shortcuts: [String] = []) throws {
        switch call.name {
        case createReminder.name:
            _ = try title(call, context: context)
            _ = try reminderDue(call, context: context)
        case listReminders.name:
            _ = try period(call, context: context, required: false)
        case createEvent.name:
            _ = try title(call, context: context)
            _ = try eventTimes(call, context: context)
        case readAgenda.name:
            _ = try period(call, context: context, required: true)
        case changeItem.name, deleteItem.name:
            guard call.text("reference") != nil else {
                throw ToolRefusal(forModel: "Il manque « reference ».", spoken: ActionPhrases.nothingToChange(context.language))
            }
            // What it gives is compared with the item when the call is carried out (`changed`).
            if call.name == changeItem.name, !changeKeys.contains(where: { call.text($0) != nil }) {
                throw unchanged(event: nil, reference: nil, context: context)
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
            throw ToolRefusal(forModel: ToolNames.unknown(call.name, among: names(shortcuts: shortcuts)),
                              spoken: ActionPhrases.notUnderstood(context.language))
        }
    }
}
