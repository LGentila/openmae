import CryptoKit
import Foundation

// Received information: other systems (Home Assistant, Gladys, Apple Shortcuts, a script, any tool that can post to
// Slack, Discord or ntfy) send short texts to Maé at a secret address. This file is the part that needs no network:
// the sources, the paths a delivery may come by, reading what was sent, cleaning it for the voice, and the rules that
// decide whether Maé says it, keeps it for later (the news, News.swift), shows it in a notification or ignores it. The
// HTTP side is in OpenMaeLink.

// MARK: - Sources and paths

/// A system that sends information to Maé, added by the user in the Mac's settings. It gets a secret address
/// (`…/in/<secret>`). What it sends only informs Maé: it never triggers an action.
public struct InboundSource: Codable, Sendable, Equatable, Identifiable {
    /// Where the source sends from. It decides the path its deliveries must come by (`accepts`); changing it changes
    /// the source's address.
    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// The home network: through the home relay.
        case home
        /// The internet: through the public relay, which cannot read the deliveries.
        case internet
    }

    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Said as soon as nobody speaks, after the chime.
        case sayNow
        /// Kept for later, silently: the news, read when the user asks « Quoi de neuf ? ».
        case keepForLater
        /// A Mac notification only.
        case notifyOnly
    }

    public var id: UUID
    public var name: String
    public var origin: Origin
    public var mode: Mode
    /// "May ask for an urgent announcement": an urgent delivery is then said at once, whatever the mode.
    public var mayBeUrgent: Bool
    /// Paused: its address answers like an unknown one.
    public var paused: Bool
    public var created: Date

    public init(id: UUID = UUID(), name: String, origin: Origin = .home, mode: Mode = .sayNow, mayBeUrgent: Bool = false,
                paused: Bool = false, created: Date = Date())
    {
        self.id = id
        self.name = name
        self.origin = origin
        self.mode = mode
        self.mayBeUrgent = mayBeUrgent
        self.paused = paused
        self.created = created
    }

    /// Compartmentalisation: a home source is only accepted through the home relay, an internet source only through
    /// the public relay. Through the other path its address answers like an unknown one.
    public func accepts(_ path: InboundPath) -> Bool {
        switch origin {
        case .home: path == .homeRelay
        case .internet: path == .publicRelay
        }
    }
}

/// The way a delivery reached the Mac. The two paths are kept apart (`InboundSource.accepts`).
public enum InboundPath: String, Codable, Sendable, CaseIterable {
    /// A relay on the home network, in home mode: it passes the delivery to the Mac on the Mac's own connection.
    case homeRelay
    /// The public relay, without reading: TLS goes through it to a certificate the Mac holds.
    case publicRelay
}

// MARK: - What was sent

/// A delivery as Maé understands it.
public struct InboundMessage: Sendable, Equatable {
    public enum Form: String, Codable, Sendable {
        /// A plain sentence: a text body, or `GET …?text=…`.
        case text
        /// A JSON object in one of the common notification formats.
        case json
    }

    public var form: Form
    /// Cleaned, nil when there is none.
    public var title: String?
    /// Cleaned: markup and web addresses removed.
    public var text: String
    public var urgent: Bool
    /// How long it may wait to be said, in seconds (10 to 3600); nil: `InboundRules.defaultExpiry`.
    public var expires: Int?
    /// The welcome home: the news after the text.
    public var news: Bool
    public var language: SpeechLanguage

    public init(form: Form, title: String?, text: String, urgent: Bool = false, expires: Int? = nil, news: Bool = false,
                language: SpeechLanguage? = nil)
    {
        self.form = form
        self.title = title
        self.text = text
        self.urgent = urgent
        self.expires = expires
        self.news = news
        self.language = language ?? LanguageGuesser.guess([title, text].compactMap { $0 }.joined(separator: " "))
    }

    /// "Title : text" with a title, in full: what the log keeps.
    public var full: String {
        guard let title, !title.isEmpty else { return text }
        return title + (language == .french ? "\u{00A0}: " : ": ") + text
    }

    /// What Maé says: `full`, stopped after its last complete sentence within 280 characters.
    public var spoken: String { InboundText.shortened(full) }
}

/// Why a delivery cannot be read.
public enum InboundRefusal: Error, Equatable, Sendable {
    /// 400: no text (an empty body), not UTF-8, or broken JSON.
    case unreadable(String)
    /// 422: a JSON object without any of the recognised text fields (a GitHub payload…).
    case noText

    /// For the HTTP answer and the log, in English like the rest of the protocol.
    public var explanation: String {
        switch self {
        case .unreadable(let why): why
        case .noText:
            "No text found. Send a plain sentence, or a JSON object with a text, message, body or content field (or Discord embeds)."
        }
    }
}

/// An HTTP request, as far as reading a delivery needs it.
public struct InboundRequest: Sendable {
    public var method: String
    /// The query's parameters (the first value of each).
    public var query: [String: String]
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// Reads the two accepted forms.
///
/// Form 1, a plain sentence: a body that is not JSON, or `GET …?text=…`; optional ntfy-style headers `Title` and
/// `Priority` (`urgent`, `high`, `max`, or 4 to 5 on ntfy's scale of 1 to 5 mean urgent).
///
/// Form 2, a JSON object: the text is the first of `text` (what users write themselves, Slack), `message` (Gotify,
/// ntfy), `body` (Apprise), `content` (Discord) that holds text, else Discord's `embeds[0]` (its title becomes the
/// title, its description the text). Optional `title`, `priority` (`urgent`, `high`, `max`; a number from 4 for ntfy,
/// whose bodies have a `topic`, from 8 for Gotify), `expires` (seconds, 10 to 3600) and `news`.
public enum InboundParser {
    public static func parse(_ request: InboundRequest) -> Result<InboundMessage, InboundRefusal> {
        guard let body = String(data: request.body, encoding: .utf8) else {
            return .failure(.unreadable("The body is not UTF-8 text."))
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        if !trimmed.isEmpty, contentType.contains("json") || trimmed.hasPrefix("{") {
            return parseJSON(request.body)
        }
        let raw = trimmed.isEmpty ? (request.query["text"] ?? request.query["message"] ?? "") : trimmed
        let text = InboundText.clean(raw)
        guard !text.isEmpty else { return .failure(.unreadable("There is no text to say.")) }
        let title = (request.headers["title"] ?? request.headers["x-title"] ?? request.query["title"])
            .map(InboundText.clean).flatMap { $0.isEmpty ? nil : $0 }
        let priority = request.headers["priority"] ?? request.headers["x-priority"] ?? request.query["priority"]
        return .success(InboundMessage(form: .text, title: title, text: text,
                                       urgent: priority.map { isUrgent($0, numberFrom: 4) } ?? false))
    }

    private static func parseJSON(_ data: Data) -> Result<InboundMessage, InboundRefusal> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.unreadable("The body is not a valid JSON object."))
        }
        var title = string(object["title"])
        var text: String?
        for key in ["text", "message", "body", "content"] {
            if let value = string(object[key]) {
                text = value
                break
            }
        }
        if text == nil, let embed = (object["embeds"] as? [Any])?.first as? [String: Any] {
            let embedTitle = string(embed["title"])
            if let description = string(embed["description"]) {
                text = description
                title = title ?? embedTitle
            } else {
                text = embedTitle
            }
        }
        guard let text else { return .failure(.noText) }

        var urgent = false
        if let priority = object["priority"] {
            // ntfy's scale goes from 1 to 5, Gotify's from 0 to 10.
            let numberFrom = object["topic"] != nil ? 4 : 8
            if let word = priority as? String {
                urgent = isUrgent(word, numberFrom: numberFrom)
            } else if let number = priority as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                urgent = number.doubleValue >= Double(numberFrom)
            }
        }
        var expires: Int?
        if let number = object["expires"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            expires = min(max(number.intValue, 10), 3600)
        } else if let word = object["expires"] as? String, let seconds = Int(word) {
            expires = min(max(seconds, 10), 3600)
        }
        let news = (object["news"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return .success(InboundMessage(form: .json, title: title, text: text, urgent: urgent, expires: expires, news: news))
    }

    /// A field that holds text once cleaned.
    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = InboundText.clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isUrgent(_ priority: String, numberFrom: Int) -> Bool {
        let word = priority.trimmingCharacters(in: .whitespaces).lowercased()
        if ["urgent", "high", "max"].contains(word) { return true }
        return Int(word).map { $0 >= numberFrom } ?? false
    }
}

// MARK: - Cleaning for the voice

public enum InboundText {
    /// Beyond this, Maé stops at the end of the last complete sentence; the full text stays in the log.
    public static let spokenLimit = 280

    /// Slack markup (`*bold*`, `<url|label>`) and Markdown removed, web addresses removed, then the usual speech
    /// preparation (`SpeakableText.clean`).
    public static func clean(_ text: String) -> String {
        var s = text
        func replace(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        // Slack: <https://…|label> and <#C123|channel> keep their label; <https://…>, <@U123>, <!here> go.
        replace(#"<(?:https?|mailto):[^|>\s]*\|([^>]*)>"#, "$1")
        replace(#"<#[a-z0-9]+\|([^>]*)>"#, "$1")
        replace(#"<[@!#][^>\s]*>"#, "")
        replace(#"<(?:https?|mailto):[^>\s]*>"#, "")
        // Markdown: [label](url) keeps its label, an image goes with its address.
        replace(#"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        replace(#"\[([^\]]+)\]\([^)]*\)"#, "$1")
        // Emphasis, both kinds: **x**, __x__, ~~x~~, then *x*, _x_, ~x~ around words, and `code`.
        replace(#"(\*\*|__|~~)(.+?)\1"#, "$2")
        replace(#"(?<![\w*~])([*_~])(?=\S)(.+?)(?<=\S)\1(?![\w*~])"#, "$2")
        replace("`+", "")
        // Headings and quotes at the start of a line.
        replace(#"(?m)^[ \t]{0,3}(?:#{1,6}|>+)[ \t]*"#, "")
        // Web addresses: Maé would read them letter by letter.
        replace(#"\b(?:https?://|www\.)\S+"#, "")
        return SpeakableText.clean(s)
    }

    /// `text` stopped after its last complete sentence within `limit` characters; without one, after its last whole
    /// word, with an ellipsis.
    public static func shortened(_ text: String, limit: Int = spokenLimit) -> String {
        guard text.count > limit else { return text }
        let head = Array(text.prefix(limit + 1))  // one more, to see whether the last character ends a sentence
        var end: Int?
        for i in stride(from: limit - 1, through: 0, by: -1) where ".!?…".contains(head[i]) {
            if head[i + 1].isWhitespace || head[i + 1] == "\u{00A0}" {
                end = i + 1
                break
            }
        }
        if let end, end >= 20 { return String(head[..<end]) }
        let words = String(head[..<limit])
        if let space = words.lastIndex(where: \.isWhitespace) {
            return words[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return words + "…"
    }
}

// MARK: - What happens to a delivery

/// The answer to a delivery that passed the checks (address, path, limits, form).
public enum InboundOutcome: String, Codable, Sendable {
    /// Maé will say it: `202 {"status":"queued"}`.
    case queued
    /// Kept for later, in the news: `202 {"status":"kept"}`.
    case kept
    /// A notification on the Mac: `202 {"status":"notified"}`.
    case notified
    /// The same text from the same source a moment ago: ignored, `200 {"status":"duplicate"}`.
    case duplicate
}

public struct InboundDecision: Sendable, Equatable {
    public var outcome: InboundOutcome
    /// Said at once: it may cut Maé's sentence, never the user's.
    public var urgent: Bool
    /// Not said after this many seconds: it then goes to the news, never said late.
    public var expiresAfter: Int

    public init(outcome: InboundOutcome, urgent: Bool = false, expiresAfter: Int = InboundRules.defaultExpiry) {
        self.outcome = outcome
        self.urgent = urgent
        self.expiresAfter = expiresAfter
    }
}

/// The settings of received information that apply to every source.
public struct InboundPreferences: Codable, Sendable, Equatable {
    /// "Announcements": off, Maé says nothing on her own, everything she would have said goes to the news.
    public var announcements: Bool
    public var quietHours: QuietHours

    public init(announcements: Bool = true, quietHours: QuietHours = QuietHours()) {
        self.announcements = announcements
        self.quietHours = quietHours
    }
}

/// "Quiet hours": while they last, what a source would have Maé say right away is kept for later, except the urgent
/// deliveries of the sources that may ask for them. Off by default; from 22:00 to 08:00 once switched on.
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Minutes after midnight, in the Mac's time zone.
    public var start: Int
    public var end: Int

    public init(enabled: Bool = false, start: Int = 22 * 60, end: Int = 8 * 60) {
        self.enabled = enabled
        self.start = start
        self.end = end
    }

    /// Whether `date` is in them (they may go past midnight).
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }
}

/// What Maé does with a delivery, by its source's mode:
/// - "Say right away": an announcement, as a timer that rings (it waits until nobody speaks, the chime, the text).
/// - "Keep for later": the news, silently.
/// - "Notification only": a Mac notification.
/// - Urgent: said at once whatever the mode, if the source may ask for it; otherwise like the others.
/// - The announcements switched off, or the quiet hours (except for the urgent ones above): to the news instead.
/// - Maé not ready (models loading, setup to finish): to the news instead.
/// - Not said within 60 s (or its `expires`): never said late, the news instead (`InboundHost`).
/// - The same text from the same source within 2 minutes: ignored.
public struct InboundRules: Sendable {
    /// Seconds an announcement may wait to be said.
    public static let defaultExpiry = 60
    public static let duplicateWindow: TimeInterval = 120

    /// The last texts each source sent that were not duplicates, and when.
    private var recent: [UUID: [String: Date]] = [:]

    public init() {}

    /// `ready`: Maé can speak now (her models are loaded). `calendar`: the time zone the quiet hours are in.
    public mutating func decide(_ message: InboundMessage, from source: InboundSource, ready: Bool,
                                preferences: InboundPreferences = InboundPreferences(), now: Date = Date(),
                                calendar: Calendar = .current) -> InboundDecision
    {
        var texts = (recent[source.id] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
        defer { recent[source.id] = texts }
        if texts[message.full] != nil { return InboundDecision(outcome: .duplicate) }
        texts[message.full] = now
        let urgent = message.urgent && source.mayBeUrgent
        if !urgent {
            switch source.mode {
            case .sayNow: break
            case .keepForLater: return InboundDecision(outcome: .kept)
            case .notifyOnly: return InboundDecision(outcome: .notified)
            }
        }
        // Maé would say it now.
        guard preferences.announcements else { return InboundDecision(outcome: .kept) }
        if !urgent, preferences.quietHours.contains(now, calendar: calendar) { return InboundDecision(outcome: .kept) }
        guard ready else { return InboundDecision(outcome: .kept) }
        return InboundDecision(outcome: .queued, urgent: urgent, expiresAfter: message.expires ?? Self.defaultExpiry)
    }

    /// Forgets a source (removed, or its address changed).
    public mutating func forget(_ source: UUID) {
        recent[source] = nil
    }
}

/// At most 6 deliveries per minute and 60 per hour for each source: beyond, `429`.
public struct InboundRateLimit: Sendable {
    public static let perMinute = 6
    public static let perHour = 60
    private var deliveries: [UUID: [Date]] = [:]

    public init() {}

    /// Records a delivery from `source` and says whether it is within the limits. A refused one is not counted.
    public mutating func allow(_ source: UUID, now: Date = Date()) -> Bool {
        var times = (deliveries[source] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        defer { deliveries[source] = times }
        let lastMinute = times.filter { now.timeIntervalSince($0) < 60 }.count
        guard lastMinute < Self.perMinute, times.count < Self.perHour else { return false }
        times.append(now)
        return true
    }
}

// MARK: - Addresses

/// The Mac's inbound name: how a relay in home mode finds the Mac a delivery is for. The first 16 bytes of
/// SHA-256("openmae-relay/1 inbound:" ‖ the Mac's raw Ed25519 public key), in lowercase base32 without padding
/// (26 characters). The relay computes it from the key the Mac registered with, so no other Mac can take it.
public enum InboundName {
    public static func make(signingKey: Data) -> String {
        let digest = SHA256.hash(data: Data("openmae-relay/1 inbound:".utf8) + signingKey)
        return base32(Data(digest.prefix(16)))
    }

    /// RFC 4648 base32, lowercase, without padding (as device ids).
    static func base32(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int(buffer >> UInt32(bits - 5) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }
}

/// A source's secret: 32 random bytes in base64url (43 characters), at the end of its address. Compared in constant
/// time, on its SHA-256.
public enum InboundSecret {
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func digest(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data(secret.utf8)))
    }

    /// Whether two digests are the same, in a time that does not depend on where they differ.
    public static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

// MARK: - Phrases

/// What Maé says or writes about received information. Her spoken phrases stay French, as `ActionPhrases`.
public enum InboundPhrases {
    /// For the conversation's history: the note recorded as the user's message, like a timer's.
    public static func note(source: String, receivedAt date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%d h %02d", parts.hour ?? 0, parts.minute ?? 0)
        return "(Information de la source « \(source) », reçue à \(time), dite à l’utilisateur.)"
    }

    /// "Send a test", in the source's settings.
    public static func test(source: String) -> String {
        "Ceci est un essai de la source \(source)."
    }
}
