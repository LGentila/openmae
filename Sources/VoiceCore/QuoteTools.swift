import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif

/// A currency or a crypto the quote tool knows, found from the model's words by the app (`QuoteCatalog.instrument`),
/// never from the model's memory of a symbol.
public enum Instrument: Sendable, Equatable {
    /// How much one `base` is worth in `quote` (ISO 4217 codes): the European Central Bank's reference rates.
    case currency(base: String, quote: String)
    /// A crypto, by its CoinGecko id ("bitcoin"), priced in `currency` ("EUR" or "USD").
    case crypto(id: String, name: String, currency: String)
}

/// A price, and when it is from.
public struct Quote: Sendable, Equatable {
    public var instrument: Instrument
    /// In the instrument's quote currency.
    public var price: Double
    /// The crypto's price in the other currency (dollars for a price in euros, and the other way round).
    public var otherPrice: Double?
    /// Since the day before (currencies) or over 24 hours (cryptos), in %.
    public var changePercent: Double?
    /// When the price is from: a day for the ECB's rates (`hasTime` false), the minute for a crypto.
    public var time: Date
    public var hasTime: Bool
}

/// The quote tool, as the model sees it (in French, like the other tools), how the app finds the instrument from the
/// model's words, and what the model is told of a price.
public enum QuoteCatalog {
    public static let name = "cours"

    // The example of the description is not a phrase of the benchmark's corpus (see ActionCatalog).
    public static let spec = ToolSpec(
        name: name,
        description: "Donne le dernier cours d'une devise (taux de change) ou d'une cryptomonnaie, sa variation et "
            + "l'heure ou le jour de ce cours. Pas pour une action ni un indice de bourse.",
        parameters: [
            ToolParameter("instrument", .string, "La devise, la paire de devises ou la cryptomonnaie, avec les mots "
                          + "de l'utilisateur (par exemple « franc suisse », « livre en euros », « ether »).",
                          required: true),
        ],
        risk: .read)

    /// Appended to the system prompt when the built-in sources are on.
    public static let promptAddendum = """
        Pour le cours d'une devise ou d'une cryptomonnaie, appelle cours plutôt que de chercher sur internet ; une \
        action ou un indice de bourse se cherche sur internet.
        """

    /// The instrument's words in a call.
    public static func words(_ call: ToolCall) -> String? {
        ["instrument", "devise", "nom", "symbole", "crypto", "paire"].lazy.compactMap { call.text($0) }.first
            .map { String($0.prefix(100)) }
    }

    /// Checks a call (the benchmark's "would the app accept it"): its words must stand for an instrument the app
    /// knows. Anything else (a share, an index) is refused, and the model is told to search the internet instead.
    public static func check(_ call: ToolCall, context: ToolContext) throws {
        _ = try instrument(of: call, context: context)
    }

    public static func instrument(of call: ToolCall, context: ToolContext) throws -> Instrument {
        guard let words = words(call) else {
            throw ToolRefusal(forModel: "Il manque « instrument » : la devise ou la cryptomonnaie.",
                              spoken: ActionPhrases.notUnderstood(context.language))
        }
        guard let found = instrument(words) else {
            throw ToolRefusal(forModel: "cours ne connaît que les devises et les cryptomonnaies, pas « \(words) ». "
                              + "Pour une action, un indice ou autre chose, cherche sur internet.",
                              spoken: BuiltInSourcePhrases.instrumentNotFound(words, context.language))
        }
        return found
    }

    // MARK: Finding the instrument

    /// The currencies of the ECB's reference rates, with the words people say for them ((singular, plural) first).
    static let currencies: [(code: String, unit: (String, String), words: [String])] = [
        ("EUR", ("euro", "euros"), ["euro", "euros", "eur"]),
        ("USD", ("dollar", "dollars"), ["dollar", "dollars", "dollar americain", "dollars americains", "usd",
                                        "billet vert", "dollar us"]),
        ("GBP", ("livre sterling", "livres sterling"), ["livre", "livres", "livre sterling", "livres sterling",
                                                        "sterling", "gbp", "livre anglaise", "livre britannique"]),
        ("CHF", ("franc suisse", "francs suisses"), ["franc suisse", "francs suisses", "chf"]),
        ("JPY", ("yen", "yens"), ["yen", "yens", "jpy"]),
        ("CAD", ("dollar canadien", "dollars canadiens"), ["dollar canadien", "dollars canadiens", "cad"]),
        ("AUD", ("dollar australien", "dollars australiens"), ["dollar australien", "dollars australiens", "aud"]),
        ("NZD", ("dollar néo-zélandais", "dollars néo-zélandais"), ["dollar neo-zelandais", "dollar neo zelandais",
                                                                    "nzd"]),
        ("HKD", ("dollar de Hong Kong", "dollars de Hong Kong"), ["dollar de hong kong", "dollars de hong kong", "hkd"]),
        ("SGD", ("dollar de Singapour", "dollars de Singapour"), ["dollar de singapour", "dollars de singapour", "sgd"]),
        ("CNY", ("yuan", "yuans"), ["yuan", "yuans", "renminbi", "cny"]),
        ("SEK", ("couronne suédoise", "couronnes suédoises"), ["couronne suedoise", "couronnes suedoises", "sek"]),
        ("NOK", ("couronne norvégienne", "couronnes norvégiennes"), ["couronne norvegienne", "couronnes norvegiennes",
                                                                     "nok"]),
        ("DKK", ("couronne danoise", "couronnes danoises"), ["couronne danoise", "couronnes danoises", "dkk"]),
        ("CZK", ("couronne tchèque", "couronnes tchèques"), ["couronne tcheque", "couronnes tcheques", "czk"]),
        ("ISK", ("couronne islandaise", "couronnes islandaises"), ["couronne islandaise", "isk"]),
        ("PLN", ("zloty", "zlotys"), ["zloty", "zlotys", "pln"]),
        ("HUF", ("forint", "forints"), ["forint", "forints", "huf"]),
        ("RON", ("leu roumain", "lei roumains"), ["leu roumain", "lei roumains", "leu", "ron"]),
        ("TRY", ("livre turque", "livres turques"), ["livre turque", "livres turques", "try"]),
        ("INR", ("roupie indienne", "roupies indiennes"), ["roupie", "roupies", "roupie indienne", "inr"]),
        ("BRL", ("réal brésilien", "réals brésiliens"), ["real", "reals", "real bresilien", "reais", "brl"]),
        ("MXN", ("peso mexicain", "pesos mexicains"), ["peso mexicain", "pesos mexicains", "peso", "mxn"]),
        ("ZAR", ("rand", "rands"), ["rand", "rands", "zar"]),
        ("KRW", ("won", "wons"), ["won", "wons", "krw"]),
        ("ILS", ("shekel", "shekels"), ["shekel", "shekels"]),
        ("THB", ("baht", "bahts"), ["baht", "bahts", "thb"]),
    ]

    /// The cryptos the app knows, by CoinGecko id, with their names and symbols.
    static let cryptos: [(id: String, name: String, words: [String])] = [
        ("bitcoin", "bitcoin", ["bitcoin", "bitcoins", "btc"]),
        ("ethereum", "ether", ["ether", "ethereum", "eth"]),
        ("solana", "solana", ["solana", "sol"]),
        ("ripple", "XRP", ["xrp", "ripple"]),
        ("binancecoin", "BNB", ["bnb", "binance coin"]),
        ("dogecoin", "dogecoin", ["dogecoin", "doge"]),
        ("cardano", "cardano", ["cardano", "ada"]),
        ("litecoin", "litecoin", ["litecoin", "ltc"]),
        ("tron", "tron", ["tron", "trx"]),
        ("polkadot", "polkadot", ["polkadot", "dot"]),
        ("chainlink", "chainlink", ["chainlink", "link"]),
        ("tether", "tether", ["tether", "usdt"]),
        ("usd-coin", "USDC", ["usdc", "usd coin"]),
    ]

    static func unit(_ code: String) -> (String, String) {
        currencies.first { $0.code == code }?.unit ?? (code, code)
    }

    /// The instrument the words stand for: one or two currencies ("dollar" is the euro in dollars, "dollar en euros"
    /// the other way round, "EUR/USD"), or a crypto ("bitcoin", "bitcoin en dollars"). nil for anything else.
    public static func instrument(_ words: String) -> Instrument? {
        let text = " " + words.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression) + " "
        // "EURUSD", "EUR/USD", "eur-usd".
        if let pair = text.range(of: #" ([a-z]{3}) ?([a-z]{3}) "#, options: .regularExpression) {
            let letters = text[pair].filter(\.isLetter)
            let base = String(letters.prefix(3)).uppercased(), quote = String(letters.suffix(3)).uppercased()
            let codes = Set(currencies.map(\.code))
            if base != quote, codes.contains(base), codes.contains(quote) { return .currency(base: base, quote: quote) }
        }
        let inDollars = text.contains(" dollar") || text.contains(" usd ")
        for crypto in cryptos where crypto.words.contains(where: { text.contains(" \($0) ") }) {
            return .crypto(id: crypto.id, name: crypto.name, currency: inDollars ? "USD" : "EUR")
        }
        // The currencies named, in their order: the longest words first ("dollar canadien" before "dollar").
        var found: [(position: String.Index, code: String)] = []
        var rest = text
        let words = currencies.flatMap { currency in currency.words.map { (word: $0, code: currency.code) } }
            .sorted { $0.word.count > $1.word.count }
        for (word, code) in words {
            while let range = rest.range(of: " \(word) ") {
                found.append((range.lowerBound, code))
                rest.replaceSubrange(range, with: " " + String(repeating: "#", count: word.count) + " ")
            }
        }
        let codes = found.sorted { $0.position < $1.position }.map(\.code)
            .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        // One currency alone is said in euros ("le dollar": 1 dollar is worth so many euros), the euro alone in dollars.
        switch codes.count {
        case 0: return nil
        case 1: return codes[0] == "EUR" ? .currency(base: "EUR", quote: "USD") : .currency(base: codes[0], quote: "EUR")
        default: return .currency(base: codes[0], quote: codes[1])
        }
    }

    // MARK: What the model is told

    /// "1 euro vaut 1,12 dollar", "1 dollar vaut 0,89 euro".
    static func rate(_ value: Double, base: String, quote: String) -> String {
        let decimals = value >= 100 ? 0 : value >= 0.1 ? 2 : 4
        let quoteUnit = unit(quote)
        return "1\u{00A0}\(unit(base).0) vaut \(SpokenNumbers.decimal(value, decimals: decimals))\u{00A0}"
            + (value >= 2 ? quoteUnit.1 : quoteUnit.0)
    }

    /// "aujourd’hui à 7 h", "hier, lundi 19 octobre", "vendredi 16 octobre".
    static func when(_ quote: Quote, _ context: ToolContext) -> String {
        let calendar = context.calendar
        let day = calendar.isDate(quote.time, inSameDayAs: context.now) ? "aujourd’hui"
            : calendar.isDate(quote.time, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: context.now)!)
                ? "hier, " + ActionPhrases.day(quote.time, context) : ActionPhrases.day(quote.time, context)
        return quote.hasTime ? day + " à " + ActionPhrases.time(quote.time, context) : day
    }

    /// "d’hier, lundi 19 octobre", "d’aujourd’hui", "du vendredi 16 octobre".
    static func of(_ moment: String) -> String {
        moment.hasPrefix("hier") || moment.hasPrefix("aujourd") ? "d’" + moment : "du " + moment
    }

    /// Read first, with the sources' note: a quote is always said with its day or time.
    static let note = BuiltInSources.note + " Dis toujours de quand date le cours."

    /// What the model reads of a price: the note, the instrument, the price and its change written the way they are
    /// said, and when the price is from (the ECB's rate of a day: no rate on weekends and holidays).
    public static func forModel(_ quote: Quote, context: ToolContext) -> JSONValue {
        let french = ToolContext(now: context.now, timeZone: context.timeZone, language: .french)
        var fields: [String: JSONValue] = ["a_savoir": .string(note)]
        let moment = when(quote, french)
        switch quote.instrument {
        case .currency(let base, let quoteCode):
            fields["instrument"] = .string("\(unit(base).0) en \(unit(quoteCode).1)")
            fields["cours"] = .string(rate(quote.price, base: base, quote: quoteCode) + " (taux \(of(moment)))")
            if quote.price > 0 {
                fields["inverse"] = .string(rate(1 / quote.price, base: quoteCode, quote: base) + " (taux \(of(moment)))")
            }
            if let change = quote.changePercent {
                fields["variation"] = .string(SpokenNumbers.change(percent: change) + " sur le jour d’avant")
            }
            fields["date"] = .string("taux de référence de la Banque centrale européenne, publié chaque jour ouvré vers "
                                     + "16\u{00A0}h\u{00A0}: le dernier est celui \(of(moment))")
        case .crypto(_, let name, let currency):
            let other = currency == "EUR" ? "USD" : "EUR"
            fields["instrument"] = .string(name)
            fields["cours"] = .string(SpokenNumbers.price(quote.price, unit: unit(currency)) + " (\(moment))")
            if let otherPrice = quote.otherPrice {
                fields["cours_en_\(unit(other).1)"] = .string(SpokenNumbers.price(otherPrice, unit: unit(other)))
            }
            if let change = quote.changePercent {
                fields["variation"] = .string(SpokenNumbers.change(percent: change) + " sur 24\u{00A0}heures")
            }
            fields["date"] = .string(moment + ", marché ouvert jour et nuit")
        }
        return .object(fields)
    }

    /// What the app says when the model gives nothing.
    public static func spoken(_ quote: Quote, context: ToolContext) -> String {
        let french = ToolContext(now: context.now, timeZone: context.timeZone, language: .french)
        switch quote.instrument {
        case .currency(let base, let quoteCode):
            return rate(quote.price, base: base, quote: quoteCode)
                + ", au taux de la Banque centrale européenne \(of(when(quote, french)))."
        case .crypto(_, let name, let currency):
            let change = quote.changePercent.map { ", " + SpokenNumbers.change(percent: $0) + " sur 24\u{00A0}heures" } ?? ""
            return "Le \(name) vaut \(SpokenNumbers.price(quote.price, unit: unit(currency)))\(change), "
                + "\(when(quote, french))."
        }
    }
}

/// Where the prices come from.
public protocol QuoteSource: Sendable {
    func quote(_ instrument: Instrument) async throws -> Quote
}

/// Free sources without a key: the European Central Bank's reference rates, through Frankfurter
/// (https://frankfurter.dev, open source), for currencies; CoinGecko's public API (https://www.coingecko.com) for
/// cryptos. Only the currencies' codes, or the crypto's id, leave the Mac.
public struct PublicQuotes: QuoteSource {
    private let session: URLSession
    private let ratesAddress: URL
    private let cryptoAddress: URL

    public init(ratesAddress: URL = URL(string: "https://api.frankfurter.dev/v1/")!,
                cryptoAddress: URL = URL(string: "https://api.coingecko.com/api/v3/simple/price")!,
                timeout: TimeInterval = BuiltInSources.timeout)
    {
        self.ratesAddress = ratesAddress
        self.cryptoAddress = cryptoAddress
        session = .forSources(timeout: timeout)
    }

    public func quote(_ instrument: Instrument) async throws -> Quote {
        switch instrument {
        case .currency(let base, let quote):
            // The last ten days: the last rate, and the one of the working day before.
            let start = Date().addingTimeInterval(-10 * 86_400)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
            formatter.dateFormat = "yyyy-MM-dd"
            var address = URLComponents(url: ratesAddress.appending(path: formatter.string(from: start) + ".."),
                                        resolvingAgainstBaseURL: false)!
            address.queryItems = [URLQueryItem(name: "base", value: base), URLQueryItem(name: "symbols", value: quote)]
            return try Self.rates(from: try await session.sourceData(address.url!), instrument: instrument)
        case .crypto(let id, _, _):
            var address = URLComponents(url: cryptoAddress, resolvingAgainstBaseURL: false)!
            address.queryItems = [
                URLQueryItem(name: "ids", value: id), URLQueryItem(name: "vs_currencies", value: "eur,usd"),
                URLQueryItem(name: "include_24hr_change", value: "true"),
                URLQueryItem(name: "include_last_updated_at", value: "true"),
            ]
            return try Self.crypto(from: try await session.sourceData(address.url!), instrument: instrument)
        }
    }

    private struct SeriesAnswer: Decodable {
        var rates: [String: [String: Double]]
    }

    /// A time series of Frankfurter (`/v1/<start>..?base=EUR&symbols=USD`): the last day's rate, its change since the
    /// day before. The days are the ECB's, in Frankfurt's time zone.
    public static func rates(from data: Data, instrument: Instrument) throws -> Quote {
        guard case .currency(_, let quote) = instrument,
              let answer = try? JSONDecoder().decode(SeriesAnswer.self, from: data)
        else { throw SourceError.unexpected }
        let days = answer.rates.compactMap { day, rates in rates[quote].map { (day, $0) } }.sorted { $0.0 < $1.0 }
        let frankfurt = TimeZone(identifier: "Europe/Berlin")!
        guard let last = days.last, let date = LocalDateTime.parse(last.0, in: frankfurt)?.date else {
            throw SourceError.unexpected
        }
        let before = days.dropLast().last?.1
        return Quote(instrument: instrument, price: last.1, otherPrice: nil,
                     changePercent: before.map { ($0 == 0 ? 0 : (last.1 - $0) / $0 * 100) }, time: date, hasTime: false)
    }

    /// CoinGecko's `simple/price` with both currencies, the 24-hour change and the time of the price.
    public static func crypto(from data: Data, instrument: Instrument) throws -> Quote {
        guard case .crypto(let id, _, let currency) = instrument,
              let answer = try? JSONDecoder().decode([String: [String: Double]].self, from: data),
              let fields = answer[id]
        else { throw SourceError.unexpected }
        let key = currency.lowercased(), other = currency == "EUR" ? "usd" : "eur"
        guard let price = fields[key] else { throw SourceError.notFound }
        let time = fields["last_updated_at"].map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Quote(instrument: instrument, price: price, otherPrice: fields[other],
                     changePercent: fields["\(key)_24h_change"], time: time, hasTime: true)
    }
}

/// The quote tool, cours: the model writes the currency or the crypto in the user's words, the app finds which one
/// it is, asks for its price, and the model sums it up with its time or day.
///
/// Kept for the app's whole life; it offers its tool only while the built-in sources are switched on.
public actor QuoteTools: ToolProvider {
    public nonisolated let identifier = "quotes"
    private var on: Bool
    private let source: any QuoteSource

    public init(on: Bool = false, source: any QuoteSource = PublicQuotes()) {
        self.on = on
        self.source = source
    }

    /// Returns true when what the model sees changed.
    @discardableResult
    public func configure(_ on: Bool) -> Bool {
        defer { self.on = on }
        return self.on != on
    }

    public func tools() async -> [ToolSpec] { on ? [QuoteCatalog.spec] : [] }

    public func promptAddendum() async -> String? { on ? QuoteCatalog.promptAddendum : nil }

    public func risk(of call: ToolCall) async -> ToolRisk { .read }

    public func check(_ call: ToolCall, context: ToolContext) async throws {
        try QuoteCatalog.check(call, context: context)
    }

    public func waitingPhrase(for tool: String, language: SpeechLanguage) async -> String? {
        BuiltInSourcePhrases.waiting(for: tool, language)
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        let instrument = try QuoteCatalog.instrument(of: call, context: context)
        do {
            let quote = try await source.quote(instrument)
            DebugLog.log("quote found")
            return ToolOutcome(spoken: QuoteCatalog.spoken(quote, context: context),
                               forModel: QuoteCatalog.forModel(quote, context: context), modelSpeaks: true)
        } catch let error as SourceError {
            DebugLog.log("quote failed: \(error)")
            throw ToolRefusal(forModel: "Cours impossible : le service ne répond pas.",
                              spoken: BuiltInSourcePhrases.unreachable(QuoteCatalog.name, context.language),
                              retryable: false)
        }
    }
}
