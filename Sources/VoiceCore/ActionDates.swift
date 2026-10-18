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
            return ToolRefusal(forModel: "Il manque « \(key) ».", spoken: ActionPhrases.badTime(context.language))
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
            refusal.momentGone = true
            return refusal
        case .tooFar(let moment):
            return ToolRefusal(forModel: "\(when(moment)), à plus d'un an : nous sommes le \(now).",
                               spoken: ActionPhrases.dateTooFar(context.language))
        }
    }
}

/// A creation refused because its moment was gone, kept for the call right after it: when the user gives another moment,
/// Gemma 4 26B often writes a change of the "last" item (`modifier_element`, "Demain à 16h."), which was never created.
/// That change then creates the item at the new moment. Used by the calendar providers (`CalendarTools`, and voice-cli's
/// calendar in memory), around their check of each call.
public struct RefusedCreation: Sendable {
    private var refused: ToolCall?

    public init() {}

    /// Before a call is checked: a creation refused only stays for the call right after it, if that call is a change (of
    /// an item that does not exist: a provider that finds the item forgets it).
    public mutating func checking(_ call: ToolCall) {
        if call.name != ActionCatalog.changeItem.name { refused = nil }
    }

    /// A call was refused: kept when it is a creation whose moment is gone.
    public mutating func refusal(_ refusal: ToolRefusal, of call: ToolCall) {
        let creations = [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name]
        refused = refusal.momentGone && creations.contains(call.name) ? call : nil
    }

    /// The creation to carry out instead of `change`, a change of an item that does not exist: the refused call, with
    /// what the change gives (the new moment instead of the old one, a title, a length, a place). nil when no creation
    /// was refused just before. Forgets it.
    public mutating func creation(insteadOf change: ToolCall) -> ToolCall? {
        guard var creation = refused, change.name == ActionCatalog.changeItem.name else { return nil }
        refused = nil
        let moments = ["quand", "debut", "echeance", "fin", "journee_entiere"]
        if moments.contains(where: { change.arguments[$0] != nil }) {
            for key in moments { creation.arguments[key] = nil }
        }
        for (key, value) in change.arguments where key != "reference" { creation.arguments[key] = value }
        return creation
    }

    public mutating func forget() { refused = nil }
}
