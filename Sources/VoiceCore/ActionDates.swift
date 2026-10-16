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

/// The checks every dated action shares (a malformed date, a date in the past or more than a year
/// ahead is refused, and the user is asked again).
public enum DateCheck {
    /// A date the user wants something to happen at: well formed, not past, less than a year ahead.
    /// Returns nil when the argument is absent and not required.
    public static func upcoming(_ call: ToolCall, _ key: String, context: ToolContext, required: Bool)
        throws -> (date: Date, hasTime: Bool)?
    {
        guard let raw = call.text(key) else {
            if required { throw refusal(.missing, key: key, context: context) }
            return nil
        }
        guard let parsed = LocalDateTime.parse(raw, in: context.timeZone) else {
            throw refusal(.malformed, key: key, context: context, raw: raw)
        }
        let calendar = context.calendar
        let past = parsed.hasTime
            ? parsed.date < context.now.addingTimeInterval(-60)
            : parsed.date < calendar.startOfDay(for: context.now)
        if past { throw refusal(.past, key: key, context: context, raw: raw) }
        if let limit = calendar.date(byAdding: .year, value: 1, to: context.now), parsed.date > limit {
            throw refusal(.tooFar, key: key, context: context, raw: raw)
        }
        return parsed
    }

    /// Any well-formed date (reading the agenda may look at the past).
    public static func any(_ call: ToolCall, _ key: String, context: ToolContext, required: Bool)
        throws -> (date: Date, hasTime: Bool)?
    {
        guard let raw = call.text(key) else {
            if required { throw refusal(.missing, key: key, context: context) }
            return nil
        }
        guard let parsed = LocalDateTime.parse(raw, in: context.timeZone) else {
            throw refusal(.malformed, key: key, context: context, raw: raw)
        }
        return parsed
    }

    public enum Problem: Sendable { case missing, malformed, past, tooFar }

    public static func refusal(_ problem: Problem, key: String, context: ToolContext, raw: String = "") -> ToolRefusal {
        let now = LocalDateTime.format(context.now, in: context.timeZone)
        switch problem {
        case .missing:
            return ToolRefusal(forModel: "Il manque « \(key) ».", spoken: ActionPhrases.badTime(context.language))
        case .malformed:
            return ToolRefusal(forModel: "« \(key) » doit être au format AAAA-MM-JJTHH:MM (reçu : \(raw)).",
                               spoken: ActionPhrases.badTime(context.language))
        case .past:
            return ToolRefusal(forModel: "« \(key) » (\(raw)) est déjà passé : nous sommes le \(now).",
                               spoken: ActionPhrases.datePassed(context.language))
        case .tooFar:
            return ToolRefusal(forModel: "« \(key) » (\(raw)) est à plus d'un an : nous sommes le \(now).",
                               spoken: ActionPhrases.dateTooFar(context.language))
        }
    }
}
