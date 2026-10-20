import Foundation

/// How the user travels.
public enum TravelMode: String, Sendable, Codable {
    /// By car, with the traffic at that time.
    case car
    /// By public transport.
    case transit
}

/// A travel time, as the maps service worked it out.
public struct TravelEstimate: Sendable, Equatable {
    /// Where the trip starts: the place the user named, or nil for where the Mac is.
    public var origin: String?
    /// The place found for the destination ("Gare de Cergy Préfecture").
    public var destination: String
    public var mode: TravelMode
    public var seconds: TimeInterval
    public var meters: Double?
    public var departure: Date
    public var arrival: Date
    /// The user gave the time to arrive by: `departure` is when to leave.
    public var arriveBy: Bool

    public init(origin: String?, destination: String, mode: TravelMode, seconds: TimeInterval, meters: Double?,
                departure: Date, arrival: Date, arriveBy: Bool)
    {
        self.origin = origin
        self.destination = destination
        self.mode = mode
        self.seconds = seconds
        self.meters = meters
        self.departure = departure
        self.arrival = arrival
        self.arriveBy = arriveBy
    }
}

/// Works out travel times (Apple's maps, in the app: `MapKitTravel`).
public protocol TravelEstimating: Sendable {
    /// From `origin` (a place the user named), or from `here` when it is nil; leaving now, or arriving by `arriveBy`.
    /// Throws `SourceError.notFound` when a place is not found, `.unexpected` when there is no way there.
    func estimate(to destination: String, from origin: String?, here: Place?, mode: TravelMode, arriveBy: Date?)
        async throws -> TravelEstimate
}

/// The travel time tool, as the model sees it (in French, like the other tools), and what it is told of a trip.
public enum TravelTimeCatalog {
    public static let name = "temps_trajet"

    // The example of the description is not a phrase of the benchmark's corpus (see ActionCatalog).
    public static let spec = ToolSpec(
        name: name,
        description: "Donne le temps de trajet jusqu'à un endroit, en voiture avec le trafic du moment ou en "
            + "transports en commun, et l'heure à laquelle partir.",
        parameters: [
            ToolParameter("destination", .string, "L'endroit où aller, avec les mots de l'utilisateur (par exemple "
                          + "« l'aéroport d'Orly »).", required: true),
            ToolParameter("depart", .string, "D'où partir, s'il le dit. Vide pour là où il est."),
            ToolParameter("mode", .oneOf(["voiture", "transports"]), "« voiture » (par défaut) ou « transports » en "
                          + "commun."),
            ToolParameter("arrivee", .string, "L'heure à laquelle il veut arriver, avec ses mots (« à 9 h »), pour "
                          + "savoir quand partir."),
        ],
        risk: .read)

    /// Appended to the system prompt when the built-in sources are on.
    public static let promptAddendum = """
        Pour un temps de trajet ou l'heure à laquelle partir, appelle temps_trajet, avec la destination comme \
        l'utilisateur la dit.
        """

    public static func destination(_ call: ToolCall) -> String? {
        ["destination", "lieu", "arrivee_lieu", "vers", "to"].lazy.compactMap { call.text($0) }.first
            .map { String($0.prefix(150)) }
    }

    /// The origin the call names; nil for where the user is.
    public static func origin(_ call: ToolCall) -> String? {
        guard let text = ["depart", "départ", "origine", "from"].lazy.compactMap({ call.text($0) }).first,
              !WeatherCatalog.isHere(text)
        else { return nil }
        return String(text.prefix(150))
    }

    public static func mode(_ call: ToolCall) -> TravelMode {
        let text = (call.text("mode") ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return ["transport", "metro", "train", "bus", "rer", "tram", "transit", "commun"].contains { text.contains($0) }
            ? .transit : .car
    }

    /// The time to arrive by, when the call gives one (it needs a time of day).
    public static func arriveBy(_ call: ToolCall, context: ToolContext) throws -> Date? {
        guard let words = call.text("arrivee") ?? call.text("arrivée") ?? call.text("heure_arrivee") else { return nil }
        guard let moment = try? FrenchDates.moment(words, now: context.now, calendar: context.calendar), moment.hasTime
        else {
            throw ToolRefusal(forModel: "Je ne comprends pas l'heure d'arrivée « \(words) ». Donne-la avec les mots "
                              + "de l'utilisateur (« à 9 h »), ou laisse « arrivee » vide pour partir maintenant.",
                              spoken: ActionPhrases.notUnderstood(context.language))
        }
        return moment.start
    }

    /// Checks a call (the benchmark's "would the app accept it").
    public static func check(_ call: ToolCall, context: ToolContext) throws {
        guard destination(call) != nil else {
            throw ToolRefusal(forModel: "Il manque « destination » : l'endroit où aller.",
                              spoken: ActionPhrases.notUnderstood(context.language))
        }
        _ = try arriveBy(call, context: context)
    }

    // MARK: Finding the place

    /// The words without their article ("la gare de Cergy" → "gare de Cergy"): a maps search for "la gare de Cergy"
    /// finds a "Rue de la Gare" first, while "la Défense" needs its article (see `bestPlace`).
    public static func withoutArticle(_ words: String) -> String {
        words.replacingOccurrences(of: #"^\s*(à\s+)?((la|le|les)\s+|l['’]\s*)"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
    }

    /// Which of the places a maps search found the words stand for: its name is the words (with or without their
    /// article), it is a point of interest (a station, an airport), its name has more of the words; never a street the
    /// words do not name ("Rue de la Gare" for "la gare de Cergy"). Ties go to the first found. nil when there is none.
    public static func bestPlace(_ found: [(name: String, isPointOfInterest: Bool)], for words: String) -> Int? {
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let said = [folded(words), folded(withoutArticle(words))]
        let stop: Set = ["les", "des", "aux", "pour", "chez", "dans", "sur", "aller", "vers"]
        let wanted = Set(folded(words).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stop.contains($0) })
        let streets = ["rue", "impasse", "avenue", "boulevard", "allee", "chemin", "place", "route", "quai", "square"]
        let namesAStreet = streets.contains { said[1].hasPrefix($0 + " ") }
        func score(_ place: (name: String, isPointOfInterest: Bool)) -> Int {
            let name = folded(place.name)
            let words = Set(name.split(separator: " ").map(String.init))
            var score = wanted.filter { words.contains($0) }.count
            if said.contains(name) { score += 3 }
            if place.isPointOfInterest { score += 2 }
            if !namesAStreet, streets.contains(where: { name.hasPrefix($0 + " ") }) { score -= 3 }
            return score
        }
        return found.indices.max { a, b in score(found[a]) < score(found[b]) || score(found[a]) == score(found[b]) && a > b }
    }

    /// What the model reads of a trip: the note, where from and where to, how, how long, and when to leave and arrive.
    public static func forModel(_ trip: TravelEstimate, context: ToolContext) -> JSONValue {
        let french = ToolContext(now: context.now, timeZone: context.timeZone, language: .french)
        var fields: [String: JSONValue] = [
            "a_savoir": .string(BuiltInSources.note),
            "depart": .string(trip.origin ?? "là où est l’utilisateur"),
            "destination": .string(trip.destination),
            "mode": .string(trip.mode == .car ? "en voiture, avec le trafic prévu" : "en transports en commun"),
            "duree": .string(SpokenNumbers.duration(seconds: trip.seconds)),
            "heure_de_depart": .string(ActionPhrases.time(trip.departure, french)
                                       + (trip.arriveBy ? "" : leavingNow(trip, context) ? " (maintenant)" : "")),
            "heure_d_arrivee": .string(ActionPhrases.time(trip.arrival, french)),
        ]
        if let meters = trip.meters, meters > 0 { fields["distance"] = .string(SpokenNumbers.distance(meters: meters)) }
        if trip.arriveBy { fields["pour_arriver_a"] = .string(ActionPhrases.time(trip.arrival, french)) }
        return .object(fields)
    }

    private static func leavingNow(_ trip: TravelEstimate, _ context: ToolContext) -> Bool {
        trip.departure.timeIntervalSince(context.now) < 5 * 60
    }

    /// What the app says when the model gives nothing.
    public static func spoken(_ trip: TravelEstimate, context: ToolContext) -> String {
        let french = ToolContext(now: context.now, timeZone: context.timeZone, language: .french)
        let how = trip.mode == .car ? "en voiture" : "en transports en commun"
        let duration = SpokenNumbers.duration(seconds: trip.seconds)
        if trip.arriveBy {
            return "Pour arriver à \(ActionPhrases.time(trip.arrival, french)) \(how), pars à "
                + "\(ActionPhrases.time(trip.departure, french))\u{00A0}: il faut \(duration)."
        }
        return "Il faut \(duration) \(how) jusqu’à \(trip.destination)\u{00A0}: tu arrives à "
            + "\(ActionPhrases.time(trip.arrival, french)) en partant à \(ActionPhrases.time(trip.departure, french))."
    }
}

/// The travel time tool, temps_trajet: the model writes the destination in the user's words (and the origin, the mode
/// and the time to arrive by, when the user gives them); the app asks the maps service and the model sums it up.
///
/// Kept for the app's whole life; it offers its tool only while the built-in sources are switched on.
public actor TravelTimeTools: ToolProvider {
    public nonisolated let identifier = "travel"
    private var on: Bool
    private let here: any HereLocating
    private let estimator: any TravelEstimating

    public init(on: Bool = false, here: any HereLocating, estimator: any TravelEstimating) {
        self.on = on
        self.here = here
        self.estimator = estimator
    }

    /// Returns true when what the model sees changed.
    @discardableResult
    public func configure(_ on: Bool) -> Bool {
        defer { self.on = on }
        return self.on != on
    }

    public func tools() async -> [ToolSpec] { on ? [TravelTimeCatalog.spec] : [] }

    public func promptAddendum() async -> String? { on ? TravelTimeCatalog.promptAddendum : nil }

    public func risk(of call: ToolCall) async -> ToolRisk { .read }

    public func check(_ call: ToolCall, context: ToolContext) async throws {
        try TravelTimeCatalog.check(call, context: context)
    }

    public func waitingPhrase(for tool: String, language: SpeechLanguage) async -> String? {
        BuiltInSourcePhrases.waiting(for: tool, language)
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        let language = context.language
        try TravelTimeCatalog.check(call, context: context)
        let destination = TravelTimeCatalog.destination(call) ?? ""
        let origin = TravelTimeCatalog.origin(call)
        let arriveBy = try TravelTimeCatalog.arriveBy(call, context: context)
        // From where the Mac is, or from the place named: then the Mac's location only helps find it, and is not asked
        // for.
        let here: Place?
        if origin == nil {
            here = await self.here.here(context: context)
        } else {
            here = await self.here.willAsk() ? nil : await self.here.here()
        }
        guard origin != nil || here != nil else {
            throw ToolRefusal(forModel: "La position de l'utilisateur n'est pas connue : demande-lui d'où il part.",
                              spoken: BuiltInSourcePhrases.whereFor(weather: false, language), retryable: false)
        }
        do {
            let trip = try await estimator.estimate(to: destination, from: origin, here: here,
                                                    mode: TravelTimeCatalog.mode(call), arriveBy: arriveBy)
            DebugLog.log("travel: \(Int(trip.seconds)) s")
            return ToolOutcome(spoken: TravelTimeCatalog.spoken(trip, context: context),
                               forModel: TravelTimeCatalog.forModel(trip, context: context), modelSpeaks: true)
        } catch let error as SourceError {
            DebugLog.log("travel failed: \(error)")
            switch error {
            case .notFound:
                throw ToolRefusal(forModel: "Aucun endroit trouvé pour « \(destination) ».",
                                  spoken: BuiltInSourcePhrases.placeNotFound(destination, language), retryable: false)
            case .unexpected:
                throw ToolRefusal(forModel: "Aucun trajet trouvé jusqu'à « \(destination) ».",
                                  spoken: BuiltInSourcePhrases.noRoute(destination, language), retryable: false)
            case .unreachable:
                throw ToolRefusal(forModel: "Trajet impossible : le service de cartes ne répond pas.",
                                  spoken: BuiltInSourcePhrases.unreachable(TravelTimeCatalog.name, language),
                                  retryable: false)
            }
        }
    }
}
