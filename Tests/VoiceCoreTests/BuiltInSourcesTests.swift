import Foundation
import Testing

@testable import VoiceCore

private let paris = TimeZone(identifier: "Europe/Paris")!
/// Tuesday 20 October 2026, 7:30, when the answers below were recorded.
private let now = LocalDateTime.parse("2026-10-20T07:30", in: paris)!.date
private let nb = "\u{00A0}"

private func context(_ language: SpeechLanguage = .french) -> ToolContext {
    ToolContext(now: now, timeZone: paris, language: language)
}

private func day(_ text: String) -> Date { LocalDateTime.parse(text, in: paris)!.date }

private func fields(_ value: JSONValue) -> [String: JSONValue] {
    guard case .object(let fields) = value else { return [:] }
    return fields
}

// Real answers of 20 October 2026 (Open-Meteo for Lyon; Open-Meteo's geocoding for « Valence », shortened;
// Frankfurter's series for the euro in dollars; CoinGecko for bitcoin).
private let lyonForecast = Data(#"""
{"latitude":45.755363,"longitude":4.852546,"generationtime_ms":0.84,"utc_offset_seconds":7200,"timezone":"Europe/Paris","timezone_abbreviation":"GMT+2","elevation":176.0,"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","apparent_temperature":"°C","weather_code":"wmo code","wind_speed_10m":"km/h"},"current":{"time":"2026-10-20T07:00","interval":900,"temperature_2m":11.5,"apparent_temperature":11.3,"weather_code":61,"wind_speed_10m":2.1},"daily_units":{"time":"iso8601"},"daily":{"time":["2026-10-20","2026-10-21","2026-10-22","2026-10-23","2026-10-24","2026-10-25","2026-10-26"],"weather_code":[63,80,45,61,3,80,61],"temperature_2m_max":[14.5,14.4,15.2,16.9,13.3,16.2,13.7],"temperature_2m_min":[10.8,8.5,4.5,10.1,8.6,8.8,7.0],"precipitation_probability_max":[100,95,0,35,56,83,49],"precipitation_sum":[46.10,2.10,0.00,0.60,1.05,7.05,0.30],"wind_speed_10m_max":[10.0,7.3,5.6,15.8,9.2,20.3,7.9]}}
"""#.utf8)

private let valence = Data(#"""
{"results":[{"id":2509954,"name":"Valence","latitude":39.47391,"longitude":-0.37966,"country_code":"ES","country":"Espagne","admin1":"Communauté Valencienne","population":824340},{"id":2971053,"name":"Valence","latitude":44.9256,"longitude":4.90956,"country_code":"FR","country":"France","admin1":"Auvergne-Rhône-Alpes","population":63864}],"generationtime_ms":1.2}
"""#.utf8)

private let euroInDollars = Data(#"""
{"amount":1.0,"base":"EUR","start_date":"2026-10-12","end_date":"2026-10-19","rates":{"2026-10-12":{"USD":1.1181},"2026-10-13":{"USD":1.1188},"2026-10-14":{"USD":1.1195},"2026-10-15":{"USD":1.1208},"2026-10-16":{"USD":1.1253},"2026-10-19":{"USD":1.1225}}}
"""#.utf8)

private let bitcoin = Data(#"""
{"bitcoin":{"eur":73016,"eur_24h_change":-0.8428426698424354,"usd":82025,"usd_24h_change":-0.8281389079835619,"last_updated_at":1792472401}}
"""#.utf8)

private let lyon = Place(name: "Lyon", latitude: 45.74906, longitude: 4.84789)
private let cergy = Place(name: "Cergy", latitude: 49.0364, longitude: 2.0761)

private struct FakeWeather: WeatherSource, PlaceFinding {
    func forecast(at place: Place) async throws -> Forecast { try OpenMeteo.forecast(from: lyonForecast, place: place) }
    func find(_ name: String, near: Place?) async throws -> Place? { name == "Lyon" ? lyon : nil }
}

private struct FakeQuotes: QuoteSource {
    func quote(_ instrument: Instrument) async throws -> Quote {
        switch instrument {
        case .currency: try PublicQuotes.rates(from: euroInDollars, instrument: .currency(base: "EUR", quote: "USD"))
        case .crypto: try PublicQuotes.crypto(from: bitcoin, instrument: instrument)
        }
    }
}

private struct FakeTravel: TravelEstimating {
    func estimate(to destination: String, from origin: String?, here: Place?, mode: TravelMode, arriveBy: Date?)
        async throws -> TravelEstimate
    {
        guard destination.contains("gare") else { throw SourceError.notFound }
        let departure = arriveBy.map { $0.addingTimeInterval(-2880) } ?? now
        return TravelEstimate(origin: origin, destination: "Gare de Cergy Préfecture", mode: mode, seconds: 2880,
                              meters: 34_755, departure: departure, arrival: departure.addingTimeInterval(2880),
                              arriveBy: arriveBy != nil)
    }
}

@Suite struct SpokenNumbersTests {
    @Test func pricesAreSaidAsPeopleSayThem() {
        #expect(SpokenNumbers.price(182.40, unit: ("dollar", "dollars")) == "182\(nb)dollars 40")
        #expect(SpokenNumbers.price(1.05, unit: ("euro", "euros")) == "1\(nb)euro 05")
        #expect(SpokenNumbers.price(73_016, unit: ("euro", "euros")) == "73\(nb)016\(nb)euros")
        #expect(SpokenNumbers.price(0.4512, unit: ("dollar", "dollars")) == "0,4512\(nb)dollar")
    }

    @Test func temperaturesChangesDurationsAndDistances() {
        #expect(SpokenNumbers.degrees(17.6) == "18\(nb)degrés")
        #expect(SpokenNumbers.degrees(-2.4) == "moins 2\(nb)degrés")
        #expect(SpokenNumbers.degrees(0.8) == "1\(nb)degré")
        #expect(SpokenNumbers.change(percent: 1.23) == "en hausse de 1,2\(nb)%")
        #expect(SpokenNumbers.change(percent: -0.84) == "en baisse de 0,8\(nb)%")
        #expect(SpokenNumbers.change(percent: 0.01) == "stable")
        #expect(SpokenNumbers.duration(seconds: 2856) == "48\(nb)minutes")
        #expect(SpokenNumbers.duration(seconds: 4200) == "1\(nb)heure 10")
        #expect(SpokenNumbers.duration(seconds: 7200) == "2\(nb)heures")
        #expect(SpokenNumbers.distance(meters: 34_755) == "35\(nb)kilomètres")
        #expect(SpokenNumbers.distance(meters: 2_540) == "2,5\(nb)kilomètres")
        #expect(SpokenNumbers.distance(meters: 820) == "800\(nb)mètres")
    }

    @Test func theVoiceSaysPercentAndDegreesInWords() {
        #expect(SpeakableText.forVoice("en hausse de 1,2\(nb)%", language: .french) == "en hausse de 1,2 pour cent")
        #expect(SpeakableText.forVoice("Il fait 18 °C.", language: .french) == "Il fait 18 degrés.")
        #expect(SpeakableText.forVoice("Il fait 18°.", language: .french) == "Il fait 18 degrés.")
        #expect(SpeakableText.forVoice("up 1.2%", language: .english) == "up 1.2 percent")
    }
}

/// A "here" for which macOS would ask the user first.
private struct AskingHere: HereLocating {
    func here() async -> Place? { cergy }
    func willAsk() async -> Bool { true }
}

private actor Said {
    var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}

@Suite struct WeatherSourceTests {
    @Test func theUserHearsWhyBeforeMacOSAsksForTheLocation() async throws {
        let said = Said()
        let context = ToolContext(now: now, timeZone: paris, language: .french, say: { await said.add($0) })
        let tools = WeatherTools(on: true, here: AskingHere(), places: FakeWeather(), source: FakeWeather())
        _ = try await tools.perform(ToolCall(name: "meteo", arguments: ["lieu": "Lyon"]), context: context)
        #expect(await said.lines.isEmpty)  // a place named: the location is not needed
        let outcome = try await tools.perform(ToolCall(name: "meteo"), context: context)
        #expect(await said.lines == ["Il me faut la position de ton Mac\(nb): macOS va te la demander."])
        #expect(fields(outcome.forModel)["lieu"] == "Cergy")
    }

    @Test func readsOpenMeteosForecast() throws {
        let forecast = try OpenMeteo.forecast(from: lyonForecast, place: lyon)
        #expect(forecast.timeZone.identifier == "Europe/Paris")
        #expect(forecast.current?.temperature == 11.5)
        #expect(forecast.current?.code == 61)
        #expect(forecast.current?.time == day("2026-10-20T07:00"))
        #expect(forecast.days.count == 7)
        #expect(forecast.days[1].date == day("2026-10-21"))
        #expect(forecast.days[1].low == 8.5)
        #expect(forecast.days[1].high == 14.4)
        #expect(forecast.days[1].rainChance == 95)
        #expect(forecast.days[1].rain == 2.1)
    }

    @Test func aGarbledAnswerIsNotAForecast() {
        #expect(throws: SourceError.unexpected) { try OpenMeteo.forecast(from: Data("<html>".utf8), place: lyon) }
    }

    @Test func aFrenchTownOfExactlyThatNameComesFirst() throws {
        let found = try #require(try OpenMeteo.place(from: valence, named: "Valence"))
        #expect(found.latitude == 44.9256)
        #expect(found.region == "Auvergne-Rhône-Alpes, France")
        #expect(try OpenMeteo.place(from: Data(#"{"generationtime_ms":0.5}"#.utf8), named: "Xyzzy") == nil)
        // Not a French name: the most populated one.
        #expect(try OpenMeteo.place(from: valence, named: "Valencia")?.latitude == 39.47391)
    }

    @Test func theDaysOfACall() throws {
        func days(_ words: String?) throws -> [Date]? {
            try WeatherCatalog.days(ToolCall(name: "meteo", arguments: words.map { ["jour": .string($0)] } ?? [:]),
                                    context: context())
        }
        #expect(try days(nil) == nil)
        #expect(try days("aujourd'hui") == nil)
        #expect(try days("demain") == [day("2026-10-21")])
        #expect(try days("samedi") == [day("2026-10-24")])
        #expect(try days("ce week-end") == [day("2026-10-24"), day("2026-10-25")])
        #expect(try days("cette semaine")?.count == 7)
        #expect(try days("ce soir") == [day("2026-10-20")])
        // Further than the forecast: refused, and the model cannot do better.
        do {
            _ = try days("le 3 novembre")
            Issue.record("a day past the forecast was accepted")
        } catch let refusal as ToolRefusal {
            #expect(!refusal.retryable)
        }
        #expect(throws: ToolRefusal.self) { try days("blablabla") }
    }

    @Test func whatTheModelReadsOfNow() {
        let forecast = try! OpenMeteo.forecast(from: lyonForecast, place: lyon)
        let read = fields(WeatherCatalog.forModel(forecast, days: nil, context: context()))
        #expect(read["a_savoir"] == .string(BuiltInSources.note))
        #expect(read["lieu"] == "Lyon")
        let current = fields(read["maintenant"]!)
        #expect(current["temperature"] == .string("12\(nb)degrés"))
        #expect(current["temps"] == "pluie faible")
        #expect(current["heure"] == .string("7\(nb)h du matin"))
        guard case .array(let days)? = read["previsions"] else { Issue.record("no forecast"); return }
        #expect(days.count == 1)
        #expect(fields(days[0])["jour"] == "aujourd’hui, mardi 20 octobre")
        #expect(fields(days[0])["maximum"] == .string("15\(nb)degrés"))
        #expect(fields(days[0])["risque_de_pluie"] == .string("100\(nb)%"))
    }

    @Test func whatTheModelReadsOfTomorrow() {
        let forecast = try! OpenMeteo.forecast(from: lyonForecast, place: lyon)
        let read = fields(WeatherCatalog.forModel(forecast, days: [day("2026-10-21")], context: context()))
        #expect(read["maintenant"] == nil)
        guard case .array(let days)? = read["previsions"] else { Issue.record("no forecast"); return }
        #expect(days.count == 1)
        let tomorrow = fields(days[0])
        #expect(tomorrow["jour"] == "demain, mercredi 21 octobre")
        #expect(tomorrow["temps"] == "quelques averses")
        #expect(tomorrow["minimum"] == .string("9\(nb)degrés"))
        #expect(tomorrow["pluie"] == .string("2,1\(nb)millimètres"))
        #expect(WeatherCatalog.spoken(forecast, days: [day("2026-10-21")], context: context())
                == "À Lyon, mercredi 21 octobre\(nb): quelques averses, de 9 à 14\(nb)degrés, 95\(nb)% de risque de pluie.")
    }

    @Test func withoutAPlaceOrALocationMaeAsksWhere() async throws {
        let tools = WeatherTools(on: true, here: FixedHere(nil), places: FakeWeather(), source: FakeWeather())
        do {
            _ = try await tools.perform(ToolCall(name: "meteo"), context: context())
            Issue.record("a forecast without a place")
        } catch let refusal as ToolRefusal {
            #expect(refusal.spoken == "Je ne sais pas où tu es. Pour quelle ville veux-tu la météo\(nb)?")
            #expect(!refusal.retryable)
        }
        // « ici » is where the user is too.
        await #expect(throws: ToolRefusal.self) {
            try await tools.perform(ToolCall(name: "meteo", arguments: ["lieu": "ici"]), context: context())
        }
    }

    @Test func aNamedPlaceWinsOverHere() async throws {
        let tools = WeatherTools(on: true, here: FixedHere(cergy), places: FakeWeather(), source: FakeWeather())
        let outcome = try await tools.perform(ToolCall(name: "meteo", arguments: ["lieu": "Lyon", "jour": "demain"]),
                                              context: context())
        #expect(outcome.modelSpeaks)
        #expect(fields(outcome.forModel)["lieu"] == "Lyon")
        let here = try await tools.perform(ToolCall(name: "meteo"), context: context())
        #expect(fields(here.forModel)["lieu"] == "Cergy")
        await #expect(throws: ToolRefusal.self) {
            try await tools.perform(ToolCall(name: "meteo", arguments: ["lieu": "Atlantide"]), context: context())
        }
    }
}

@Suite struct QuoteSourceTests {
    private func found(_ words: String) -> Instrument? { QuoteCatalog.instrument(words) }

    @Test func findsTheInstrumentFromTheUsersWords() {
        #expect(found("dollar") == .currency(base: "USD", quote: "EUR"))
        #expect(found("le dollar") == .currency(base: "USD", quote: "EUR"))
        #expect(found("euro dollar") == .currency(base: "EUR", quote: "USD"))
        #expect(found("EUR/USD") == .currency(base: "EUR", quote: "USD"))
        #expect(found("eurusd") == .currency(base: "EUR", quote: "USD"))
        #expect(found("l'euro") == .currency(base: "EUR", quote: "USD"))
        #expect(found("dollar en euros") == .currency(base: "USD", quote: "EUR"))
        #expect(found("franc suisse") == .currency(base: "CHF", quote: "EUR"))
        #expect(found("dollar canadien") == .currency(base: "CAD", quote: "EUR"))
        #expect(found("livre sterling") == .currency(base: "GBP", quote: "EUR"))
        #expect(found("euro en livres") == .currency(base: "EUR", quote: "GBP"))
        #expect(found("la livre turque") == .currency(base: "TRY", quote: "EUR"))
        #expect(found("yen") == .currency(base: "JPY", quote: "EUR"))
        #expect(found("euro en yen") == .currency(base: "EUR", quote: "JPY"))
        #expect(found("bitcoin") == .crypto(id: "bitcoin", name: "bitcoin", currency: "EUR"))
        #expect(found("le Bitcoin en dollars") == .crypto(id: "bitcoin", name: "bitcoin", currency: "USD"))
        #expect(found("BTC") == .crypto(id: "bitcoin", name: "bitcoin", currency: "EUR"))
        #expect(found("ether") == .crypto(id: "ethereum", name: "ether", currency: "EUR"))
    }

    @Test func sharesAndIndicesAreNotItsOwn() {
        for words in ["Apple", "l'action Apple", "LVMH", "le CAC 40", "AAPL", "Total", "Nasdaq"] {
            #expect(found(words) == nil, "\(words)")
        }
        // The model is told to search the internet instead, and gets that second try.
        do {
            try QuoteCatalog.check(ToolCall(name: "cours", arguments: ["instrument": "Apple"]), context: context())
            Issue.record("a share was accepted")
        } catch let refusal as ToolRefusal {
            #expect(refusal.retryable)
            #expect(refusal.forModel.contains("cherche sur internet"))
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func readsTheECBsRates() throws {
        let quote = try PublicQuotes.rates(from: euroInDollars, instrument: .currency(base: "EUR", quote: "USD"))
        #expect(quote.price == 1.1225)
        #expect(!quote.hasTime)
        #expect(quote.time == LocalDateTime.parse("2026-10-19", in: TimeZone(identifier: "Europe/Berlin")!)!.date)
        #expect(abs((quote.changePercent ?? 0) - (1.1225 - 1.1253) / 1.1253 * 100) < 1e-9)
    }

    @Test func readsCoinGeckosPrice() throws {
        let instrument = Instrument.crypto(id: "bitcoin", name: "bitcoin", currency: "EUR")
        let quote = try PublicQuotes.crypto(from: bitcoin, instrument: instrument)
        #expect(quote.price == 73_016)
        #expect(quote.otherPrice == 82_025)
        #expect(quote.hasTime)
        #expect(quote.time == Date(timeIntervalSince1970: 1_792_472_401))
        #expect(throws: SourceError.self) {
            try PublicQuotes.crypto(from: bitcoin, instrument: .crypto(id: "ethereum", name: "ether", currency: "EUR"))
        }
    }

    @Test func whatTheModelReadsOfARate() throws {
        let quote = try PublicQuotes.rates(from: euroInDollars, instrument: .currency(base: "EUR", quote: "USD"))
        let read = fields(QuoteCatalog.forModel(quote, context: context()))
        #expect(read["a_savoir"]?.text?.hasSuffix("Dis toujours de quand date le cours.") == true)
        #expect(read["cours"] == .string("1\(nb)euro vaut 1,12\(nb)dollar (taux d’hier, lundi 19 octobre)"))
        #expect(read["inverse"] == .string("1\(nb)dollar vaut 0,89\(nb)euro (taux d’hier, lundi 19 octobre)"))
        #expect(read["variation"] == .string("en baisse de 0,2\(nb)% sur le jour d’avant"))
        #expect(read["date"]?.text?.hasSuffix("le dernier est celui d’hier, lundi 19 octobre") == true)
        #expect(QuoteCatalog.spoken(quote, context: context())
                == "1\(nb)euro vaut 1,12\(nb)dollar, au taux de la Banque centrale européenne d’hier, lundi 19 octobre.")
    }

    @Test func whatTheModelReadsOfACrypto() throws {
        let quote = try PublicQuotes.crypto(from: bitcoin, instrument: .crypto(id: "bitcoin", name: "bitcoin", currency: "EUR"))
        let read = fields(QuoteCatalog.forModel(quote, context: context()))
        #expect(read["cours"] == .string("73\(nb)016\(nb)euros (aujourd’hui à 7\(nb)h du matin)"))
        #expect(read["cours_en_dollars"] == .string("82\(nb)025\(nb)dollars"))
        #expect(read["variation"] == .string("en baisse de 0,8\(nb)% sur 24\(nb)heures"))
        #expect(read["date"] == .string("aujourd’hui à 7\(nb)h du matin, marché ouvert jour et nuit"))
    }

    @Test func theProviderSumsUpThroughTheModel() async throws {
        let tools = QuoteTools(on: true, source: FakeQuotes())
        let outcome = try await tools.perform(ToolCall(name: "cours", arguments: ["instrument": "bitcoin"]),
                                              context: context())
        #expect(outcome.modelSpeaks)
        #expect(outcome.spoken.hasPrefix("Le bitcoin vaut 73\(nb)016\(nb)euros, en baisse de 0,8\(nb)%"))
    }
}

@Suite struct TravelTimeSourceTests {
    @Test func readsTheCall() throws {
        let call = ToolCall(name: "temps_trajet", arguments: ["destination": "la gare de Cergy", "mode": "transports",
                                                              "arrivee": "à 9 h", "depart": "ici"])
        #expect(TravelTimeCatalog.destination(call) == "la gare de Cergy")
        #expect(TravelTimeCatalog.origin(call) == nil)
        #expect(TravelTimeCatalog.mode(call) == .transit)
        #expect(TravelTimeCatalog.mode(ToolCall(name: "temps_trajet")) == .car)
        #expect(try TravelTimeCatalog.arriveBy(call, context: context()) == day("2026-10-20T09:00"))
        #expect(throws: ToolRefusal.self) {
            try TravelTimeCatalog.check(ToolCall(name: "temps_trajet", arguments: ["mode": "voiture"]), context: context())
        }
    }

    @Test func findsThePlaceTheWordsStandFor() {
        #expect(TravelTimeCatalog.withoutArticle("la gare de Cergy") == "gare de Cergy")
        #expect(TravelTimeCatalog.withoutArticle("l'aéroport de Roissy") == "aéroport de Roissy")
        #expect(TravelTimeCatalog.withoutArticle("Versailles") == "Versailles")
        #expect(TravelTimeCatalog.withoutArticle("Lens") == "Lens")
        #expect(TravelTimeCatalog.withoutArticle("Laval") == "Laval")
        #expect(TravelTimeCatalog.withoutArticle("Le Havre") == "Havre")
        // What Apple's maps found on 20 October 2026, with the words and without their article.
        #expect(TravelTimeCatalog.bestPlace([("Rue de la Gare", false), ("Gare de Cergy Saint-Christophe", true),
                                             ("Gare de Cergy Préfecture", true)], for: "la gare de Cergy") == 1)
        #expect(TravelTimeCatalog.bestPlace([("Appartement à 15 mn en Train de Paris et à 20 mn en Voiture de "
                                              + "L'aéroport Roissy", false), ("Aéroport Paris-Charles de Gaulle", true)],
                                            for: "l'aéroport de Roissy") == 1)
        #expect(TravelTimeCatalog.bestPlace([("La Défense", false), ("Impasse de la Défense", false)],
                                            for: "la Défense") == 0)
        #expect(TravelTimeCatalog.bestPlace([("Versailles", false)], for: "Versailles") == 0)
        #expect(TravelTimeCatalog.bestPlace([("Rue de la Paix", false)], for: "rue de la Paix") == 0)
        #expect(TravelTimeCatalog.bestPlace([], for: "Atlantide") == nil)
    }

    @Test func whatTheModelReadsOfATrip() async throws {
        let tools = TravelTimeTools(on: true, here: FixedHere(cergy), estimator: FakeTravel())
        let outcome = try await tools.perform(ToolCall(name: "temps_trajet", arguments: ["destination": "la gare"]),
                                              context: context())
        #expect(outcome.modelSpeaks)
        let read = fields(outcome.forModel)
        #expect(read["duree"] == .string("48\(nb)minutes"))
        #expect(read["distance"] == .string("35\(nb)kilomètres"))
        #expect(read["mode"] == "en voiture, avec le trafic prévu")
        #expect(read["heure_de_depart"] == .string("7\(nb)h\(nb)30 du matin (maintenant)"))
        #expect(read["heure_d_arrivee"] == .string("8\(nb)h\(nb)18"))
        #expect(outcome.spoken == "Il faut 48\(nb)minutes en voiture jusqu’à Gare de Cergy Préfecture\(nb): tu arrives "
                + "à 8\(nb)h\(nb)18 en partant à 7\(nb)h\(nb)30 du matin.")
    }

    @Test func toArriveByATimeItSaysWhenToLeave() async throws {
        let tools = TravelTimeTools(on: true, here: FixedHere(cergy), estimator: FakeTravel())
        let outcome = try await tools.perform(
            ToolCall(name: "temps_trajet", arguments: ["destination": "la gare", "arrivee": "à 10 h"]), context: context())
        let read = fields(outcome.forModel)
        #expect(read["pour_arriver_a"] == .string("10\(nb)h"))
        #expect(read["heure_de_depart"] == .string("9\(nb)h\(nb)12"))
    }

    @Test func withoutALocationMaeAsksWhereFrom() async throws {
        let tools = TravelTimeTools(on: true, here: FixedHere(nil), estimator: FakeTravel())
        do {
            _ = try await tools.perform(ToolCall(name: "temps_trajet", arguments: ["destination": "la gare"]),
                                        context: context())
            Issue.record("a trip without an origin")
        } catch let refusal as ToolRefusal {
            #expect(refusal.spoken == "Je ne sais pas où tu es. D’où veux-tu partir\(nb)?")
        }
        await #expect(throws: ToolRefusal.self) {
            try await TravelTimeTools(on: true, here: FixedHere(cergy), estimator: FakeTravel())
                .perform(ToolCall(name: "temps_trajet", arguments: ["destination": "Atlantide"]), context: context())
        }
    }
}

@Suite struct BuiltInSourcesSwitchTests {
    @Test func theToolsAreOfferedOnlyWhenSwitchedOn() async {
        let weather = WeatherTools(here: FixedHere(nil))
        #expect(await weather.tools().isEmpty)
        #expect(await weather.promptAddendum() == nil)
        #expect(await weather.configure(true))
        #expect(await weather.tools().map(\.name) == ["meteo"])
        #expect(await !weather.configure(true))
        let quotes = QuoteTools()
        #expect(await quotes.configure(true))
        #expect(await quotes.waitingPhrase(for: "cours", language: .french) == "Je regarde le cours, un instant.")
    }

    @Test func settingsOfAnEarlierVersionHaveThemOff() throws {
        let earlier = Data(#"{"audioMode":"speakers","pushToTalk":false,"actionsEnabled":true}"#.utf8)
        #expect(try !JSONDecoder().decode(AssistantSettings.self, from: earlier).builtInSources)
        var settings = AssistantSettings()
        settings.builtInSources = true
        let again = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.builtInSources)
    }

    @Test func offeredOnTheTiersThatPassedTheBenchmark() {
        #expect(BuiltInSources.offered(on: .comfort))
        #expect(BuiltInSources.offered(on: .max))
        #expect(BuiltInSources.offered(on: .standard))
        #expect(!BuiltInSources.offered(on: .minimum))
    }

    /// So that a slip of two letters in a tool's name can only stand for one tool.
    @Test func theirNamesAreFarFromTheOtherTools() {
        let all = ActionCatalog.names(shortcuts: ["Salon"]) + AgentCatalog.names.sorted() + [WebSearchCatalog.searchName]
            + BuiltInSources.tools.map(\.name)
        for name in BuiltInSources.tools.map(\.name) {
            for other in all where other != name {
                #expect(ToolNames.distance(ToolNames.folded(name), ToolNames.folded(other)) >= 5, "\(name), \(other)")
            }
        }
    }
}
