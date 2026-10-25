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
/// words about time the app cannot place or none at all, a calendar or a list that does not exist, a title that does not
/// say what: `ActionCatalog.title`), kept for the call right after it. When the user answers ("Demain à 16h.", "Mets-la
/// dans Maison alors."), Gemma 4 26B often takes the refused item for saved and writes a change of the "last" item
/// (`modifier_element`), which was never created: that change then creates the item, with what the change gives. In
/// voice-cli dialogue-bench the 26B answered so 9 times in 10 after a calendar that does not exist, 2 to 5 after words
/// about time the app cannot place: the item was saved at that answer in 5 and 8 runs of 10, when its second try wrote
/// the creation again, and in 10 of 10 since. Used by the calendar providers (`CalendarTools`, and voice-cli's calendar
/// in memory), around their check and their carrying out of each call.
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
///
/// Refused for a calendar or a list that does not exist, the creation goes instead in the one the user's answer names
/// among the writable ones (« Mets-la dans Maison alors. »: `ActionCatalog.collectionAnswered`), when the change that
/// stands for it gives none (`creation(insteadOf:said:names:exists:)`), or when the creation written again leaves it
/// out (`answer(before:said:)`): the refused one could only be refused again, and the default one is not the one
/// named. Gemma 4 E4B answered so with `modifier_element {reference: dernier, titre: réunion}`, without the calendar,
/// in 2 runs of 10 of voice-cli dialogue-bench: the meeting was refused again for « Travail », and the model said it
/// was in « Maison ». Only the user's answer, said after the refusal: the request itself, which a second try of the
/// model reads again, names the refused one.
///
/// Refused for words that gave the day but left the hour open (« jeudi après le travail »:
/// `FrenchDates.leavesTheHourOpen`), the creation keeps that day when the answer gives an hour alone (« À 18 h. »:
/// `FrenchDates.saysOnlyTheHour`), in a change (`creation(insteadOf:said:names:exists:)`) or in the creation written
/// again (`withRefusedMoment`): « à 18 h » alone is the next 18:00, the next day at the bench's 18:42, not the Thursday
/// the user said. To that answer, the models wrote « jeudi à 18 h » in 59 of 60 calls of voice-cli dialogue-bench,
/// and Gemma 4 E4B once a change of the last item with « à 18 h ».
///
/// Refused for its title (« Rappelle-moi demain à 9 h. », which does not say what), the creation keeps its moment for the
/// answer (« D'appeler le plombier. »): a change of the last item gives the title (`creation(insteadOf:said:names:exists:)`),
/// and the creation written again with its title alone gets the refused one's moment (`withRefusedMoment`).
public struct RefusedCreation: Sendable {
    private var refused: ToolCall?
    /// The creation refused just before the call being checked and carried out, when that call is the same tool's.
    private var before: ToolCall?
    /// What the user had said when the creation kept (`refused`, then `before`) was refused (`ToolContext.userSaid`):
    /// a call with the same words comes from the same turn, a second try of the model, not from the user's answer.
    private var refusedSaid: [String] = []
    private static let creations = [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name]
    /// The words a call may give its moment under, the first one given counting.
    private static let starts = ["quand", "debut", "echeance"]

    public init() {}

    /// Before a call is checked: a creation refused only stays for the call right after it, if that call is a change
    /// (`creation(insteadOf:said:names:exists:)`), or the same creation written again (`collection(before:)`,
    /// `answer(before:said:)`, `withRefusedMoment`).
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

    /// The user's answer to the refusal of the same creation refused just before `call`, the call being checked and
    /// carried out: `said`'s first (`ToolContext.userSaid`, the latest first), when the user said it after that
    /// refusal. nil when `call` is another one, or comes from the same turn (the model's second try, with the request
    /// as the user's words). For the calendar or the list that answer names, when the refused one does not exist
    /// (`ActionCatalog.withCollectionSaid`).
    public func answer(before call: ToolCall, said: [String]) -> String? {
        guard let before, before.name == call.name, said != refusedSaid else { return nil }
        return said.first
    }

    /// `call`, the call being checked and carried out, when it is the same creation refused just before written again:
    /// - with an hour alone (« à 18 h ») after words that gave the day and left the hour open (« jeudi après le
    ///   travail »): with both, « jeudi après le travail à 18 h », Thursday at 18:00;
    /// - without a moment, after a refusal for its title (`ActionCatalog.saysWhat`): with the refused one's moment
    ///   (`moment(of:in:)`). « Rappelle-moi demain à 9 h. » does not say what to remind; to the answer, « D'appeler le
    ///   plombier. », the model may write the reminder with its title alone, which would be saved without a date.
    /// Unchanged otherwise: a moment with a day of its own (« demain à 18 h ») replaces the refused one. `said`: the
    /// user's messages, the latest first (`ToolContext.userSaid`), for words of the model's own
    /// (`words(_:said:keepingTheDayOf:)`).
    public func withRefusedMoment(_ call: ToolCall, said: [String]) -> ToolCall {
        guard let before, before.name == call.name else { return call }
        guard let key = Self.starts.first(where: { call.text($0) != nil }) else {
            return ActionCatalog.saysWhat(before) ? call : Self.moment(of: before, in: call)
        }
        guard let words = call.text(key), let kept = Self.words(words, said: said, keepingTheDayOf: before) else {
            return call
        }
        var call = call
        call.arguments[key] = .string(kept)
        return call
    }

    /// `call`, a creation that gives no moment, with the moment of `refused`, the same creation refused just before:
    /// its start, its end and its length, under the words it gave them, each one `call` does not give.
    private static func moment(of refused: ToolCall, in call: ToolCall) -> ToolCall {
        var call = call
        for key in starts + ["fin", "journee_entiere", "duree", "duree_minutes"] where call.text(key) == nil {
            if let value = refused.arguments[key] { call.arguments[key] = value }
        }
        return call
    }

    /// The moment words of `refused`, when they leave the hour open (`FrenchDates.leavesTheHourOpen`), followed by
    /// `words` when these give an hour alone (`FrenchDates.saysOnlyTheHour`), or by the user's answer (`said`, the
    /// latest first) when it gives one and `words` are not the user's (a date the model worked out, « jeudi 15 octobre
    /// 2026 à 18 h »): the app would read that answer alone instead, the next 18:00. nil otherwise.
    ///
    /// Asked « À quelle heure ? », Gemma 4 E4B wrote « jeudi 15 octobre 2026 à 18 h » (today's date, from the date
    /// line) to « À 18 h. » in 1 run of 10 of voice-cli dialogue-bench: the answer alone saved Friday. The words kept
    /// are then read as any others: when the refused ones are not the user's either (« jeudi » from the date line,
    /// when the user said « après le travail »), the user's answer alone.
    private static func words(_ words: String, said: [String], keepingTheDayOf refused: ToolCall) -> String? {
        guard let key = starts.first(where: { refused.text($0) != nil }), let open = refused.text(key),
              FrenchDates.leavesTheHourOpen(open)
        else { return nil }
        if FrenchDates.saysOnlyTheHour(words) { return open + " " + words }
        guard let answer = said.first, FrenchDates.saysOnlyTheHour(answer),
              !FrenchDates.wordsAreTheUser(words, said: said)
        else { return nil }
        return open + " " + answer
    }

    /// A call was refused, by the provider's check or when carried out: a creation is kept when the user gives the
    /// refused detail again (`ToolRefusal.detailGivenAgain`), forgotten otherwise. A change refused leaves what is
    /// kept: its second try may still make it, and the creation it was made into, refused in turn, is already kept.
    /// `said`: what the user had said (`ToolContext.userSaid`), which tells their answer from a second try of the
    /// model in the same turn.
    public mutating func refused(_ call: ToolCall, _ refusal: ToolRefusal, said: [String] = []) {
        guard Self.creations.contains(call.name) else { return }
        refused = refusal.detailGivenAgain ? call : nil
        refusedSaid = said
    }

    /// The creation to carry out instead of `change`, a change of the last item or of one that does not exist: the
    /// refused call, with what the change gives: a new moment instead of the old one (as `quand`, whichever word the
    /// change uses; an hour alone after words that gave the day and left the hour open, both: « jeudi après le
    /// travail à 18 h »), a calendar or a list (an event's calendar, a reminder's list, whichever of the two words the
    /// change uses; none, when the refused one does not exist among `names(event)`, the calendars of an event or the
    /// lists of a reminder: the one the user's answer names, `ActionCatalog.collectionAnswered`), a title, a length, a
    /// place. nil when no creation was refused just before, or when the change names by its id an item created in this
    /// conversation (`exists`: whether a reference names one), which it changes. `said`: the user's messages, the
    /// latest first, as for `withRefusedMoment`; the first is their answer when they said it after the refusal
    /// (`refused(_:_:said:)`). Forgets the refused creation.
    public mutating func creation(insteadOf change: ToolCall, said: [String] = [],
                                  names: (_ event: Bool) -> [String] = { _ in [] },
                                  exists: (String) -> Bool) -> ToolCall? {
        guard var creation = refused, change.name == ActionCatalog.changeItem.name else { return nil }
        refused = nil
        let reference = change.text("reference") ?? "dernier"
        if !ActionCatalog.meansLastItem(reference), exists(reference) { return nil }
        var given = change.arguments.filter { key, _ in key != "reference" && change.text(key) != nil }
        let starts = Self.starts
        if let start = starts.first(where: { given[$0] != nil }) {
            let kept = change.text(start).flatMap { Self.words($0, said: said, keepingTheDayOf: creation) }
            for key in starts + ["fin", "journee_entiere"] { creation.arguments[key] = nil }
            let moment = kept.map { JSONValue.string($0) } ?? given[start]
            for key in starts { given[key] = nil }
            given["quand"] = moment
        }
        let event = creation.name == ActionCatalog.createEvent.name
        let (own, other) = event ? ("calendrier", "liste") : ("liste", "calendrier")
        if let named = given.removeValue(forKey: other), given[own] == nil { given[own] = named }
        // None given, and the refused one does not exist: the one the user's answer names.
        if given[own] == nil, let refusedName = creation.text(own), said != refusedSaid, let answer = said.first {
            let all = names(event)
            if ActionCatalog.collectionIndex(named: refusedName, among: all) == nil,
               let index = ActionCatalog.collectionAnswered(in: answer, event: event, among: all)
            {
                given[own] = .string(all[index])
                DebugLog.log("calendar: \(event ? "calendar" : "list") “\(all[index])” taken from the user's answer")
            }
        }
        creation.arguments.merge(given) { _, changed in changed }
        return creation
    }

    public mutating func forget() {
        refused = nil
        before = nil
        refusedSaid = []
    }
}
