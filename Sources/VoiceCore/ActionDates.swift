import Foundation

/// Dates as the model writes them in tool calls: ISO 8601 in local time, "2026-10-16T10:00", or a day alone,
/// "2026-10-16". A time-zone suffix ("Z", "+02:00") is ignored: the model is asked for local time, and when it
/// adds one it almost always means local time anyway.
public enum LocalDateTime {
    private static let pattern =
        #"^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(?:Z|[+-]\d{2}:?\d{2})?$"#

    /// The date, and whether it has a time of day. nil when the text is not such a date.
    public static func parse(_ text: String, in timeZone: TimeZone) -> (date: Date, hasTime: Bool)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func number(_ i: Int) -> Int? {
            Range(match.range(at: i), in: text).flatMap { Int(text[$0]) }
        }
        var components = DateComponents()
        components.year = number(1)
        components.month = number(2)
        components.day = number(3)
        let hasTime = number(4) != nil
        components.hour = number(4) ?? 0
        components.minute = number(5) ?? 0
        components.second = number(6) ?? 0
        guard let month = components.month, (1...12).contains(month), let day = components.day, (1...31).contains(day),
              let hour = components.hour, (0...24).contains(hour), let minute = components.minute, (0...59).contains(minute)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // "24:00" is the end of the day.
        if hour == 24 { components.hour = 23; components.minute = 59 }
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day  // no 31 September
        else { return nil }
        return (date, hasTime)
    }

    /// "2026-10-16T10:00", in the given time zone.
    public static func format(_ date: Date, in timeZone: TimeZone, withTime: Bool = true) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return withTime ? day + String(format: "T%02d:%02d", c.hour ?? 0, c.minute ?? 0) : day
    }
}

/// The checks every dated action shares: a moment in the past or more than a year ahead is refused, and the user
/// is asked again.
///
/// A moment in the past is asked to the user at once, not to the model: the app reads the user's own words when the
/// model changed them, so a second try could not give another moment, and Gemma 4 E4B filled it with a sentence of its
/// own — "J'ai ajouté ton rendez-vous…" for an event never saved, nothing at all, or a question without the event. The
/// call stays in the history, with what to do once the user gives another moment: the same call again, not a change
/// (Gemma 4 26B took the refused event for saved, and moved it with `modifier_element`).
public enum DateCheck {
    /// Refuses a moment in the past (a minute's grace; a day alone, before today) or more than a year ahead. `tool`: the
    /// call's, which the model is told to write again once the user gives another moment.
    public static func upcoming(_ moment: FrenchDates.Moment, key: String, raw: String, context: ToolContext,
                                tool: String? = nil) throws
    {
        let calendar = context.calendar
        let past = moment.hasTime
            ? moment.start < context.now.addingTimeInterval(-60)
            : moment.start < calendar.startOfDay(for: context.now)
        if past { throw refusal(.past(moment), key: key, raw: raw, context: context, tool: tool) }
        if let limit = calendar.date(byAdding: .year, value: 1, to: context.now), moment.start > limit {
            throw refusal(.tooFar(moment), key: key, raw: raw, context: context)
        }
    }

    public enum Problem: Sendable {
        case missing
        case past(FrenchDates.Moment)
        case tooFar(FrenchDates.Moment)
    }

    public static func refusal(_ problem: Problem, key: String, raw: String, context: ToolContext,
                               tool: String? = nil) -> ToolRefusal
    {
        let now = ActionPhrases.moment(context.now, hasTime: true, context)
        func when(_ moment: FrenchDates.Moment) -> String {
            "« \(key) » (« \(raw) ») tombe le \(ActionPhrases.moment(moment.start, hasTime: moment.hasTime, context))"
        }
        switch problem {
        case .missing:
            var refusal = ToolRefusal(forModel: "Il manque « \(key) ».",
                                      spoken: ActionPhrases.badTime(context.language))
            refusal.detailGivenAgain = true
            return refusal
        case .past(let moment):
            let creation = [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name].contains(tool ?? "")
            let next = tool.map {
                " Quand il le donne, appelle de nouveau \($0) avec ses mots"
                    + (creation ? " (pas \(ActionCatalog.changeItem.name) : rien n'existe encore)." : ".")
            } ?? ""
            var refusal = ToolRefusal(forModel: "\(when(moment)), déjà passé : nous sommes le \(now). Rien n'est "
                                          + (tool == nil ? "créé ni changé" : creation ? "créé" : "changé")
                                          + " : l'app demande un autre moment à l'utilisateur." + next,
                                      spoken: ActionPhrases.datePassed(context.language), retryable: false)
            refusal.detailGivenAgain = true
            return refusal
        case .tooFar(let moment):
            return ToolRefusal(forModel: "\(when(moment)), à plus d'un an : nous sommes le \(now).",
                               spoken: ActionPhrases.dateTooFar(context.language))
        }
    }
}

/// A creation refused for a detail the user then gives again (`ToolRefusal.detailGivenAgain`: a moment already gone,
/// words about time the app cannot place or none at all, a calendar or a list that does not exist), kept for the call
/// right after it. When the user answers ("Demain à 16h.", "Mets-la dans Maison alors."), Gemma 4 26B often takes the
/// refused item for saved and writes a change of the "last" item (`modifier_element`), which was never created: that
/// change then creates the item, with what the change gives. In voice-cli dialogue-bench the 26B answered so 9 times in
/// 10 after a calendar that does not exist, 2 to 5 after words about time the app cannot place: the item was saved at
/// that answer in 5 and 8 runs of 10, when its second try wrote the creation again, and in 10 of 10 since. Used by the
/// calendar providers (`CalendarTools`, and voice-cli's calendar in memory), around their check and their carrying out
/// of each call.
///
/// The last item is then the refused one, even when the conversation created another before it: a change of the last
/// item (« dernier ») is the refused creation. That earlier item used to be changed instead (« Demain à 18 h. » moved
/// it, « Mets-la dans Maison alors. » saved it unchanged, « C'est modifié »), and the item the user asked for was never
/// saved. A change that names an item by its id ("r1") still changes that item: asked to move the reminder created
/// before instead (« Laisse tomber, décale plutôt mon rappel à 11 h. »), Gemma 4 26B, E4B and E2B named it so in every
/// change they wrote in voice-cli dialogue-bench.
///
/// Not after a refusal whose answer only completes the refused words (« de l'après-midi » for an hour that may be the
/// morning, « le 25 » for a weekday that does not match the date): read alone, such words would lose the rest of the
/// moment, which the model writes again in a creation of its own.
///
/// When the model writes the creation again instead, without its calendar or its list, the refused one's
/// (`collection(before:)`).
public struct RefusedCreation: Sendable {
    private var refused: ToolCall?
    /// The creation refused just before the call being checked and carried out, when that call is the same tool's.
    private var before: ToolCall?
    private static let creations = [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name]

    public init() {}

    /// Before a call is checked: a creation refused only stays for the call right after it, if that call is a change
    /// (`creation(insteadOf:exists:)`), or the same creation written again (`collection(before:)`).
    public mutating func checking(_ call: ToolCall) {
        before = refused?.name == call.name ? refused : nil
        if call.name != ActionCatalog.changeItem.name { refused = nil }
    }

    /// The calendar (an event's) or the list (a reminder's) of the same creation refused just before `call`, the call
    /// being checked and carried out, written again (« Demain à 18 h. » after words about time the app could not
    /// place): the user named it in the request (the app kept it so: `ActionCatalog.withCollectionSaid`), or the model
    /// did, and left it out when it wrote the call again. nil when `call` is another one.
    public func collection(before call: ToolCall) -> String? {
        guard let before, before.name == call.name else { return nil }
        return before.text(before.name == ActionCatalog.createEvent.name ? "calendrier" : "liste")
    }

    /// A call was refused, by the provider's check or when carried out: a creation is kept when the user gives the
    /// refused detail again (`ToolRefusal.detailGivenAgain`), forgotten otherwise. A change refused leaves what is
    /// kept: its second try may still make it, and the creation it was made into, refused in turn, is already kept.
    public mutating func refused(_ call: ToolCall, _ refusal: ToolRefusal) {
        guard Self.creations.contains(call.name) else { return }
        refused = refusal.detailGivenAgain ? call : nil
    }

    /// The creation to carry out instead of `change`, a change of the last item or of one that does not exist: the
    /// refused call, with what the change gives: a new moment instead of the old one (as `quand`, whichever word the
    /// change uses), a calendar or a list (an event's calendar, a reminder's list, whichever of the two words the change
    /// uses), a title, a length, a place. nil when no creation was refused just before, or when the change names by its
    /// id an item created in this conversation (`exists`: whether a reference names one), which it changes. Forgets
    /// the refused creation.
    public mutating func creation(insteadOf change: ToolCall, exists: (String) -> Bool) -> ToolCall? {
        guard var creation = refused, change.name == ActionCatalog.changeItem.name else { return nil }
        refused = nil
        let reference = change.text("reference") ?? "dernier"
        if !ActionCatalog.meansLastItem(reference), exists(reference) { return nil }
        var given = change.arguments.filter { key, _ in key != "reference" && change.text(key) != nil }
        let starts = ["quand", "debut", "echeance"]
        if let start = starts.first(where: { given[$0] != nil }) {
            for key in starts + ["fin", "journee_entiere"] { creation.arguments[key] = nil }
            let moment = given[start]
            for key in starts { given[key] = nil }
            given["quand"] = moment
        }
        let event = creation.name == ActionCatalog.createEvent.name
        let (own, other) = event ? ("calendrier", "liste") : ("liste", "calendrier")
        if let named = given.removeValue(forKey: other), given[own] == nil { given[own] = named }
        creation.arguments.merge(given) { _, changed in changed }
        return creation
    }

    public mutating func forget() {
        refused = nil
        before = nil
    }
}
