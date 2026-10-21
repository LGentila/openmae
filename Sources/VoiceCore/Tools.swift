import Foundation

// Actions: the language model fills in a hidden form (a tool call), the app checks it, carries it out and
// says what was really saved. The model never writes the confirmation itself, so what the user hears is
// what happened.
//
// A `ToolProvider` offers a few tools (reminders and calendar, timers, shortcuts…). Its tools are described
// once in the system prompt, which stays constant during a session so the model keeps it in memory.

/// A JSON value, for tool arguments and results.
public enum JSONValue: Sendable, Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The text of a string; numbers and booleans written out (models sometimes quote a number, or not).
    public var text: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    /// A whole number, from a number or a string holding one ("90", "90.0").
    public var integer: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value: Int(value)
        case .string(let value): Int(value.trimmingCharacters(in: .whitespaces))
            ?? Double(value.trimmingCharacters(in: .whitespaces)).flatMap { $0.rounded() == $0 ? Int($0) : nil }
        default: nil
        }
    }

    public var boolean: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "vrai", "oui"].contains(value.lowercased()) ? true
            : ["false", "faux", "non"].contains(value.lowercased()) ? false : nil
        default: nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

/// What a tool may do, which decides how the app handles it (never the model).
public enum ToolRisk: String, Sendable, Codable {
    /// Only reads: carried out at once.
    case read
    /// Creates or changes something the user can take back: carried out, confirmed out loud, and "annule"
    /// undoes it for two minutes.
    case undoable
    /// The app reads a summary and waits for the user's "oui" first.
    case sensitive
}

/// One parameter of a tool (a small subset of JSON Schema: what the voice tools need, and what connected tools use).
public struct ToolParameter: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case string
        case integer
        /// Any number, whole or not (a temperature).
        case number
        case boolean
        /// A string among these values.
        case oneOf([String])
        /// Several strings; among these values when there are some.
        case strings([String])
        /// Anything deeper (an object, an array of objects): the JSON Schema as a connected tool gave it, passed on as is.
        case schema(JSONValue)
    }

    public var name: String
    public var kind: Kind
    public var description: String
    public var required: Bool

    public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = false) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
    }
}

/// A tool as the model sees it. Names, descriptions and parameters are in French, like the system prompt.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    /// One sentence: what the tool does and when to use it.
    public var description: String
    public var parameters: [ToolParameter]
    public var risk: ToolRisk

    public init(name: String, description: String, parameters: [ToolParameter], risk: ToolRisk) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.risk = risk
    }
}

/// A tool call written by the model.
public struct ToolCall: Sendable, Codable, Hashable {
    public var name: String
    public var arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue] = [:]) {
        self.name = name
        self.arguments = arguments
    }

    /// A non-empty text argument (spaces trimmed).
    public func text(_ key: String) -> String? {
        guard let text = arguments[key]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}

/// Lets a provider take back what it did ("annule").
public struct UndoToken: Sendable, Hashable {
    public var provider: String
    public var id: String

    public init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }
}

/// What a tool did.
public struct ToolOutcome: Sendable {
    /// The sentence the app says, filled in from what was really saved.
    public var spoken: String
    /// The structured result, kept in the history so the next turn ("décale-le") has the context.
    public var forModel: JSONValue
    /// nil when there is nothing to take back.
    public var undo: UndoToken?
    /// Said when the user asks to undo an action that cannot be (a shortcut).
    public var cannotUndo: String?
    /// The model says it from `forModel` instead: a text that came from outside, to sum up (an agent's report).
    /// `spoken` is then only said if the model gives nothing.
    public var modelSpeaks: Bool

    /// Told the model when, summing up such a text, it writes a call and nothing else (no call is carried out then):
    /// it gets one more pass to answer with what it has.
    public static let noCallWhileSummingUp = "Appel non fait : plus aucun outil pour ce message. Réponds maintenant à "
        + "l'utilisateur avec ce que tu as, et dis-le simplement si ça ne répond pas à sa question."

    public init(spoken: String, forModel: JSONValue, undo: UndoToken? = nil, cannotUndo: String? = nil,
                modelSpeaks: Bool = false)
    {
        self.spoken = spoken
        self.forModel = forModel
        self.undo = undo
        self.cannotUndo = cannotUndo
        self.modelSpeaks = modelSpeaks
    }
}

/// A call the app refuses, and why. It is never carried out.
public struct ToolRefusal: Error, Sendable {
    /// Why, for the model, which gets one chance to correct its call.
    public var forModel: String
    /// The question the app asks the user when the model cannot correct it.
    public var spoken: String
    /// The model may correct its call (wrong arguments); false when retrying cannot help (permission refused).
    public var retryable: Bool
    /// What is refused is one detail of the call, which the answer gives again, whole: a moment already gone, words
    /// about time the app cannot place or none at all, a calendar or a list that does not exist. Right after a creation
    /// refused so, a change of the last item, or of one never created, is that creation with what the change gives
    /// (`RefusedCreation`).
    public var detailGivenAgain = false

    public init(forModel: String, spoken: String, retryable: Bool = true) {
        self.forModel = forModel
        self.spoken = spoken
        self.retryable = retryable
    }

    /// What the model reads of the refused call, in the history: why, and when it may correct its call, what the app
    /// waits for (`secondTry`).
    public func result(for call: ToolCall) -> JSONValue {
        ["erreur": .string(retryable ? forModel + " " + Self.secondTry(call.name) : forModel)]
    }

    /// Said to the model after the reason of a refusal it may correct, for a call to `tool`: nothing was done, so not to
    /// say it was, and what the app waits for: another call, or the user's answer to its question. For a creation, also
    /// to write it again once the user answers, not a change of an item that does not exist, as after a moment gone
    /// (`DateCheck`).
    ///
    /// Without it, Gemma 4 26B began most of its second tries with « C'est noté… » or « C'est fait… » for an item never
    /// saved, then asked about it (« … le 22 octobre tombe un jeudi. Veux-tu que je le programme pour le dimanche
    /// 25 ? »): in voice-cli dialogue-bench, 8 of 10 on a weekday that does not match the date, 9 of 12 on words it
    /// cannot place in time; with it, 1 of 42 in all. Told only that nothing was created, still 5 of 10. Naming the
    /// creation to write once the user answers made the user's answer save the item (a calendar that does not exist: 9 of
    /// 10 instead of 4); the model then also writes a creation refused for a list that does not exist again, as it was,
    /// so the app asks the user which list rather than the model choosing one.
    public static func secondTry(_ tool: String) -> String {
        guard [ActionCatalog.createEvent.name, ActionCatalog.createReminder.name].contains(tool) else {
            return "Rien n'est créé ni changé : ne dis pas que c'est noté ou fait. Écris un nouvel appel, ou pose ta "
                + "question à l'utilisateur."
        }
        return "Rien n'est créé : ne dis pas que c'est noté ou fait. Écris un nouvel appel, ou pose ta question à "
            + "l'utilisateur ; quand il répond, appelle de nouveau \(tool) (pas \(ActionCatalog.changeItem.name) : rien "
            + "n'existe encore)."
    }
}

/// The circumstances of a call.
public struct ToolContext: Sendable {
    /// Reference time of the turn (the date line the model was given).
    public var now: Date
    public var timeZone: TimeZone
    public var language: SpeechLanguage
    /// What the user said in this turn, then in the ones before (without the date line): when the model changed the
    /// user's words about a moment, the app reads it from theirs.
    public var userSaid: [String]
    /// Says a sentence at once, before the outcome (e.g. just before macOS asks for a permission).
    public var say: @Sendable (String) async -> Void

    public init(now: Date, timeZone: TimeZone = .current, language: SpeechLanguage, userSaid: [String] = [],
                say: @escaping @Sendable (String) async -> Void = { _ in })
    {
        self.now = now
        self.timeZone = timeZone
        self.language = language
        self.userSaid = userSaid
        self.say = say
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: language == .french ? "fr_FR" : "en_US")
        return calendar
    }
}

/// A set of tools: reminders and calendar, timers, shortcuts, agents…
public protocol ToolProvider: Sendable {
    /// Stable identifier, e.g. "calendar".
    var identifier: String { get }
    /// Constant during a session: the tools go into the system prompt, which the model keeps in memory.
    func tools() async -> [ToolSpec]
    /// A few sentences for the system prompt about when to use these tools; constant during a session too.
    func promptAddendum() async -> String?
    /// The risk of this call; by default the tool's.
    func risk(of call: ToolCall) async -> ToolRisk
    /// Checks a call without carrying it out (dates, names). Throws a `ToolRefusal`.
    func check(_ call: ToolCall, context: ToolContext) async throws
    /// What the app says while the model writes a call to this tool, instead of "Un instant, je m'en occupe tout de
    /// suite." (nil).
    func waitingPhrase(for tool: String, language: SpeechLanguage) async -> String?
    /// What the app says before asking "On y va ?" for a sensitive call.
    func summary(of call: ToolCall, context: ToolContext) async -> String
    /// A sensitive call that waited for the user's "oui" will not be carried out: it expired, another request replaced
    /// it or a new conversation began.
    func dropped(_ call: ToolCall) async
    /// The same, because the user said no (by default, `dropped`).
    func declined(_ call: ToolCall) async
    /// Carries out a call that passed `check`. Throws a `ToolRefusal` when it cannot.
    func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome
    /// Takes back an action; returns what to say.
    func undo(_ token: UndoToken, context: ToolContext) async throws -> String
    /// A new conversation: forget the items created in the previous one.
    func resetConversation() async
}

extension ToolProvider {
    public func promptAddendum() async -> String? { nil }
    public func risk(of call: ToolCall) async -> ToolRisk {
        await tools().first { $0.name == call.name }?.risk ?? .sensitive
    }
    public func check(_ call: ToolCall, context: ToolContext) async throws {}
    public func waitingPhrase(for tool: String, language: SpeechLanguage) async -> String? { nil }
    public func summary(of call: ToolCall, context: ToolContext) async -> String { call.name }
    public func dropped(_ call: ToolCall) async {}
    public func declined(_ call: ToolCall) async { await dropped(call) }
    public func undo(_ token: UndoToken, context: ToolContext) async throws -> String {
        ActionPhrases.cannotUndo(context.language)
    }
    public func resetConversation() async {}
}
