import Foundation

/// Dates, times and lengths as French speakers say them — "samedi à 20 h", "demain matin", "dans 20 minutes",
/// "le 3 novembre", "midi et demi", "une heure et quart" — worked out by the app instead of the language model.
/// The model only copies the user's words into its tool call (`quand`, `duree`): the smaller models often get a
/// date wrong when they compute it themselves (a Sunday placed on the wrong day, an hour and a quarter taken for an
/// hour and a half), while these rules read the same words the same way every time.
///
/// What a model may write instead of the user's words is read too: an ISO date ("2026-10-17T20:00"), "17/10",
/// "20h00".
///
/// Where French leaves a choice:
/// - a weekday is the next one ("samedi", "ce samedi", "samedi prochain"), today's weekday meaning next week's;
///   "samedi en huit" is the one after, "samedi de la semaine prochaine" the one of next week (Monday to Sunday);
/// - a date without a year is the next one ("le 12 juin" said in October is next June); without a month, this
///   month's, or next month's once it has passed;
/// - a time without a day is the next one: "à 23 h" said in the evening is tonight, "à 9 h" tomorrow morning;
/// - an hour from 1 to 7 said without "du matin", "de l'après-midi", "ce soir"… could be either: it is not guessed
///   (`Problem.ambiguousHour`, the user is asked). From 8 to 12 it is the morning, as in spoken French;
/// - a part of the day alone is a usual hour: the morning 9:00, the afternoon 14:00, the end of the afternoon
///   17:00, the evening 19:00, the night 22:00 — or the next full hour, once that part of today has begun.
public enum FrenchDates {
    /// When something happens, and the end or the length the words give.
    public struct Moment: Sendable, Equatable {
        public var start: Date
        /// false for a day alone ("vendredi"): a reminder without a time, an event for the whole day.
        public var hasTime: Bool
        /// The end the words give: "de 10 h à midi" (noon), "du 20 au 24 décembre" (the 25th at midnight).
        public var end: Date?
        /// The length the words give ("pendant une heure et demie"), in seconds.
        public var duration: Int?

        public init(start: Date, hasTime: Bool, end: Date? = nil, duration: Int? = nil) {
            self.start = start
            self.hasTime = hasTime
            self.end = end
            self.duration = duration
        }
    }

    /// An item being changed, as it is now: "à 16 h" keeps its day, "à la même heure" its time, "une heure plus
    /// tard" moves it from there.
    public struct Base: Sendable, Equatable {
        public var date: Date
        public var hasTime: Bool

        public init(date: Date, hasTime: Bool) {
            self.date = date
            self.hasTime = hasTime
        }
    }

    public enum Problem: Error, Sendable, Equatable {
        /// Nothing says when.
        case notUnderstood
        /// "à 3 h": three in the morning, or in the afternoon?
        case ambiguousHour(hour: Int, minute: Int)
        /// "dimanche 22 octobre" when the 22nd is a Thursday: that date, which falls on another weekday.
        case wrongWeekday(Date)
        /// Two different days or times ("demain samedi").
        case contradiction
        /// A length alone for a change ("d'une heure"): earlier or later?
        case noDirection
    }

    /// "samedi à 20 h", "demain de 10 h à midi", "le 3 novembre", "dans 20 minutes". `base`: the item a change
    /// starts from.
    public static func moment(_ text: String, now: Date, calendar: Calendar, base: Base? = nil) throws -> Moment {
        try Resolver(now: now, calendar: calendar, base: base).moment(Parser(tokens(text)).parse())
    }

    /// The period a reading covers: "demain", "samedi", "cette semaine", "ce soir", "du 20 au 24 décembre".
    public static func period(_ text: String, now: Date, calendar: Calendar) throws -> (start: Date, end: Date) {
        try Resolver(now: now, calendar: calendar, base: nil).period(Parser(tokens(text)).parse())
    }

    /// "10 minutes", "une heure et quart", "1 h 30", "trois quarts d'heure", in seconds (a day counts 24 hours).
    /// nil without a unit, or for months and years.
    public static func duration(_ text: String) -> Int? {
        let parser = Parser(tokens(text))
        for index in parser.tokens.indices {
            if let (span, _) = parser.span(at: index) {
                return span.months == 0 ? span.days * 86_400 + span.seconds : nil
            }
        }
        return nil
    }

    // MARK: - Whether the words are the user's

    /// Whether every word of `text` that says when — a day, a month, a number, a part of the day, a unit — is one the
    /// user said (`said`: their messages, the latest first). false when the model changed them: "demain" became
    /// "vendredi", a day taken from the date line, a date it worked out itself.
    public static func wordsAreTheUser(_ text: String, said: [String]) -> Bool {
        let theirs = Set(said.flatMap { tokens($0) }.compactMap(meaning))
        return tokens(text).compactMap(meaning).allSatisfy(theirs.contains)
    }

    /// The words of `text` that do not say when, in lower case and without accents, elisions and hyphens apart
    /// (« rappelle-moi » is « rappelle », « moi »; « d'appeler » is « d' », « appeler »): every word but the numbers,
    /// dates, days, months, parts of the day, units and words like « demain » that `wordsAreTheUser` compares.
    /// « Rappel demain à 9 h » gives « rappel », « a ».
    public static func wordsBesidesWhen(_ text: String) -> [String] {
        tokens(text).compactMap { token in
            guard case .word(let word) = token, meaning(token) == nil else { return nil }
            return word
        }
    }

    /// Whether a sentence says when by itself — a day, a time, a date, "dans 20 minutes" — and not only a part of
    /// it ("de l'après-midi", the answer to a question).
    public static func saysWhen(_ text: String) -> Bool {
        let p = Parser(tokens(text)).parse()
        return !p.days.isEmpty || !p.clocks.isEmpty || p.offset != nil || p.shift != nil || p.period != nil
            || p.endDay != nil
    }

    /// Whether words say when relative to something the app cannot place in time — « après le travail », « avant
    /// de partir », « en sortant du bureau », « dès que je rentre » — and give no hour of their own (`saysTheHour`):
    /// « jeudi après le travail » gives the day, never the hour. `moment` reads such words without that part
    /// (« jeudi », the whole day; « après le travail » alone is `Problem.notUnderstood`): right for a forecast's day,
    /// not for an event.
    public static func leavesTheHourOpen(_ text: String) -> Bool {
        let p = Parser(tokens(text)).parse()
        return p.unplaced && !p.saysTheHour
    }

    /// Whether words say the hour: an hour (« à 18 h »), a part of the day (« jeudi soir »), « dans 20 minutes »,
    /// « une heure plus tard », « à la même heure ».
    public static func saysTheHour(_ text: String) -> Bool {
        Parser(tokens(text)).parse().saysTheHour
    }

    /// Whether words give the hour of a day they leave out: an hour (« à 18 h », « de 18 h à 19 h »), a part of the
    /// day (« le soir ») — the answer to « À quelle heure ? ». Not with a day of their own (« demain à 18 h », « jeudi
    /// soir », « ce soir »), a date or a period, nor an hour counted from now or from the item (« dans 20 minutes »,
    /// « une heure plus tard », « à la même heure »).
    public static func saysOnlyTheHour(_ text: String) -> Bool {
        let p = Parser(tokens(text)).parse()
        return (!p.clocks.isEmpty || !p.parts.isEmpty) && p.days.isEmpty && p.endDay == nil && p.period == nil
            && p.offset == nil && p.shift == nil && !p.sameTime
    }

    /// The length a sentence says ("mets un minuteur d'une heure et quart" → 4500 s), not counting times of day.
    public static func lengthSaid(_ text: String) -> Int? {
        let p = Parser(tokens(text)).parse()
        return (p.duration ?? p.looseSpan)?.totalSeconds
    }

    /// What a token says, for comparing words: numbers, days, months, parts of the day and units, in one spelling
    /// ("15 h" and "quinze heures" say the same). nil for the other words.
    private static func meaning(_ token: Token) -> String? {
        switch token {
        case .number(let n): return "#\(n)"
        case .iso, .numeric: return "\(token)"  // the model's way: never said
        case .word(let word):
            if let unit = Parser.units[word] { return "\(unit)" }
            if let month = Parser.months[word] { return "month \(month)" }
            switch word {
            case "matin", "matinee", "mat": return "matin"
            case "soir", "soiree": return "soir"
            case "demi", "demie": return "demi"
            case "prochain", "prochaine": return "prochain"
            case "dernier", "derniere": return "dernier"
            case ":": return "\(Parser.Unit.hour)"
            default:
                return meaningful.contains(word) || Parser.weekdays[word] != nil ? word : nil
            }
        }
    }

    private static let meaningful: Set<String> = [
        "aujourd'hui", "demain", "apres-demain", "hier", "avant-hier", "lendemain", "surlendemain", "veille",
        "avant-veille", "apres-midi", "nuit", "midi", "minuit", "quart", "week-end", "noel", "toussaint",
        "saint-valentin", "maintenant",
    ]

    // MARK: - From text to tokens

    fileprivate enum Token: Equatable {
        case number(Int)
        case word(String)
        /// "2026-10-17", "2026-10-17T20:00": the model's way, never the user's.
        case iso(year: Int, month: Int, day: Int, hour: Int?, minute: Int?)
        /// "17/10", "17/10/2026".
        case numeric(day: Int, month: Int, year: Int?)
    }

    /// Lower case, without accents; numbers spelled out become numbers ("dix-sept" → 17, "vingt et un" → 21);
    /// "15h30" is 15, "h", 30; "d'une" is "d'", 1; "l'après-midi" is "l'", "apres-midi".
    fileprivate static func tokens(_ text: String) -> [Token] {
        var text = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        for (from, to) in [("’", "'"), ("‘", "'"), ("ʼ", "'"), ("`", "'"), ("´", "'"), ("\u{00A0}", " "),
                           ("\u{202F}", " ")]
        {
            text = text.replacingOccurrences(of: from, with: to)
        }
        var tokens: [Token] = []
        var rest = text[...]
        // ISO and numeric dates first: their dashes and slashes mean something else elsewhere.
        while let (range, token) = special(in: rest) {
            tokens += plain(rest[..<range.lowerBound])
            tokens.append(token)
            rest = rest[range.upperBound...]
        }
        return tokens + plain(rest)
    }

    private static func special(in text: Substring) -> (Range<String.Index>, Token)? {
        var found: (Range<String.Index>, Token)?
        let iso = #"(\d{4})-(\d{1,2})-(\d{1,2})(?:[t ](\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?)?(?:z|[+-]\d{2}:?\d{2})?"#
        if let regex = try? Regex(iso), let match = try? regex.firstMatch(in: text) {
            func number(_ i: Int) -> Int? { match.output[i].substring.flatMap { Int($0) } }
            if let year = number(1), let month = number(2), let day = number(3) {
                found = (match.range, .iso(year: year, month: month, day: day, hour: number(4), minute: number(5)))
            }
        }
        if let regex = try? Regex(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\b"#),
           let match = try? regex.firstMatch(in: text), found.map({ match.range.lowerBound < $0.0.lowerBound }) ?? true
        {
            func number(_ i: Int) -> Int? { match.output[i].substring.flatMap { Int($0) } }
            if let day = number(1), let month = number(2) {
                let year = number(3).map { $0 < 100 ? 2000 + $0 : $0 }
                found = (match.range, .numeric(day: day, month: month, year: year))
            }
        }
        return found
    }

    private static func plain(_ text: Substring) -> [Token] {
        var words: [String] = []
        var run = ""
        var digits = false
        func flush() {
            if !run.isEmpty { words += digits ? [run] : split(run) }
            if !digits, run.count > 1, run.hasSuffix("-") { words.append("-") }  // "10h-12h"
            run = ""
        }
        for c in text {
            if c.isASCII, c.isNumber {
                if !digits { flush() }
                digits = true
                run.append(c)
            } else if c.isLetter || ((c == "'" || c == "-") && !run.isEmpty && !digits) {
                if digits { flush() }
                digits = false
                run.append(c)
            } else {
                flush()
                // "15:30", "10 h - 12 h"; a comma ends a time ("à 9 h, 30 minutes").
                if c == ":" || c == "-" || c == "," || c == ";" { words.append(c == ";" ? "," : String(c)) }
            }
        }
        flush()
        return numbers(merged(words))
    }

    private static let compounds: Set<String> = ["aujourd'hui", "apres-demain", "apres-midi", "avant-hier",
                                                 "avant-veille", "week-end", "demi-heure", "demi-heures",
                                                 "saint-valentin"]

    /// Elisions ("d'une", "jusqu'au") and hyphens ("mi-novembre", "mets-le") apart, except in compound words and
    /// spelled numbers ("après-midi", "dix-sept").
    private static func split(_ run: String) -> [String] {
        var word = run
        while word.first == "'" || word.first == "-" { word.removeFirst() }
        while word.last == "-" { word.removeLast() }
        guard !word.isEmpty else { return [] }
        if compounds.contains(word) || numberValue(word) != nil { return [word] }
        if word.hasSuffix("aujourd'hui") { return split(String(word.dropLast(11))) + ["aujourd'hui"] }
        if let apostrophe = word.firstIndex(of: "'") {
            return [String(word[...apostrophe])] + split(String(word[word.index(after: apostrophe)...]))
        }
        if word.contains("-") { return word.split(separator: "-").flatMap { split(String($0)) } }
        return [word]
    }

    private static let pairs: [String: [String: String]] = [
        "apres": ["midi": "apres-midi", "demain": "apres-demain"],
        "avant": ["hier": "avant-hier", "veille": "avant-veille"],
        "week": ["end": "week-end"],
        "demi": ["heure": "demi-heure", "heures": "demi-heures"],
        "saint": ["valentin": "saint-valentin"],
        "aujourd": ["hui": "aujourd'hui"],
    ]

    /// Compound words written apart ("après midi", "week end") and "aprèm".
    private static func merged(_ words: [String]) -> [String] {
        var out: [String] = []
        for word in words {
            if let last = out.last, let joined = pairs[last]?[word] {
                out[out.count - 1] = joined
            } else {
                out.append(word == "aprem" || word == "aprems" ? "apres-midi" : word)
            }
        }
        return out
    }

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8,
        "neuf": 9, "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16,
        "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
    ]

    /// "dix-sept" → 17, "vingt-et-un" → 21, "quatre-vingt-dix" → 90.
    private static func numberValue(_ word: String) -> Int? {
        let parts = word.split(separator: "-").map(String.init).filter { $0 != "et" }
        guard !parts.isEmpty else { return nil }
        var total = 0
        var last = 0
        for part in parts {
            guard let value = smallNumbers[part] else { return nil }
            total += value == 20 && last == 4 ? 80 - 4 : value  // "quatre-vingt"
            last = value
        }
        return total
    }

    /// Digits and spelled numbers, the latter joined when written apart: "vingt et un", "trente cinq",
    /// "soixante dix", "quatre vingt", "dix sept".
    private static func numbers(_ words: [String]) -> [Token] {
        func spelled(_ k: Int) -> Int? {
            guard words.indices.contains(k), words[k].first?.isNumber == false else { return nil }
            return numberValue(words[k])
        }
        var tokens: [Token] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            i += 1
            if let value = Int(word) {
                tokens.append(.number(value))
                continue
            }
            guard var n = numberValue(word) else {
                tokens.append(.word(word))
                continue
            }
            if n == 4, spelled(i) == 20 {
                n = 80
                i += 1
            }
            if n == 10, let unit = spelled(i), (7...9).contains(unit) {
                n += unit
                i += 1
            } else if [20, 30, 40, 50, 60, 80].contains(n) {
                let k = words.indices.contains(i) && words[i] == "et" ? i + 1 : i
                if let unit = spelled(k), (1...9).contains(unit) || ([60, 80].contains(n) && (10...19).contains(unit)) {
                    n += unit
                    i = k + 1
                }
            }
            tokens.append(.number(n))
        }
        return tokens
    }

    // MARK: - From tokens to what they say

    fileprivate enum Part: Equatable {
        case morning, afternoon, lateAfternoon, evening, night
    }

    /// Which weekday of that name.
    fileprivate enum Rule: Equatable {
        /// The next one: "samedi", "samedi prochain", "ce samedi".
        case coming
        /// "samedi en huit" (1), "en quinze" (2).
        case weeksLater(Int)
        /// "samedi de la semaine prochaine".
        case nextWeek
        /// "samedi de cette semaine".
        case thisWeek
        /// "samedi dernier".
        case last
    }

    fileprivate enum Day: Equatable {
        /// From today: "demain" is 1.
        case relative(Int)
        /// From the item being changed: "le lendemain" is 1.
        case fromBase(Int)
        /// Calendar weekday: 1 is Sunday.
        case weekday(Int, Rule)
        case date(day: Int, month: Int?, year: Int?, weekday: Int?)
        /// "début novembre" (1), "mi-novembre" (2), "fin novembre" (3).
        case monthPart(month: Int, part: Int)
    }

    fileprivate enum Period: Equatable {
        case thisWeek, nextWeek, lastWeek, weekend(next: Bool), thisMonth, nextMonth, month(Int), comingDays(Int)
    }

    fileprivate struct Clock: Equatable {
        var hour: Int
        var minute: Int
        /// "du matin", "de l'après-midi", "du soir"…
        var part: Part?
        /// "midi", "minuit".
        var named = false
        /// Written on a 24-hour clock by the model (ISO): never ambiguous.
        var exact = false
        /// The hour as said, before "moins le quart" (whether it is one of the ambiguous ones).
        var said: Int
    }

    fileprivate struct Span: Equatable {
        var months = 0
        var days = 0
        var seconds = 0
        var underADay: Bool { months == 0 && days == 0 }
        var totalSeconds: Int? { months == 0 ? days * 86_400 + seconds : nil }
    }

    /// Everything the words say, before it is placed in time.
    fileprivate struct Parsed {
        var days: [Day] = []
        var clocks: [Clock] = []
        var endClock: Clock?
        var endDay: Day?
        var parts: [Part] = []
        /// "dans 20 minutes", "maintenant" (zero).
        var offset: Span?
        /// "une heure plus tard" (later), "deux jours plus tôt".
        var shift: (span: Span, later: Bool)?
        /// "pendant une heure et demie".
        var duration: Span?
        /// A length said alone, or after "de" ("d'une heure", "30 minutes"): an event's length, or a change without
        /// a direction.
        var looseSpan: Span?
        var sameTime = false
        var period: Period?
        var allDay = false
        /// Words that say when relative to something the app cannot place: « après le travail » (`Parser.unplaced`).
        var unplaced = false

        /// An hour, a part of the day, a time from now or from the item ("dans 20 minutes", "une heure plus tard"),
        /// "à la même heure"; not a day alone, nor "dans deux jours".
        var saysTheHour: Bool {
            !clocks.isEmpty || !parts.isEmpty || sameTime || shift != nil || (offset?.underADay ?? false)
        }
    }

    fileprivate struct Parser {
        let tokens: [Token]

        init(_ tokens: [Token]) { self.tokens = tokens }

        func word(_ i: Int) -> String? {
            guard tokens.indices.contains(i), case .word(let word) = tokens[i] else { return nil }
            return word
        }

        func number(_ i: Int) -> Int? {
            guard tokens.indices.contains(i), case .number(let number) = tokens[i] else { return nil }
            return number
        }

        func isWord(_ i: Int, _ words: Set<String>) -> Bool { word(i).map(words.contains) ?? false }

        enum Unit { case second, minute, hour, day, week, month, year }

        static let units: [String: Unit] = [
            "s": .second, "sec": .second, "seconde": .second, "secondes": .second,
            "min": .minute, "mn": .minute, "minute": .minute, "minutes": .minute,
            "h": .hour, "heure": .hour, "heures": .hour,
            "jour": .day, "jours": .day, "journee": .day, "journees": .day,
            "semaine": .week, "semaines": .week, "mois": .month, "an": .year, "ans": .year, "annee": .year,
            "annees": .year,
        ]

        static let weekdays = ["dimanche": 1, "lundi": 2, "mardi": 3, "mercredi": 4, "jeudi": 5, "vendredi": 6,
                               "samedi": 7]

        static let months = ["janvier": 1, "janv": 1, "fevrier": 2, "fevr": 2, "fev": 2, "mars": 3, "avril": 4,
                             "avr": 4, "mai": 5, "juin": 6, "juillet": 7, "juil": 7, "aout": 8, "septembre": 9,
                             "octobre": 10, "oct": 10, "novembre": 11, "nov": 11, "decembre": 12, "dec": 12]

        static let minuteWords: Set<String> = ["minute", "minutes", "min", "mn"]
        static let secondWords: Set<String> = ["seconde", "secondes", "s", "sec"]

        func month(_ i: Int) -> Int? { word(i).flatMap { Self.months[$0] } }

        func year(_ i: Int) -> Int? { number(i).flatMap { (1900...2200).contains($0) ? $0 : nil } }

        // MARK: Lengths

        /// "une heure et quart", "1 h 30", "trois semaines", "une demi-heure", "trois quarts d'heure".
        func span(at start: Int) -> (Span, Int)? {
            var total = Span()
            var i = start
            var found = false
            while let (part, next) = spanPart(at: i) {
                total.months += part.months
                total.days += part.days
                total.seconds += part.seconds
                i = next
                found = true
                if word(i) == "et", spanPart(at: i + 1) != nil { i += 1 }  // "une heure et 15 minutes"
            }
            return found ? (total, i) : nil
        }

        private func spanPart(at i: Int) -> (Span, Int)? {
            var k = i
            var count = 1
            var counted = false
            if let n = number(k) {
                count = n
                counted = true
                k += 1
            }
            if isWord(k, ["demi-heure", "demi-heures"]) { return (Span(seconds: count * 1800), k + 1) }
            if isWord(k, ["quart", "quarts"]), isWord(k + 1, ["d'", "de"]), isWord(k + 2, ["heure", "heures"]) {
                return (Span(seconds: count * 900), k + 3)
            }
            guard counted, let name = word(k), let unit = Self.units[name] else { return nil }
            k += 1
            var span = Span()
            switch unit {
            case .second: span.seconds = count
            case .minute: span.seconds = count * 60
            case .hour: span.seconds = count * 3600
            case .day: span.days = count
            case .week: span.days = count * 7
            case .month: span.months = count
            case .year: span.months = count * 12
            }
            if word(k) == "et", isWord(k + 1, ["demi", "demie"]) {  // "une heure et demie"
                switch unit {
                case .second: break
                case .minute: span.seconds += 30
                case .hour: span.seconds += 1800
                case .day: span.seconds += 12 * 3600
                case .week: span.days += 3
                    span.seconds += 12 * 3600
                case .month: span.days += 15
                case .year: span.months += 6
                }
                k += 2
            } else if unit == .hour, word(k) == "et", word(k + 1) == "quart" {
                span.seconds += 900
                k += 2
            } else if unit == .hour, word(k) == "moins", isWord(k + 1, ["le", "quart"]) {  // "une heure moins le quart"
                let quarter = word(k + 1) == "le" ? k + 2 : k + 1
                guard word(quarter) == "quart" else { return (span, k) }
                span.seconds -= 900
                k = quarter + 1
            } else if unit == .hour || unit == .minute, let rest = number(k), (0..<60).contains(rest),
                      !(word(k + 1).map { Self.units[$0] != nil } ?? false)
                        || isWord(k + 1, unit == .hour ? Self.minuteWords : Self.secondWords)
            {
                // "1 h 30", "deux minutes trente": the next smaller unit, its name said or not.
                span.seconds += unit == .hour ? rest * 60 : rest
                k += 1
                if isWord(k, unit == .hour ? Self.minuteWords : Self.secondWords) { k += 1 }
            }
            return (span, k)
        }

        // MARK: Times of day

        /// "15 h", "15 h 30", "9 heures et demie", "8 h moins le quart", "midi et demi", "minuit", "3 h de
        /// l'après-midi".
        func clock(at i: Int) -> (Clock, Int)? {
            var k = i
            var clock: Clock
            if word(k) == "midi" {
                clock = Clock(hour: 12, minute: 0, named: true, said: 12)
                k += 1
            } else if word(k) == "minuit" {
                clock = Clock(hour: 24, minute: 0, named: true, said: 24)
                k += 1
            } else if let hour = number(k), (0...24).contains(hour), isWord(k + 1, ["h", "heure", "heures", ":"]) {
                clock = Clock(hour: hour, minute: 0, said: hour)
                k += 2
            } else {
                return nil
            }
            if word(k) == "et", word(k + 1) == "quart" {
                clock.minute = 15
                k += 2
            } else if word(k) == "et", isWord(k + 1, ["demi", "demie"]) {
                clock.minute = 30
                k += 2
            } else if word(k) == "moins" {
                var less: Int?
                var next = k + 1
                if word(next) == "le" { next += 1 }
                if word(next) == "quart" {
                    less = 15
                    next += 1
                } else if let n = number(k + 1), (1...30).contains(n) {
                    less = n
                    next = k + 2
                    if isWord(next, Self.minuteWords) { next += 1 }
                }
                if let less {
                    clock.hour -= 1
                    clock.minute = 60 - less
                    k = next
                }
            } else if let minute = number(k), (0...59).contains(minute),
                      !(word(k + 1).map { Self.units[$0] != nil && !Self.minuteWords.contains($0) } ?? false)
            {
                clock.minute = minute
                k += 1
                if isWord(k, Self.minuteWords) { k += 1 }
            }
            if let (part, next) = qualifier(at: k) {
                clock.part = part
                k = next
            }
            guard clock.hour >= 0 else { return nil }
            return (clock, k)
        }

        /// "du matin", "de l'après-midi", "du soir", "de la nuit".
        func qualifier(at k: Int) -> (Part, Int)? {
            if word(k) == "du", let part = partWord(k + 1), part == .morning || part == .evening { return (part, k + 2) }
            if word(k) == "de", word(k + 1) == "l'", word(k + 2) == "apres-midi" { return (.afternoon, k + 3) }
            if word(k) == "de", word(k + 1) == "la", let part = partWord(k + 2) { return (part, k + 3) }
            return nil
        }

        func partWord(_ k: Int) -> Part? {
            switch word(k) {
            case "matin", "matinee", "mat": .morning
            case "apres-midi": .afternoon
            case "soir", "soiree": .evening
            case "nuit": .night
            default: nil
            }
        }

        /// "de 10 h à midi", "entre 14 h et 16 h" (after "de" or "entre"), "10 à 12 h", "10 h - 12 h".
        func timeRange(at i: Int) -> (Clock, Clock, Int)? {
            var k = i
            var first: Clock
            if let (clock, next) = clock(at: k) {
                first = clock
                k = next
            } else if let hour = number(k), (0...24).contains(hour), isWord(k + 1, ["a", "-", "et", "jusqu'"]) {
                first = Clock(hour: hour, minute: 0, said: hour)
                k += 1
            } else {
                return nil
            }
            guard isWord(k, ["a", "-", "et", "jusqu'"]) else { return nil }
            k += word(k) == "jusqu'" && word(k + 1) == "a" ? 2 : 1
            guard let (second, next) = clock(at: k) else { return nil }
            if first.part == nil { first.part = second.part }  // "de 3 h à 5 h de l'après-midi"
            return (first, second, next)
        }

        // MARK: Days

        /// "3", "1er", "premier": a day of the month, when nothing after it makes it an hour or a length.
        func dayNumber(at k: Int) -> (Int, Int)? {
            if isWord(k, ["premier", "premiere"]) { return (1, k + 1) }
            guard let n = number(k), (1...31).contains(n) else { return nil }
            var next = k + 1
            if isWord(next, ["er", "re", "ere", "e", "eme"]) { next += 1 }
            if let after = word(next), Self.units[after] != nil || after == ":" { return nil }
            return (n, next)
        }

        func day(at i: Int) -> (Day, Int)? {
            let k = i
            if let token = tokens.indices.contains(k) ? tokens[k] : nil {
                switch token {
                case .iso(let year, let month, let day, _, _):
                    return (.date(day: day, month: month, year: year, weekday: nil), k + 1)
                case .numeric(let day, let month, let year):
                    return (.date(day: day, month: month, year: year, weekday: nil), k + 1)
                default: break
                }
            }
            if let name = word(k) {
                switch name {
                case "aujourd'hui": return (.relative(0), k + 1)
                case "demain": return (.relative(1), k + 1)
                case "apres-demain": return (.relative(2), k + 1)
                case "hier": return (.relative(-1), k + 1)
                case "avant-hier": return (.relative(-2), k + 1)
                case "lendemain": return (.fromBase(1), k + 1)
                case "surlendemain": return (.fromBase(2), k + 1)
                case "veille": return (.fromBase(-1), k + 1)
                case "avant-veille": return (.fromBase(-2), k + 1)
                case "noel": return (.date(day: 25, month: 12, year: nil, weekday: nil), k + 1)
                case "toussaint": return (.date(day: 1, month: 11, year: nil, weekday: nil), k + 1)
                case "saint-valentin": return (.date(day: 14, month: 2, year: nil, weekday: nil), k + 1)
                default: break
                }
                if name == "nouvel", word(k + 1) == "an" { return (.date(day: 1, month: 1, year: nil, weekday: nil), k + 2) }
                if name == "jour", word(k + 1) == "de", word(k + 2) == "l'", word(k + 3) == "an" {
                    return (.date(day: 1, month: 1, year: nil, weekday: nil), k + 4)
                }
                if let weekday = Self.weekdays[name] {
                    if let (n, next) = dayNumber(at: k + 1) {  // "samedi 12 juin", "vendredi 23"
                        var j = next
                        let month = self.month(j)
                        if month != nil { j += 1 }
                        let year = month == nil ? nil : self.year(j)
                        if year != nil { j += 1 }
                        return (.date(day: n, month: month, year: year, weekday: weekday), j)
                    }
                    var j = k + 1
                    let rule = self.rule(at: &j)
                    return (.weekday(weekday, rule), j)
                }
                if ["debut", "mi", "fin"].contains(name) {
                    let j = isWord(k + 1, ["de", "d'"]) ? k + 2 : k + 1
                    if let month = self.month(j) {
                        return (.monthPart(month: month, part: name == "debut" ? 1 : name == "mi" ? 2 : 3), j + 1)
                    }
                }
            }
            if let (n, next) = dayNumber(at: k), let month = self.month(next) {  // "3 novembre", "1er novembre 2026"
                let year = self.year(next + 1)
                return (.date(day: n, month: month, year: year, weekday: nil), next + (year == nil ? 1 : 2))
            }
            return nil
        }

        /// What follows a weekday: "prochain", "en huit", "de la semaine prochaine", "dernier"…
        private func rule(at j: inout Int) -> Rule {
            if isWord(j, ["prochain", "prochaine"]) {
                j += 1
                return .coming
            }
            if word(j) == "qui", isWord(j + 1, ["vient", "arrive"]) {
                j += 2
                return .coming
            }
            if word(j) == "en", number(j + 1) == 8 || number(j + 1) == 15 {
                defer { j += 2 }
                return .weeksLater(number(j + 1) == 8 ? 1 : 2)
            }
            if isWord(j, ["dernier", "derniere", "passe"]) {
                j += 1
                return .last
            }
            if isWord(j, ["de", "d'"]) {
                if word(j + 1) == "la", word(j + 2) == "semaine", isWord(j + 3, ["prochaine", "suivante"]) {
                    j += 4
                    return .nextWeek
                }
                if word(j + 1) == "cette", word(j + 2) == "semaine" {
                    j += 3
                    return .thisWeek
                }
            }
            return .coming
        }

        /// "du 20 au 24 décembre", "du lundi au mercredi", "entre le 3 et le 5 novembre" (after "du", "de", "entre").
        func dayRange(at i: Int) -> (Day, Day, Int)? {
            var k = word(i) == "le" ? i + 1 : i
            var first: Day
            if let (day, next) = day(at: k) {
                first = day
                k = next
            } else if let (n, next) = dayNumber(at: k) {
                first = .date(day: n, month: nil, year: nil, weekday: nil)
                k = next
            } else {
                return nil
            }
            guard isWord(k, ["au", "a", "et", "jusqu'"]) else { return nil }
            k += word(k) == "jusqu'" && isWord(k + 1, ["au", "a"]) ? 2 : 1
            if word(k) == "le" { k += 1 }
            let second: Day
            if let (day, next) = day(at: k) {
                second = day
                k = next
            } else if let (n, next) = dayNumber(at: k) {
                second = .date(day: n, month: nil, year: nil, weekday: nil)
                k = next
            } else {
                return nil
            }
            // "du 20 au 24 décembre": the first day takes the second's month and year.
            if case .date(let n, nil, nil, let weekday) = first, case .date(_, let month?, let year, _) = second {
                first = .date(day: n, month: month, year: year, weekday: weekday)
            }
            return (first, second, k)
        }

        // MARK: Periods

        /// "cette semaine", "la semaine prochaine", "ce week-end", "le mois prochain", "en novembre", "les 3
        /// prochains jours".
        func period(at i: Int) -> (Period, Int)? {
            let (w0, w1, w2) = (word(i), word(i + 1), word(i + 2))
            switch (w0, w1, w2) {
            case ("cette", "semaine", _): return (.thisWeek, i + 2)
            case ("la", "semaine", "prochaine"), ("la", "semaine", "suivante"): return (.nextWeek, i + 3)
            case ("semaine", "prochaine", _), ("semaine", "suivante", _): return (.nextWeek, i + 2)
            case ("la", "semaine", "derniere"): return (.lastWeek, i + 3)
            case ("semaine", "derniere", _): return (.lastWeek, i + 2)
            case ("ce", "week-end", _): return (.weekend(next: false), i + 2)
            case ("le", "week-end", "prochain"): return (.weekend(next: true), i + 3)
            case ("week-end", "prochain", _): return (.weekend(next: true), i + 2)
            case ("le", "week-end", _): return (.weekend(next: false), i + 2)
            case ("week-end", _, _): return (.weekend(next: false), i + 1)
            case ("ce", "mois", _): return (.thisMonth, w2 == "ci" ? i + 3 : i + 2)
            case ("le", "mois", "prochain"): return (.nextMonth, i + 3)
            case ("mois", "prochain", _): return (.nextMonth, i + 2)
            default: break
            }
            if w0 == "en", let month = self.month(i + 1) { return (.month(month), i + 2) }
            if let month = self.month(i) { return (.month(month), i + 1) }
            let k = w0 == "les" ? i + 1 : i
            if let n = number(k), isWord(k + 1, ["prochains", "prochaines"]), isWord(k + 2, ["jours"]) {
                return (.comingDays(n), k + 3)
            }
            if w0 == "les", isWord(i + 1, ["prochains"]), isWord(i + 2, ["jours"]) { return (.comingDays(7), i + 3) }
            return nil
        }

        // MARK: The whole text

        func parse() -> Parsed {
            var p = Parsed()
            var i = 0
            while i < tokens.count {
                let w = word(i)
                // An ISO date with its time.
                if case .iso(_, _, _, let hour?, let minute?) = tokens[i] {
                    if let (day, _) = day(at: i) { p.days.append(day) }
                    p.clocks.append(Clock(hour: hour, minute: minute, exact: true, said: hour))
                    i += 1
                    continue
                }
                // "dans 20 minutes", "dans la soirée", "dans les 3 prochains jours", "d'ici une heure".
                if w == "dans" || (w == "d'" && word(i + 1) == "ici") {
                    let k = w == "dans" ? i + 1 : i + 2
                    if isWord(k, ["la", "l'"]), let part = partWord(k + 1) {
                        p.parts.append(part)
                        i = k + 2
                        continue
                    }
                    if let (period, next) = period(at: k) {
                        p.period = period
                        i = next
                        continue
                    }
                    if let (span, next) = span(at: k) {
                        p.offset = span
                        i = next
                        continue
                    }
                }
                if isWord(i, ["pendant", "durant"]), let (span, next) = span(at: i + 1) {
                    p.duration = span
                    i = next
                    continue
                }
                if isWord(i, ["de", "des", "entre", "depuis"]), let (first, second, next) = timeRange(at: i + 1) {
                    p.clocks.append(first)
                    p.endClock = second
                    i = next
                    continue
                }
                if isWord(i, ["du", "de", "des", "entre", "depuis"]), let (first, second, next) = dayRange(at: i + 1) {
                    p.days.append(first)
                    p.endDay = second
                    i = next
                    continue
                }
                if w == "jusqu'" || w == "jusque" {
                    let k = isWord(i + 1, ["a", "au"]) ? i + 2 : i + 1
                    if let (clock, next) = clock(at: k) {
                        p.endClock = clock
                        i = next
                        continue
                    }
                    if let (day, next) = day(at: k) {
                        p.endDay = day
                        i = next
                        continue
                    }
                }
                if let (first, second, next) = timeRange(at: i) {  // "10 h - 12 h", "demain 10 h à 12 h"
                    p.clocks.append(first)
                    p.endClock = second
                    i = next
                    continue
                }
                if let (span, next) = span(at: i) {  // "une heure plus tard", "deux jours avant"
                    if word(next) == "plus", isWord(next + 1, ["tard", "tot"]) {
                        p.shift = (span, word(next + 1) == "tard")
                        i = next + 2
                        continue
                    }
                    // Not « à 18 h après le travail »: an hour, then words relative to something (18 hours later, it
                    // lost the day and the hour).
                    if isWord(next, ["apres", "avant"]), !unplaced(at: next) {
                        p.shift = (span, word(next) == "apres")
                        i = next + 1
                        continue
                    }
                }
                if w == "toute", word(i + 1) == "la", word(i + 2) == "journee" {
                    p.allDay = true
                    i += 3
                    continue
                }
                if w == "journee", word(i + 1) == "entiere" {
                    p.allDay = true
                    i += 2
                    continue
                }
                if w == "meme", isWord(i + 1, ["heure", "horaire"]) {  // "à la même heure"
                    p.sameTime = true
                    i += 2
                    continue
                }
                if isWord(i, ["maintenant", "immediatement"]) {
                    p.offset = Span()
                    i += 1
                    continue
                }
                if w == "tout", word(i + 1) == "de", word(i + 2) == "suite" {
                    p.offset = Span()
                    i += 3
                    continue
                }
                // A second time without "à" after a first one is a length: "vendredi à 18 h, une heure et demie".
                let lengthAfterTime = !p.clocks.isEmpty && !isWord(i - 1, ["a", "vers"])
                if !lengthAfterTime, let (clock, next) = clock(at: i) {
                    p.clocks.append(clock)
                    i = next
                    continue
                }
                if let (period, next) = period(at: i) {
                    p.period = period
                    i = next
                    continue
                }
                if isWord(i, ["ce", "cet", "cette"]), let part = partWord(i + 1) {  // "ce soir", "cet après-midi"
                    p.days.append(.relative(0))
                    p.parts.append(part)
                    i += 2
                    continue
                }
                if w == "ce", word(i + 1) == "midi" {
                    p.days.append(.relative(0))
                    i += 1
                    continue
                }
                if w == "le", let (day, next) = day(at: i + 1) ?? dayNumber(at: i + 1).map({
                    (Day.date(day: $0.0, month: nil, year: nil, weekday: nil), $0.1)
                }) {  // "le 3 novembre", "le 20", "le lendemain"
                    p.days.append(day)
                    i = next
                    continue
                }
                if let (day, next) = day(at: i) {
                    p.days.append(day)
                    i = next
                    continue
                }
                if w == "fin", isWord(i + 1, ["d'", "de"]), isWord(i + 2, ["apres-midi", "journee"]) {
                    p.parts.append(.lateAfternoon)
                    i += 3
                    continue
                }
                if let part = partWord(i) {
                    p.parts.append(part)
                    i += 1
                    continue
                }
                // "d'une heure", "de 30 minutes" are lengths; "de 10 h", a time.
                if isWord(i, ["de", "d'"]), let (span, next) = span(at: i + 1),
                   clock(at: i + 1).map({ $0.0.said < 8 && $0.0.part == nil && !$0.0.named }) ?? true
                {
                    p.looseSpan = span
                    i = next
                    continue
                }
                if let (span, next) = span(at: i) {  // "30 minutes"
                    p.looseSpan = span
                    i = next
                    continue
                }
                if unplaced(at: i) { p.unplaced = true }
                i += 1
            }
            return p
        }

        // MARK: Words it cannot place

        static let articles: Set<String> = ["le", "la", "l'", "les", "ce", "cet", "cette"]
        static let subjects: Set<String> = ["je", "j'", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "c'"]
        /// After « après », « avant »…: not something the moment is relative to.
        static let unrelated = subjects.union([",", "-", "tout", "quoi"])
        static let possessives: Set<String> = ["mon", "ton", "son", "notre", "votre", "leur"]
        static let leaving: Set<String> = ["sortant", "rentrant", "partant", "arrivant", "revenant", "quittant",
                                           "finissant", "terminant"]

        /// Whether the words from `i` say when relative to something the app cannot place in time: « après le
        /// travail », « avant de partir », « pendant la pause », « en sortant du bureau », « à la sortie de
        /// l'école », « à l'heure du déjeuner », « au retour », « à mon retour », « au réveil », « dès que je
        /// rentre », « quand tu rentres », « lors du déjeuner ». Not when a moment follows (« après 18 h », « avant
        /// vendredi », « avant le 15 », « pendant le week-end »), nor « d'après », « en avant », « après tout »,
        /// « après, on verra », « après je verrai »; « deux jours après » and « pendant une heure » never get here
        /// (a shift, a length).
        func unplaced(at i: Int) -> Bool {
            let of: Set<String> = ["de", "du", "des", "d'"]
            switch word(i) {
            case "apres", "avant", "pendant", "durant":
                guard !isWord(i - 1, ["d'", "de", "en", "l'", "ci"]), !isWord(i + 1, Self.unrelated) else {
                    return false
                }
                let k = isWord(i + 1, Self.articles) ? i + 2 : i + 1
                guard tokens.indices.contains(k) else { return false }
                return FrenchDates.meaning(tokens[k]) == nil  // not a word that says when: « avant le 15 », « midi »
            case "en": return isWord(i + 1, Self.leaving)
            case "a":  // « à », its accent gone
                if word(i + 1) == "la", word(i + 2) == "sortie", isWord(i + 3, of) { return true }
                if word(i + 1) == "l'", isWord(i + 2, ["heure", "heures"]), isWord(i + 3, of) { return true }
                return isWord(i + 1, Self.possessives) && word(i + 2) == "retour"
            case "au": return isWord(i + 1, ["retour", "reveil", "lever", "coucher"])
            case "des":  // « dès »
                return isWord(i + 1, ["que", "qu'"]) || isWord(i + 1, Self.possessives) && word(i + 2) == "retour"
            case "quand": return isWord(i + 1, Self.subjects)
            case "lors": return isWord(i + 1, of)
            default: return false
            }
        }
    }

    // MARK: - From what the words say to dates

    fileprivate struct Resolver {
        let now: Date
        let calendar: Calendar
        let base: Base?

        var today: Date { calendar.startOfDay(for: now) }

        func days(_ n: Int, after date: Date) -> Date {
            calendar.date(byAdding: .day, value: n, to: date) ?? date.addingTimeInterval(Double(n) * 86_400)
        }

        /// That day at that time; 24:00 is the midnight that ends it.
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            let date = hour >= 24 ? days(1, after: day) : day
            var c = calendar.dateComponents([.year, .month, .day], from: date)
            c.hour = hour % 24
            c.minute = minute
            return calendar.date(from: c) ?? date
        }

        func adding(_ span: Span, to date: Date, sign: Int = 1) -> Date {
            var c = DateComponents()
            c.month = span.months * sign
            c.day = span.days * sign
            c.second = span.seconds * sign
            return calendar.date(byAdding: c, to: date) ?? date
        }

        func time(of date: Date) -> (hour: Int, minute: Int) {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return (c.hour ?? 0, c.minute ?? 0)
        }

        // MARK: Hours

        /// The hour on a 24-hour clock. Throws for 1 to 7 said with nothing telling the morning from the afternoon.
        func hour(_ clock: Clock, part context: Part?) throws -> (hour: Int, minute: Int) {
            if clock.exact || clock.hour >= 24 { return (clock.hour, clock.minute) }
            var hour = clock.hour
            switch clock.part ?? context {
            case .morning: break
            case .afternoon, .lateAfternoon, .evening: if hour < 12 { hour += 12 }
            case .night: if (8...11).contains(hour) { hour += 12 } else if hour == 12 { hour = 0 }
            case nil:
                if !clock.named, (1...7).contains(clock.said) {
                    throw Problem.ambiguousHour(hour: clock.hour, minute: clock.minute)
                }
            }
            guard (0...23).contains(hour) else { throw Problem.notUnderstood }
            return (hour, clock.minute)
        }

        /// A start, which the end of its range may settle: "de 2 h à 16 h" is in the afternoon.
        func startHour(_ clock: Clock, end: Clock?, part context: Part?) throws -> (hour: Int, minute: Int) {
            do {
                return try hour(clock, part: context)
            } catch Problem.ambiguousHour(let h, let m) {
                if let end, let last = try? hour(end, part: end.part ?? context), last.hour >= 13 {
                    return (h + 12 < last.hour || (h + 12 == last.hour && m < last.minute)) ? (h + 12, m) : (h, m)
                }
                throw Problem.ambiguousHour(hour: h, minute: m)
            }
        }

        /// The end of a range is never asked about: it comes after the start ("de 10 h à 2 h" ends at 14:00).
        func end(_ clock: Clock, after start: Date, part context: Part?) -> Date {
            let day = calendar.startOfDay(for: start)
            let (h, m) = (try? hour(clock, part: clock.part ?? context)) ?? (clock.hour, clock.minute)
            var end = at(day, h, m)
            if end <= start, h < 12, at(day, h + 12, m) > start {
                end = at(day, h + 12, m)
            } else if end <= start {
                end = days(1, after: end)
            }
            return end
        }

        func usualHour(_ part: Part) -> Int {
            switch part {
            case .morning: 9
            case .afternoon: 14
            case .lateAfternoon: 17
            case .evening: 19
            case .night: 22
            }
        }

        func range(_ part: Part, on day: Date) -> (start: Date, end: Date) {
            switch part {
            case .morning: (day, at(day, 12, 0))
            case .afternoon: (at(day, 12, 0), at(day, 18, 0))
            case .lateAfternoon: (at(day, 16, 0), at(day, 19, 0))
            case .evening: (at(day, 18, 0), at(day, 24, 0))
            case .night: (at(day, 22, 0), at(days(1, after: day), 6, 0))
            }
        }

        // MARK: Days

        func day(_ day: Day) throws -> Date {
            switch day {
            case .relative(let n): return days(n, after: today)
            case .fromBase(let n): return days(n, after: calendar.startOfDay(for: base?.date ?? now))
            case .weekday(let weekday, let rule): return self.weekday(weekday, rule)
            case .date(let n, let month, let year, let weekday): return try date(n, month, year, weekday)
            case .monthPart(let month, let part):
                let thisMonth = calendar.component(.month, from: today)
                let year = calendar.component(.year, from: today) + (month < thisMonth ? 1 : 0)
                guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                    throw Problem.notUnderstood
                }
                switch part {
                case 1: return first
                case 2: return days(14, after: first)
                default: return days(-1, after: calendar.date(byAdding: .month, value: 1, to: first) ?? first)
                }
            }
        }

        func weekday(_ weekday: Int, _ rule: Rule) -> Date {
            let todays = calendar.component(.weekday, from: today)
            let monday = days(-((todays + 5) % 7), after: today)
            let fromMonday = (weekday + 5) % 7
            var ahead = (weekday - todays + 7) % 7
            if ahead == 0 { ahead = 7 }
            switch rule {
            case .coming: return days(ahead, after: today)
            case .weeksLater(let n): return days(ahead + 7 * n, after: today)
            case .nextWeek: return days(7 + fromMonday, after: monday)
            case .thisWeek: return days(fromMonday, after: monday)
            case .last:
                var back = (todays - weekday + 7) % 7
                if back == 0 { back = 7 }
                return days(-back, after: today)
            }
        }

        /// A date said without its year (the next one) or its month (this month's or the next); a weekday said with
        /// it must match, and may tell the year ("samedi 12 juin").
        func date(_ n: Int, _ month: Int?, _ year: Int?, _ weekday: Int?) throws -> Date {
            func make(_ year: Int, _ month: Int) -> Date? {
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: n)),
                      calendar.component(.day, from: date) == n  // no 31 November
                else { return nil }
                return date
            }
            let c = calendar.dateComponents([.year, .month], from: today)
            let (thisYear, thisMonth) = (c.year ?? 2000, c.month ?? 1)
            var candidates: [Date]
            if let month {
                guard (1...12).contains(month) else { throw Problem.notUnderstood }
                if let year {
                    candidates = [make(year, month)].compactMap { $0 }
                } else {
                    candidates = [make(thisYear, month), make(thisYear + 1, month)].compactMap { $0 }.filter { $0 >= today }
                }
            } else {
                candidates = (0..<3).compactMap { offset in
                    let index = thisMonth - 1 + offset
                    return make(thisYear + index / 12, index % 12 + 1)
                }.filter { $0 >= today }
            }
            guard let first = candidates.first else { throw Problem.notUnderstood }
            guard let weekday else { return first }
            if let match = candidates.first(where: { calendar.component(.weekday, from: $0) == weekday }) { return match }
            throw Problem.wrongWeekday(first)
        }

        /// The last day of a range, on or after its first: "du lundi au mercredi", "du 20 au 24".
        func rangeEnd(_ day: Day, from first: Date) throws -> Date {
            switch day {
            case .weekday(let weekday, _):
                return days((weekday - calendar.component(.weekday, from: first) + 7) % 7, after: first)
            case .date(let n, nil, nil, _):
                var candidate = first
                for _ in 0..<62 {
                    if calendar.component(.day, from: candidate) == n { return candidate }
                    candidate = days(1, after: candidate)
                }
                throw Problem.notUnderstood
            default:
                return try self.day(day)
            }
        }

        func range(_ period: Period) -> (start: Date, end: Date) {
            let todays = calendar.component(.weekday, from: today)
            let monday = days(-((todays + 5) % 7), after: today)
            func firstOfMonth(_ offset: Int) -> Date {
                let c = calendar.dateComponents([.year, .month], from: today)
                let first = calendar.date(from: DateComponents(year: c.year, month: c.month, day: 1)) ?? today
                return calendar.date(byAdding: .month, value: offset, to: first) ?? first
            }
            switch period {
            case .thisWeek: return (today, days(7, after: monday))
            case .nextWeek: return (days(7, after: monday), days(14, after: monday))
            case .lastWeek: return (days(-7, after: monday), monday)
            case .weekend(let next):
                var saturday = days(5, after: monday)
                if next, todays == 7 || todays == 1 { saturday = days(7, after: saturday) }
                return (max(saturday, today), days(2, after: saturday))
            case .thisMonth: return (today, firstOfMonth(1))
            case .nextMonth: return (firstOfMonth(1), firstOfMonth(2))
            case .month(let month):
                let thisMonth = calendar.component(.month, from: today)
                let first = firstOfMonth((month - thisMonth + 12) % 12)
                return (max(first, today), calendar.date(byAdding: .month, value: 1, to: first) ?? first)
            case .comingDays(let n): return (today, days(max(n, 1), after: today))
            }
        }

        // MARK: A moment

        func moment(_ p: Parsed) throws -> Moment {
            let context = p.parts.first
            let said = Set(try p.days.map { try self.day($0) })
            guard said.count <= 1, Set(p.clocks.map { [$0.hour, $0.minute] }).count <= 1 else {
                throw Problem.contradiction
            }
            var day = said.first
            var time: (hour: Int, minute: Int)?
            if let clock = p.clocks.first {
                time = try startHour(clock, end: p.endClock, part: context)
                // "cette nuit à 2 h": the night that follows that day.
                if (clock.part ?? context) == .night, let hour = time?.hour, hour < 6, let night = day {
                    day = days(1, after: night)
                }
            } else if p.sameTime {
                guard let base, base.hasTime else { throw Problem.notUnderstood }
                time = self.time(of: base.date)
            }
            var exact: Date?
            // "dans 20 minutes", "une heure plus tard", "maintenant": an exact moment; "dans trois semaines": a day.
            if let span = p.offset ?? p.shift?.span {
                let from = p.offset != nil ? now : (base?.date ?? now)
                let target = adding(span, to: from, sign: p.offset == nil && p.shift?.later == false ? -1 : 1)
                if span.underADay, time == nil {
                    exact = target
                } else {
                    let targetDay = calendar.startOfDay(for: target)
                    guard day == nil || day == targetDay else { throw Problem.contradiction }
                    day = targetDay
                    if time == nil, p.shift != nil, let base, base.hasTime { time = self.time(of: base.date) }
                }
            }
            let start: Date
            var hasTime = true
            if let exact {
                start = exact
            } else {
                var usual: Part?
                if time == nil, !p.allDay, let context {
                    time = (usualHour(context), 0)
                    usual = context
                }
                // A change to another day keeps the item's time.
                if time == nil, !p.allDay, day != nil, let base, base.hasTime { time = self.time(of: base.date) }
                if day == nil {
                    if let time {
                        if let base {
                            day = calendar.startOfDay(for: base.date)
                        } else {
                            day = at(today, time.hour, time.minute) > now ? today : days(1, after: today)
                        }
                    } else if let period = p.period, ![.thisWeek, .lastWeek].contains(period) {
                        day = range(period).start
                    } else if p.looseSpan != nil, base != nil {
                        throw Problem.noDirection
                    } else {
                        throw Problem.notUnderstood
                    }
                }
                guard let chosen = day else { throw Problem.notUnderstood }
                if let time {
                    var moment = at(chosen, time.hour, time.minute)
                    // "ce soir" said at 19:30: the next full hour.
                    if let usual, moment <= now, calendar.isDate(chosen, inSameDayAs: now),
                       now < range(usual, on: chosen).end
                    {
                        moment = at(chosen, self.time(of: now).hour + 1, 0)
                    }
                    start = moment
                } else {
                    start = chosen
                    hasTime = false
                }
            }

            var end: Date?
            if let endClock = p.endClock {
                end = self.end(endClock, after: start, part: context)
            }
            if let endDay = p.endDay {
                let last = try rangeEnd(endDay, from: calendar.startOfDay(for: start))
                if !hasTime {
                    end = days(1, after: last)
                } else if let endClock = p.endClock {
                    let (h, m) = (try? hour(endClock, part: endClock.part ?? context)) ?? (endClock.hour, endClock.minute)
                    end = at(last, h, m)
                }
            }
            if let end, end <= start { throw Problem.contradiction }
            return Moment(start: start, hasTime: hasTime, end: end, duration: (p.duration ?? p.looseSpan)?.totalSeconds)
        }

        // MARK: A period

        func period(_ p: Parsed) throws -> (start: Date, end: Date) {
            if let period = p.period { return range(period) }
            let context = p.parts.first
            let said = try p.days.map { try self.day($0) }.sorted()
            if let first = said.first, let endDay = p.endDay {
                let last = try rangeEnd(endDay, from: first)
                return (first, days(1, after: last))
            }
            if let first = said.first, let last = said.last, first != last { return (first, days(1, after: last)) }
            var chosen = said.first
            if chosen == nil, let offset = p.offset { chosen = calendar.startOfDay(for: adding(offset, to: now)) }
            if chosen == nil, let endDay = p.endDay {  // "jusqu'à vendredi"
                return (now, days(1, after: try rangeEnd(endDay, from: today)))
            }
            if let clock = p.clocks.first {  // "demain de 14 h à 18 h"; "demain à partir de 15 h": until the evening
                let (h, m) = try startHour(clock, end: p.endClock, part: context)
                let from = at(chosen ?? today, h, m)
                return (from, p.endClock.map { self.end($0, after: from, part: context) } ?? days(1, after: chosen ?? today))
            }
            if let context { return range(context, on: chosen ?? today) }
            guard let chosen else { throw Problem.notUnderstood }
            return (chosen, days(1, after: chosen))
        }
    }
}
