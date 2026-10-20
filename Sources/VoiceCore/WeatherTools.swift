import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif

/// The weather tool, as the model sees it (in French, like the other tools), and what it is told of a forecast.
public enum WeatherCatalog {
    public static let name = "meteo"

    // The example of the description is not a phrase of the benchmark's corpus (see ActionCatalog).
    public static let spec = ToolSpec(
        name: name,
        description: "Donne la météo d'un lieu : le temps qu'il fait maintenant et les prévisions jour par jour, "
            + "jusqu'à sept jours (températures, pluie, vent).",
        parameters: [
            ToolParameter("lieu", .string, "La ville ou l'endroit que l'utilisateur nomme (par exemple « Annecy »). "
                          + "Vide pour là où il est."),
            ToolParameter("jour", .string, "Le jour qu'il demande, avec ses mots (par exemple « jeudi », « ce "
                          + "week-end »). Vide pour maintenant."),
        ],
        risk: .read)

    /// Appended to the system prompt when the built-in sources are on.
    public static let promptAddendum = """
        Pour la météo (le temps qu'il fait, s'il va pleuvoir, les températures, jusqu'à sept jours), appelle meteo \
        plutôt que de chercher sur internet, avec le lieu seulement si l'utilisateur en nomme un : sans lieu, l'app \
        sait où il est.
        """

    /// The place the call names, if any ("ici" and the like mean where the user is).
    public static func place(_ call: ToolCall) -> String? {
        guard let text = ["lieu", "ville", "endroit", "location", "place"].lazy.compactMap({ call.text($0) }).first
        else { return nil }
        return isHere(text) ? nil : String(text.prefix(100))
    }

    /// "ici", "là où je suis", "ma position", "chez moi": where the user is, not a place to find.
    static func isHere(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.range(of: #"\b(ici|ma position|position actuelle|ma localisation|ou je suis|ou tu es|chez moi|"#
                            + #"a la maison|here|current location|actuel|actuelle)\b"#, options: .regularExpression) != nil
    }

    /// The days a call asks for, from its `jour`: nil for now (the current conditions and today), the day for "demain"
    /// or "samedi", Saturday and Sunday for "ce week-end", the seven days for "cette semaine". Throws a refusal for a
    /// day further than the forecast goes, or words that give no day.
    public static func days(_ call: ToolCall, context: ToolContext) throws -> [Date]? {
        guard let words = call.text("jour") ?? call.text("quand") ?? call.text("date") else { return nil }
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        let folded = words.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        if ["maintenant", "aujourd'hui", "aujourd’hui", "aujourdhui", "en ce moment", "actuellement", "now", "today"]
            .contains(where: { folded == $0 })
        {
            return nil
        }
        if folded.contains("semaine") || folded.contains("prochains jours") || folded.contains("week") && folded.contains("7") {
            return (0..<forecastDays).map(day)
        }
        if folded.contains("week-end") || folded.contains("weekend") || folded.contains("week end") {
            // The coming Saturday and Sunday (on a Sunday: today alone).
            let weekday = calendar.component(.weekday, from: today)  // 1 = Sunday, 7 = Saturday
            switch weekday {
            case 1: return [today]
            case 7: return [today, day(1)]
            default: return [day(7 - weekday), day(8 - weekday)]
            }
        }
        if folded.contains("ce soir") || folded.contains("cet apres-midi") || folded.contains("ce matin")
            || folded.contains("cette nuit")
        {
            return [today]
        }
        guard let moment = try? FrenchDates.moment(words, now: context.now, calendar: calendar) else {
            throw ToolRefusal(forModel: "Je ne comprends pas le jour « \(words) ». Donne-le avec les mots de "
                              + "l'utilisateur (« demain », « samedi »), ou laisse « jour » vide pour maintenant.",
                              spoken: ActionPhrases.notUnderstood(context.language))
        }
        let start = calendar.startOfDay(for: moment.start)
        let offset = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        guard offset >= 0, offset < forecastDays else {
            throw ToolRefusal(forModel: "Les prévisions ne vont que jusqu'à sept jours, à partir d'aujourd'hui.",
                              spoken: context.language == .french
                                  ? "Je n’ai les prévisions que pour les sept prochains jours."
                                  : "I only have the forecast for the next seven days.",
                              retryable: false)
        }
        return [start]
    }

    static let forecastDays = 7

    /// Checks a call (the benchmark's "would the app accept it").
    public static func check(_ call: ToolCall, context: ToolContext) throws {
        _ = try days(call, context: context)
    }

    /// What the model reads of a forecast: the note, the place, the current conditions when it asks for now, and the
    /// days it asks for, every number written the way it is said.
    public static func forModel(_ forecast: Forecast, days: [Date]?, context: ToolContext) -> JSONValue {
        let french = ToolContext(now: context.now, timeZone: forecast.timeZone, language: .french)
        let calendar = french.calendar
        var fields: [String: JSONValue] = ["a_savoir": .string(BuiltInSources.note), "lieu": .string(forecast.place.name)]
        let wanted = days ?? [calendar.startOfDay(for: context.now)]
        if days == nil, let now = forecast.current {
            var current: [String: JSONValue] = [
                "heure": .string(ActionPhrases.time(now.time, french)), "temps": .string(sky(now.code)),
                "temperature": .string(SpokenNumbers.degrees(now.temperature)),
            ]
            if let feels = now.feelsLike, abs(feels - now.temperature) >= 2 {
                current["ressenti"] = .string(SpokenNumbers.degrees(feels))
            }
            if let wind = now.wind { current["vent"] = .string(windSpeed(wind)) }
            fields["maintenant"] = .object(current)
        }
        let chosen = forecast.days.filter { day in wanted.contains { calendar.isDate($0, inSameDayAs: day.date) } }
        fields["previsions"] = .array(chosen.map { entry($0, calendar: calendar, context: french) })
        return .object(fields)
    }

    private static func entry(_ day: Forecast.Day, calendar: Calendar, context: ToolContext) -> JSONValue {
        let name = ActionPhrases.day(day.date, context)
        let label = calendar.isDate(day.date, inSameDayAs: context.now) ? "aujourd’hui, \(name)"
            : calendar.isDate(day.date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: context.now)!)
                ? "demain, \(name)" : name
        var fields: [String: JSONValue] = ["jour": .string(label), "temps": .string(sky(day.code))]
        if let low = day.low { fields["minimum"] = .string(SpokenNumbers.degrees(low)) }
        if let high = day.high { fields["maximum"] = .string(SpokenNumbers.degrees(high)) }
        if let chance = day.rainChance { fields["risque_de_pluie"] = .string("\(chance)\u{00A0}%") }
        if let rain = day.rain, rain >= 0.1 {
            fields["pluie"] = .string(SpokenNumbers.decimal(rain, decimals: rain < 10 ? 1 : 0) + "\u{00A0}millimètres")
        }
        if let wind = day.wind, wind >= 30 { fields["vent_maximum"] = .string(windSpeed(wind)) }
        return .object(fields)
    }

    private static func windSpeed(_ kilometersPerHour: Double) -> String {
        "\(Int(kilometersPerHour.rounded()))\u{00A0}kilomètres heure"
    }

    /// What the app says when the model gives nothing: the place, then now or the first day asked for.
    public static func spoken(_ forecast: Forecast, days: [Date]?, context: ToolContext) -> String {
        let french = ToolContext(now: context.now, timeZone: forecast.timeZone, language: .french)
        let calendar = french.calendar
        let place = forecast.place.name
        if days == nil, let now = forecast.current {
            return context.language == .french
                ? "À \(place), en ce moment\u{00A0}: \(sky(now.code)), \(SpokenNumbers.degrees(now.temperature))."
                : "In \(place) right now, \(Int(now.temperature.rounded())) degrees Celsius."
        }
        let first = days?.first ?? calendar.startOfDay(for: context.now)
        guard let day = forecast.days.first(where: { calendar.isDate($0.date, inSameDayAs: first) }) else {
            return BuiltInSourcePhrases.unreachable(name, context.language)
        }
        let low = day.low.map { Int($0.rounded()) }, high = day.high.map { Int($0.rounded()) }
        if context.language == .english {
            return "In \(place), \(ActionPhrases.day(day.date, ToolContext(now: context.now, language: .english))): "
                + "\(low ?? 0) to \(high ?? 0) degrees Celsius."
        }
        let range = low.flatMap { low in high.map { "de \(low) à \(SpokenNumbers.degrees(Double($0)))" } } ?? ""
        let rain = day.rainChance.map { ", \($0)\u{00A0}% de risque de pluie" } ?? ""
        return "À \(place), \(ActionPhrases.day(day.date, french))\u{00A0}: \(sky(day.code)), \(range)\(rain)."
    }

    /// The sky of a WMO weather code (the codes Open-Meteo gives), in French.
    public static func sky(_ code: Int) -> String {
        switch code {
        case 0: "ciel dégagé"
        case 1: "plutôt ensoleillé"
        case 2: "éclaircies et nuages"
        case 3: "ciel couvert"
        case 45, 48: "brouillard"
        case 51, 53: "bruine"
        case 55: "bruine forte"
        case 56, 57: "bruine verglaçante"
        case 61: "pluie faible"
        case 63: "pluie"
        case 65: "forte pluie"
        case 66, 67: "pluie verglaçante"
        case 71: "neige faible"
        case 73: "neige"
        case 75: "forte neige"
        case 77: "grains de neige"
        case 80: "quelques averses"
        case 81: "averses"
        case 82: "fortes averses"
        case 85, 86: "averses de neige"
        case 95: "orages"
        case 96, 99: "orages avec grêle"
        default: "temps variable"
        }
    }
}

/// A forecast: the current conditions and the next days, in the place's time zone.
public struct Forecast: Sendable, Equatable {
    public struct Now: Sendable, Equatable {
        public var time: Date
        public var temperature: Double
        public var feelsLike: Double?
        public var code: Int
        /// km/h.
        public var wind: Double?
    }

    public struct Day: Sendable, Equatable {
        /// The day's start, in the place's time zone.
        public var date: Date
        public var code: Int
        public var low: Double?
        public var high: Double?
        /// The highest chance of rain of the day, in %.
        public var rainChance: Int?
        /// mm.
        public var rain: Double?
        /// The strongest wind of the day, km/h.
        public var wind: Double?
    }

    public var place: Place
    public var timeZone: TimeZone
    public var current: Now?
    public var days: [Day]
}

/// Where the forecasts come from.
public protocol WeatherSource: Sendable {
    func forecast(at place: Place) async throws -> Forecast
}

/// Finds a place the user named.
public protocol PlaceFinding: Sendable {
    /// The place `name` stands for, near `near` when there are several; nil when there is none.
    func find(_ name: String, near: Place?) async throws -> Place?
}

/// Open-Meteo (https://open-meteo.com): forecasts from the national weather services' models (Météo-France's among
/// them), and its geocoding of town names. Free, no key, for non-commercial use; data under CC BY 4.0 (credited in the
/// settings). Only the place's coordinates, or the name the user said, leave the Mac.
public struct OpenMeteo: WeatherSource, PlaceFinding {
    private let session: URLSession
    private let forecastAddress: URL
    private let geocodingAddress: URL

    public init(forecastAddress: URL = URL(string: "https://api.open-meteo.com/v1/forecast")!,
                geocodingAddress: URL = URL(string: "https://geocoding-api.open-meteo.com/v1/search")!,
                timeout: TimeInterval = BuiltInSources.timeout)
    {
        self.forecastAddress = forecastAddress
        self.geocodingAddress = geocodingAddress
        session = .forSources(timeout: timeout)
    }

    public func forecast(at place: Place) async throws -> Forecast {
        var address = URLComponents(url: forecastAddress, resolvingAgainstBaseURL: false)!
        address.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,"
                         + "precipitation_probability_max,precipitation_sum,wind_speed_10m_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(WeatherCatalog.forecastDays)),
        ]
        return try Self.forecast(from: try await session.sourceData(address.url!), place: place)
    }

    public func find(_ name: String, near: Place?) async throws -> Place? {
        var address = URLComponents(url: geocodingAddress, resolvingAgainstBaseURL: false)!
        address.queryItems = [
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "fr"), URLQueryItem(name: "format", value: "json"),
        ]
        return try Self.place(from: try await session.sourceData(address.url!), named: name)
    }

    // MARK: Reading the answers

    // The keys are spelled out: JSONDecoder's snake case would read "temperature_2m" as "temperature2M".
    private struct ForecastAnswer: Decodable {
        struct Current: Decodable {
            var time: String
            var temperature: Double
            var feelsLike: Double?
            var code: Int
            var wind: Double?

            enum CodingKeys: String, CodingKey {
                case time, temperature = "temperature_2m", feelsLike = "apparent_temperature", code = "weather_code",
                     wind = "wind_speed_10m"
            }
        }

        struct Daily: Decodable {
            var time: [String]
            var code: [Int?]
            var high: [Double?]?
            var low: [Double?]?
            var rainChance: [Int?]?
            var rain: [Double?]?
            var wind: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time, code = "weather_code", high = "temperature_2m_max", low = "temperature_2m_min",
                     rainChance = "precipitation_probability_max", rain = "precipitation_sum", wind = "wind_speed_10m_max"
            }
        }

        var timezone: String?
        var current: Current?
        var daily: Daily
    }

    /// A forecast answer (`/v1/forecast` with `timezone=auto`): its times are the place's local times.
    public static func forecast(from data: Data, place: Place) throws -> Forecast {
        guard let answer = try? JSONDecoder().decode(ForecastAnswer.self, from: data) else { throw SourceError.unexpected }
        let timeZone = answer.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        func date(_ text: String) -> Date? { LocalDateTime.parse(text, in: timeZone)?.date }
        let current = answer.current.flatMap { now in
            date(now.time).map {
                Forecast.Now(time: $0, temperature: now.temperature, feelsLike: now.feelsLike, code: now.code, wind: now.wind)
            }
        }
        let daily = answer.daily
        func at<T>(_ values: [T?]?, _ index: Int) -> T? {
            guard let values, index < values.count else { return nil }
            return values[index]
        }
        let days: [Forecast.Day] = daily.time.indices.compactMap { index in
            guard let day = date(daily.time[index]) else { return nil }
            return Forecast.Day(date: day, code: at(daily.code, index) ?? -1, low: at(daily.low, index),
                                high: at(daily.high, index), rainChance: at(daily.rainChance, index),
                                rain: at(daily.rain, index), wind: at(daily.wind, index))
        }
        guard !days.isEmpty else { throw SourceError.unexpected }
        return Forecast(place: place, timeZone: timeZone, current: current, days: days)
    }

    private struct GeocodingAnswer: Decodable {
        struct Result: Decodable {
            var name: String
            var latitude: Double
            var longitude: Double
            var countryCode: String?
            var country: String?
            var admin1: String?
        }

        var results: [Result]?
    }

    /// A geocoding answer (`/v1/search`): its first result (the most populated of that name), or the first French one
    /// of exactly that name ("Valence" is the Drôme's, not Valencia).
    public static func place(from data: Data, named name: String) throws -> Place? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let answer = try? decoder.decode(GeocodingAnswer.self, from: data) else { throw SourceError.unexpected }
        let results = answer.results ?? []
        func folded(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let french = results.first { $0.countryCode == "FR" && folded($0.name) == folded(name) }
        guard let chosen = french ?? results.first else { return nil }
        let region = [chosen.admin1, chosen.country].compactMap { $0 }.joined(separator: ", ")
        return Place(name: chosen.name, latitude: chosen.latitude, longitude: chosen.longitude,
                     region: region.isEmpty ? nil : region)
    }
}

/// The weather tool, meteo: the model writes the place the user named (or none, for where the Mac is) and the day; the
/// app asks Open-Meteo and the model sums up the forecast in a sentence or two.
///
/// Kept for the app's whole life; it offers its tool only while the built-in sources are switched on.
public actor WeatherTools: ToolProvider {
    public nonisolated let identifier = "weather"
    private var on: Bool
    private let here: any HereLocating
    private let places: any PlaceFinding
    private let source: any WeatherSource

    public init(on: Bool = false, here: any HereLocating, places: any PlaceFinding = OpenMeteo(),
                source: any WeatherSource = OpenMeteo())
    {
        self.on = on
        self.here = here
        self.places = places
        self.source = source
    }

    /// Returns true when what the model sees changed.
    @discardableResult
    public func configure(_ on: Bool) -> Bool {
        defer { self.on = on }
        return self.on != on
    }

    public func tools() async -> [ToolSpec] { on ? [WeatherCatalog.spec] : [] }

    public func promptAddendum() async -> String? { on ? WeatherCatalog.promptAddendum : nil }

    public func risk(of call: ToolCall) async -> ToolRisk { .read }

    public func check(_ call: ToolCall, context: ToolContext) async throws {
        try WeatherCatalog.check(call, context: context)
    }

    public func waitingPhrase(for tool: String, language: SpeechLanguage) async -> String? {
        BuiltInSourcePhrases.waiting(for: tool, language)
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        let language = context.language
        let days = try WeatherCatalog.days(call, context: context)
        do {
            let forecast = try await source.forecast(at: try await resolvePlace(call, context: context))
            DebugLog.log("weather: \(forecast.days.count) days")
            return ToolOutcome(spoken: WeatherCatalog.spoken(forecast, days: days, context: context),
                               forModel: WeatherCatalog.forModel(forecast, days: days, context: context),
                               modelSpeaks: true)
        } catch let error as SourceError {
            DebugLog.log("weather failed: \(error)")
            throw ToolRefusal(forModel: "Météo impossible : le service ne répond pas.",
                              spoken: BuiltInSourcePhrases.unreachable(WeatherCatalog.name, language), retryable: false)
        }
    }

    /// The place the user named (found without the Mac's location), or where the Mac is.
    private func resolvePlace(_ call: ToolCall, context: ToolContext) async throws -> Place {
        let language = context.language
        if let name = WeatherCatalog.place(call) {
            guard let found = try await places.find(name, near: nil) else {
                throw ToolRefusal(forModel: "Aucun lieu trouvé pour « \(name) ».",
                                  spoken: BuiltInSourcePhrases.placeNotFound(name, language), retryable: false)
            }
            return found
        }
        guard let place = await here.here(context: context) else {
            throw ToolRefusal(forModel: "La position de l'utilisateur n'est pas connue : demande-lui pour quelle ville.",
                              spoken: BuiltInSourcePhrases.whereFor(weather: true, language), retryable: false)
        }
        return place
    }
}
