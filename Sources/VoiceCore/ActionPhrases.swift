import Foundation

/// The sentences the app says after an action, filled in from what was really saved. They are product
/// content, so they are written in French (and English, for conversations in English), following the
/// interface's typography: "tu", non-breaking spaces (`\u{00A0}`) before « : ? ! » and inside guillemets,
/// typographic apostrophes. `SpeakableText.forVoice` turns them into what the voice reads ("10 h" → "10 heures").
///
/// Every sentence has at least five words: the voice renders shorter texts as silence.
public enum ActionPhrases {
    static let nb = "\u{00A0}"

    // MARK: - Dates

    private static let frenchWeekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    private static let frenchMonths = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
                                       "septembre", "octobre", "novembre", "décembre"]
    private static let englishWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August",
                                        "September", "October", "November", "December"]

    /// "vendredi 16 octobre" ("1er" for the first; the year only when it is not the current one).
    public static func day(_ date: Date, _ context: ToolContext) -> String {
        let calendar = context.calendar
        let c = calendar.dateComponents([.weekday, .day, .month, .year], from: date)
        let (weekday, day, month, year) = (c.weekday! - 1, c.day!, c.month! - 1, c.year!)
        let thisYear = calendar.component(.year, from: context.now) == year
        switch context.language {
        case .french:
            return "\(frenchWeekdays[weekday]) \(day == 1 ? "1er" : String(day)) \(frenchMonths[month])"
                + (thisYear ? "" : " \(year)")
        case .english:
            return "\(englishWeekdays[weekday]), \(englishMonths[month]) \(day)" + (thisYear ? "" : ", \(year)")
        }
    }

    /// "jeudi".
    public static func weekday(_ date: Date, _ context: ToolContext) -> String {
        let index = context.calendar.component(.weekday, from: date) - 1
        return context.language == .french ? frenchWeekdays[index] : englishWeekdays[index]
    }

    /// "22 octobre" ("1er" for the first; the year only when it is not the current one).
    public static func dayOfMonth(_ date: Date, _ context: ToolContext) -> String {
        let calendar = context.calendar
        let c = calendar.dateComponents([.day, .month, .year], from: date)
        let (day, month, year) = (c.day!, c.month! - 1, c.year!)
        let thisYear = calendar.component(.year, from: context.now) == year
        switch context.language {
        case .french: return "\(day == 1 ? "1er" : String(day)) \(frenchMonths[month])" + (thisYear ? "" : " \(year)")
        case .english: return "\(englishMonths[month]) \(day)" + (thisYear ? "" : ", \(year)")
        }
    }

    /// "10\u{00A0}h", "10\u{00A0}h\u{00A0}30", "midi", "3\u{00A0}h du matin" (an hour between 1 and 7 is said in full, so a
    /// morning taken for an afternoon is heard at once).
    public static func time(_ date: Date, _ context: ToolContext) -> String {
        let c = context.calendar.dateComponents([.hour, .minute], from: date)
        let (hour, minute) = (c.hour!, c.minute!)
        switch context.language {
        case .french:
            if minute == 0, hour == 12 { return "midi" }
            if minute == 0, hour == 0 { return "minuit" }
            let base = minute == 0 ? "\(hour)\(nb)h" : "\(hour)\(nb)h\(nb)\(String(format: "%02d", minute))"
            return (1...7).contains(hour) ? base + " du matin" : base
        case .english:
            if minute == 0, hour == 12 { return "noon" }
            if minute == 0, hour == 0 { return "midnight" }
            let h = hour % 12 == 0 ? 12 : hour % 12
            let suffix = hour < 12 ? "AM" : "PM"
            return minute == 0 ? "\(h)\(nb)\(suffix)" : "\(h):\(String(format: "%02d", minute))\(nb)\(suffix)"
        }
    }

    /// "vendredi 16 octobre à 10 h", or the day alone.
    public static func moment(_ date: Date, hasTime: Bool, _ context: ToolContext) -> String {
        guard hasTime else { return day(date, context) }
        return context.language == .french
            ? "\(day(date, context)) à \(time(date, context))"
            : "\(day(date, context)) at \(time(date, context))"
    }

    /// "vendredi 16 octobre de 15 h à 16 h", "vendredi 16 octobre, toute la journée", or across days.
    public static func span(_ start: Date, _ end: Date, allDay: Bool, _ context: ToolContext) -> String {
        let calendar = context.calendar
        let french = context.language == .french
        if allDay {
            // An all-day event ends at midnight after its last day.
            let lastDay = calendar.date(byAdding: .second, value: -1, to: max(end, start.addingTimeInterval(1))) ?? start
            if calendar.isDate(lastDay, inSameDayAs: start) {
                return french ? "\(day(start, context)), toute la journée" : "\(day(start, context)), all day"
            }
            return french ? "du \(day(start, context)) au \(day(lastDay, context))"
                : "from \(day(start, context)) to \(day(lastDay, context))"
        }
        if calendar.isDate(start, inSameDayAs: end) || end <= start {
            return french
                ? "\(day(start, context)) de \(time(start, context)) à \(time(end, context))"
                : "\(day(start, context)) from \(time(start, context)) to \(time(end, context))"
        }
        return french
            ? "du \(moment(start, hasTime: true, context)) au \(moment(end, hasTime: true, context))"
            : "from \(moment(start, hasTime: true, context)) to \(moment(end, hasTime: true, context))"
    }

    /// "Aujourd'hui", "Demain", "Vendredi 16 octobre", or "Du lundi 20 octobre au dimanche 26 octobre": how a
    /// reading of the agenda opens.
    public static func period(_ start: Date, _ end: Date, _ context: ToolContext) -> String {
        let calendar = context.calendar
        let french = context.language == .french
        let last = end > start ? end.addingTimeInterval(-1) : start
        if calendar.isDate(start, inSameDayAs: last) {
            if calendar.isDate(start, inSameDayAs: context.now) { return french ? "Aujourd’hui" : "Today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: context.now),
               calendar.isDate(start, inSameDayAs: tomorrow)
            {
                return french ? "Demain" : "Tomorrow"
            }
            return capitalized(day(start, context))
        }
        return french ? "Du \(day(start, context)) au \(day(last, context))"
            : "From \(day(start, context)) to \(day(last, context))"
    }

    /// "10 minutes", "1 heure et 30 minutes", "45 secondes".
    public static func duration(seconds: Int, _ language: SpeechLanguage) -> String {
        let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        let french = language == .french
        var parts: [String] = []
        if h > 0 { parts.append(french ? "\(h) heure\(h > 1 ? "s" : "")" : "\(h) hour\(h > 1 ? "s" : "")") }
        if m > 0 { parts.append("\(m) minute\(m > 1 ? "s" : "")") }
        if s > 0 || parts.isEmpty {
            parts.append(french ? "\(s) seconde\(s > 1 ? "s" : "")" : "\(s) second\(s == 1 ? "" : "s")")
        }
        return list(parts, language)
    }

    // MARK: - Calendar and reminders

    public static func eventCreated(title: String, start: Date, end: Date, allDay: Bool, calendarName: String?,
                                    _ context: ToolContext) -> String
    {
        let when = span(start, end, allDay: allDay, context)
        switch context.language {
        case .french:
            let place = calendarName.map { "dans ton calendrier «\(nb)\($0)\(nb)»" } ?? "dans ton agenda"
            return "C’est \(place)\(nb): \(title), \(when)."
        case .english:
            let place = calendarName.map { "in your “\($0)” calendar" } ?? "in your calendar"
            return "It’s \(place): \(title), \(when)."
        }
    }

    public static func reminderCreated(title: String, due: Date?, hasTime: Bool, listName: String?,
                                       _ context: ToolContext) -> String
    {
        switch context.language {
        case .french:
            let place = listName.map { " dans ta liste «\(nb)\($0)\(nb)»" } ?? (due == nil ? " dans tes rappels" : "")
            guard let due else { return "C’est noté\(place)\(nb): \(title)." }
            return "C’est noté\(place)\(nb): \(moment(due, hasTime: hasTime, context)), \(title)."
        case .english:
            let place = listName.map { " in your “\($0)” list" } ?? (due == nil ? " in your reminders" : "")
            guard let due else { return "Noted\(place): \(title)." }
            return "Noted\(place): \(moment(due, hasTime: hasTime, context)), \(title)."
        }
    }

    public static func eventChanged(title: String, start: Date, end: Date, allDay: Bool, moved: Bool,
                                    _ context: ToolContext) -> String
    {
        let when = span(start, end, allDay: allDay, context)
        switch context.language {
        case .french: return "C’est \(moved ? "déplacé" : "modifié")\(nb): \(title), \(when)."
        case .english: return "\(moved ? "Moved" : "Changed"): \(title), \(when)."
        }
    }

    public static func reminderChanged(title: String, due: Date?, hasTime: Bool, moved: Bool,
                                       _ context: ToolContext) -> String
    {
        let when = due.map { ", " + moment($0, hasTime: hasTime, context) } ?? ""
        switch context.language {
        case .french: return "C’est \(moved ? "déplacé" : "modifié")\(nb): \(title)\(when)."
        case .english: return "\(moved ? "Moved" : "Changed"): \(title)\(when)."
        }
    }

    public static func deleted(event: Bool, title: String, _ language: SpeechLanguage) -> String {
        switch language {
        case .french: "C’est fait, j’ai supprimé \(event ? "l’événement" : "le rappel")\(nb): \(title)."
        case .english: "Done, I deleted the \(event ? "event" : "reminder"): \(title)."
        }
    }

    public enum UndoneKind { case event, reminder, change, timer }

    public static func undone(_ kind: UndoneKind, _ language: SpeechLanguage) -> String {
        switch (kind, language) {
        case (.event, .french): "C’est annulé\(nb): j’ai retiré l’événement."
        case (.reminder, .french): "C’est annulé\(nb): j’ai retiré le rappel."
        case (.change, .french): "C’est annulé\(nb): tout est revenu comme avant."
        case (.timer, .french): "C’est annulé, j’ai arrêté le minuteur."
        case (.event, .english): "Cancelled: I removed the event."
        case (.reminder, .english): "Cancelled: I removed the reminder."
        case (.change, .english): "Cancelled: everything is back as before."
        case (.timer, .english): "Cancelled, I stopped the timer."
        }
    }

    /// One event or reminder in a reading: its title and when.
    public struct Item: Sendable {
        public var title: String
        public var date: Date?
        public var hasTime: Bool
        public init(title: String, date: Date?, hasTime: Bool) {
            self.title = title
            self.date = date
            self.hasTime = hasTime
        }
    }

    /// "Demain, tu as trois choses : …" (four at most, then how many more).
    public static func agenda(_ items: [Item], from start: Date, to end: Date, _ context: ToolContext) -> String {
        let opening = period(start, end, context)
        let singleDay = context.calendar.isDate(start, inSameDayAs: end > start ? end.addingTimeInterval(-1) : start)
        let read = items.prefix(4).map { describe($0, withDay: !singleDay, context) }
        switch context.language {
        case .french:
            if items.isEmpty { return "\(opening), rien de prévu dans ton agenda." }
            let amount = items.count == 1 ? "une seule chose" : "\(count(items.count, feminine: true)) choses"
            return "\(opening), tu as \(amount)\(nb): \(list(read, .french, more: items.count - read.count))."
        case .english:
            if items.isEmpty { return "\(opening), nothing is planned in your calendar." }
            let amount = items.count == 1 ? "just one thing" : "\(count(items.count, english: true)) things"
            return "\(opening), you have \(amount): \(list(read, .english, more: items.count - read.count))."
        }
    }

    /// "Tu as deux rappels pour demain : …"; without a period, every reminder still to do. Reminders left over
    /// from before the period (overdue) are only counted after the others: "…, plus trois en retard."
    public static func reminders(_ items: [Item], from start: Date?, to end: Date?, _ context: ToolContext) -> String {
        let french = context.language == .french
        var scope = ""
        var singleDay = false
        var due = items
        var late: [Item] = []
        if let start, let end {
            let opening = period(start, end, context)
            singleDay = context.calendar.isDate(start, inSameDayAs: end > start ? end.addingTimeInterval(-1) : start)
            switch opening {
            case "Aujourd’hui": scope = " pour aujourd’hui"
            case "Demain": scope = " pour demain"
            case "Today": scope = " for today"
            case "Tomorrow": scope = " for tomorrow"
            default: scope = french ? (singleDay ? " pour le " : " ") + lowercasedFirst(opening)
                : (singleDay ? " for " : " ") + lowercasedFirst(opening)
            }
            let firstDay = context.calendar.startOfDay(for: start)
            late = items.filter { ($0.date ?? .distantFuture) < firstDay }.reversed()  // the most recent first
            due = items.filter { ($0.date ?? .distantFuture) >= firstDay }
        }
        if due.isEmpty, !late.isEmpty {
            let read = late.prefix(4).map { describe($0, withDay: true, allDay: false, context) }
            let more = late.count - read.count
            return french
                ? "Rien de prévu\(scope), mais \(late.count == 1 ? "un rappel" : "\(count(late.count)) rappels") en "
                    + "retard\(nb): \(list(read, .french, more: more))."
                : "Nothing\(scope), but \(late.count == 1 ? "one overdue reminder" : "\(count(late.count, english: true)) overdue reminders"): "
                    + "\(list(read, .english, more: more))."
        }
        let read = due.prefix(4).map { describe($0, withDay: !singleDay, allDay: false, context) }
        let more = due.count - read.count
        if french {
            if due.isEmpty { return "Tu n’as aucun rappel en cours\(scope)." }
            let amount = due.count == 1 ? "un seul rappel" : "\(count(due.count, feminine: false)) rappels"
            let overdue = late.isEmpty ? "" : ", plus \(count(late.count)) en retard"
            return "Tu as \(amount)\(scope)\(nb): \(list(read, .french, more: more))\(overdue)."
        }
        if due.isEmpty { return "You have no reminders to do\(scope)." }
        let amount = due.count == 1 ? "just one reminder" : "\(count(due.count, english: true)) reminders"
        let overdue = late.isEmpty ? "" : ", plus \(count(late.count, english: true)) overdue"
        return "You have \(amount)\(scope): \(list(read, .english, more: more))\(overdue)."
    }

    /// `allDay`: an event without a time is said "toute la journée"; a reminder without a time, just by its title.
    private static func describe(_ item: Item, withDay: Bool, allDay: Bool = true, _ context: ToolContext) -> String {
        guard let date = item.date else { return item.title }
        let french = context.language == .french
        if !item.hasTime {
            if withDay { return "\(item.title) \(french ? "le" : "on") \(day(date, context))" }
            return allDay ? "\(item.title) \(french ? "toute la journée" : "all day")" : item.title
        }
        let at = french ? "à" : "at"
        guard withDay else { return "\(item.title) \(at) \(time(date, context))" }
        return "\(item.title) \(french ? "le" : "on") \(day(date, context)) \(at) \(time(date, context))"
    }

    // MARK: - Timers

    public static func timerStarted(seconds: Int, label: String?, _ language: SpeechLanguage) -> String {
        let length = duration(seconds: seconds, language)
        switch language {
        case .french:
            return "C’est parti pour \(length)" + (label.map { "\(nb): \($0)" } ?? "") + ". Je te préviens à la fin."
        case .english:
            return "Timer started for \(length)" + (label.map { ": \($0)" } ?? "") + ". I’ll tell you when it’s done."
        }
    }

    public static func timerFinished(seconds: Int, label: String?, _ language: SpeechLanguage) -> String {
        let length = duration(seconds: seconds, language)
        switch language {
        case .french: return "Ton minuteur de \(length) est terminé" + (label.map { "\(nb): \($0)" } ?? "") + "."
        case .english: return "Your timer of \(length) is done" + (label.map { ": \($0)" } ?? "") + "."
        }
    }

    // MARK: - Shortcuts

    public static func shortcutDone(name: String, output: String?, _ language: SpeechLanguage) -> String {
        let done = language == .french ? "C’est fait, j’ai lancé «\(quoted(name))»." : "Done, I ran the shortcut “\(name)”."
        guard let output = output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else { return done }
        if output.count < 200 {
            return wordCount(output) >= 5 ? output : String(done.dropLast()) + "\(language == .french ? nb : ""): \(output)"
        }
        return done + " " + firstSentence(output)
    }

    public static func confirmShortcut(name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Je lance le raccourci «\(quoted(name))». On y va\(nb)?"
            : "I’ll run the shortcut “\(name)”. Shall I go ahead?"
    }

    public static func shortcutTimedOut(name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Le raccourci «\(quoted(name))» n’a pas répondu à temps."
            : "The shortcut “\(name)” did not answer in time."
    }

    public static func shortcutFailed(name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Le raccourci «\(quoted(name))» n’a pas marché, désolée."
            : "The shortcut “\(name)” did not work, sorry."
    }

    public static func cannotUndoShortcut(_ language: SpeechLanguage) -> String {
        language == .french ? "Je ne peux pas défaire un raccourci." : "I can’t undo a shortcut, sorry."
    }

    // MARK: - Confirmation, refusals, permissions

    /// Said while the model writes its call (about 1.5 s with the largest model), so the user is not left in silence.
    public static func oneMoment(_ language: SpeechLanguage) -> String {
        language == .french ? "Un instant, je m’en occupe tout de suite." : "One moment, I’m taking care of it."
    }

    public static func declined(_ language: SpeechLanguage) -> String {
        language == .french ? "D’accord, je ne fais rien." : "Okay, I won’t do anything."
    }

    public static func cannotUndo(_ language: SpeechLanguage) -> String {
        language == .french ? "Je ne peux pas défaire cette action." : "I can’t undo that action, sorry."
    }

    public static func oneThingAtATime(_ language: SpeechLanguage) -> String {
        language == .french ? "Je fais une chose à la fois\(nb): redis-moi la suite."
            : "I do one thing at a time: tell me the rest again."
    }

    public static func badTime(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas bien compris l’heure. Tu peux répéter\(nb)?"
            : "I didn’t quite get the time. Can you say it again?"
    }

    public static func datePassed(_ language: SpeechLanguage) -> String {
        language == .french ? "Cette date est déjà passée. Tu peux me redire quand\(nb)?"
            : "That date has already passed. When do you mean?"
    }

    public static func dateTooFar(_ language: SpeechLanguage) -> String {
        language == .french ? "C’est dans plus d’un an. Tu peux me redire la date\(nb)?"
            : "That’s more than a year away. Can you repeat the date?"
    }

    /// "Tu veux dire 3 h du matin, ou 15 h ?": an hour from 1 to 7 said without the morning or the afternoon.
    public static func morningOrAfternoon(hour: Int, minute: Int, _ context: ToolContext) -> String {
        let calendar = context.calendar
        let day = calendar.startOfDay(for: context.now)
        let morning = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        let afternoon = morning.addingTimeInterval(12 * 3600)
        return context.language == .french
            ? "Tu veux dire \(time(morning, context)), ou \(time(afternoon, context))\(nb)?"
            : "Do you mean \(time(morning, context)) or \(time(afternoon, context))?"
    }

    /// "Le 22 octobre tombe un jeudi. Tu peux me redire la date ?"
    public static func wrongWeekday(_ date: Date, _ context: ToolContext) -> String {
        context.language == .french
            ? "Le \(dayOfMonth(date, context)) tombe un \(weekday(date, context)). Tu peux me redire la date\(nb)?"
            : "\(dayOfMonth(date, context)) is a \(weekday(date, context)). Which date do you mean?"
    }

    public static func earlierOrLater(_ language: SpeechLanguage) -> String {
        language == .french ? "Plus tôt ou plus tard\(nb)? Tu peux préciser\(nb)?" : "Earlier or later? Can you tell me more?"
    }

    public static func badDuration(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas compris la durée. Tu peux répéter\(nb)?"
            : "I didn’t get the duration. Can you say it again?"
    }

    public static func missingTitle(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas compris quoi noter. Tu peux répéter\(nb)?"
            : "I didn’t get what to write down. Can you say it again?"
    }

    public static func unknownCalendar(_ name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Je ne trouve pas le calendrier «\(quoted(name))». Tu peux me redire son nom\(nb)?"
            : "I can’t find the calendar “\(name)”. What is it called?"
    }

    public static func unknownList(_ name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Je ne trouve pas la liste «\(quoted(name))». Tu peux me redire son nom\(nb)?"
            : "I can’t find the list “\(name)”. What is it called?"
    }

    public static func unknownShortcut(_ name: String, _ language: SpeechLanguage) -> String {
        language == .french ? "Je ne trouve pas le raccourci «\(quoted(name))» dans le dossier OpenMaé."
            : "I can’t find the shortcut “\(name)” in the OpenMaé folder."
    }

    public static func nothingToChange(_ language: SpeechLanguage) -> String {
        language == .french ? "Je ne retrouve pas ce que tu veux changer. Tu peux préciser\(nb)?"
            : "I can’t find what you want to change. Can you tell me more?"
    }

    public static func notUnderstood(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas bien compris. Tu peux le dire autrement\(nb)?"
            : "I didn’t quite understand. Can you say it differently?"
    }

    public static func saveFailed(_ language: SpeechLanguage) -> String {
        language == .french ? "Je n’ai pas réussi à l’enregistrer. Tu peux réessayer\(nb)?"
            : "I couldn’t save it, sorry. Can you try again?"
    }

    public enum Access { case calendar, reminders }

    /// Said just before macOS shows its permission dialog.
    public static func askingAccess(_ access: Access, _ language: SpeechLanguage) -> String {
        switch (access, language) {
        case (.calendar, .french): "Il me faut l’accès à ton calendrier\(nb): macOS va te le demander."
        case (.reminders, .french): "Il me faut l’accès à tes rappels\(nb): macOS va te le demander."
        case (.calendar, .english): "I need access to your calendar: macOS is going to ask you."
        case (.reminders, .english): "I need access to your reminders: macOS is going to ask you."
        }
    }

    public static func accessDenied(_ access: Access, _ language: SpeechLanguage) -> String {
        switch (access, language) {
        case (.calendar, .french):
            "Sans accès à ton calendrier, je ne peux pas le faire. Tu peux l’autoriser dans Réglages Système, Confidentialité."
        case (.reminders, .french):
            "Sans accès à tes rappels, je ne peux pas le faire. Tu peux l’autoriser dans Réglages Système, Confidentialité."
        case (.calendar, .english):
            "Without access to your calendar, I can’t do that. You can allow it in System Settings, Privacy."
        case (.reminders, .english):
            "Without access to your reminders, I can’t do that. You can allow it in System Settings, Privacy."
        }
    }

    // MARK: - Helpers

    /// "a, b et c"; with `more`, "a, b, c, d et deux autres".
    static func list(_ parts: [String], _ language: SpeechLanguage, more: Int = 0) -> String {
        let and = language == .french ? " et " : " and "
        var parts = parts
        if more > 0 {
            parts.append(language == .french
                         ? (more == 1 ? "une autre" : "\(count(more, feminine: true)) autres")
                         : (more == 1 ? "one more" : "\(count(more, english: true)) more"))
        }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + and + parts.last!
    }

    private static let frenchNumbers = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit",
                                        "neuf", "dix"]
    private static let englishNumbers = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                         "nine", "ten"]

    static func count(_ n: Int, feminine: Bool = false, english: Bool = false) -> String {
        guard n <= 10 else { return String(n) }
        if english { return englishNumbers[n] }
        return n == 1 && feminine ? "une" : frenchNumbers[n]
    }

    /// Inside French guillemets, with non-breaking spaces.
    private static func quoted(_ text: String) -> String { "\(nb)\(text)\(nb)" }

    private static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
    private static func lowercasedFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }

    static func wordCount(_ text: String) -> Int {
        text.split { !($0.isLetter || $0 == "'" || $0 == "’" || $0 == "-") }.count
    }

    private static func firstSentence(_ text: String) -> String {
        guard let end = text.firstIndex(where: { ".!?…".contains($0) }) else { return String(text.prefix(200)) }
        return String(text[...end])
    }
}
