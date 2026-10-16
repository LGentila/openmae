import Foundation
import Testing

@testable import VoiceCore

private func utc(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

@Suite("Brave Search", .serialized)
struct BraveSearchTests {
    @Test func searchesWithTheKeyInItsHeader() async throws {
        let server = FakeBrave()
        try await server.start()
        defer { server.stop() }
        let found = try await BraveSearchProvider(key: server.key, region: "FR", endpoint: server.endpoint, timeout: 2)
            .search("PSG résultat & score + C++", language: .french)
        let request = try #require(server.requests.last)
        #expect(request.method == "GET")
        #expect(request.path == "/res/v1/web/search")
        // A "+" or a "&" of the keywords stays one.
        #expect(request.query == ["q": "PSG résultat & score + C++", "count": "5", "country": "FR", "search_lang": "fr",
                                  "ui_lang": "fr-FR", "safesearch": "moderate", "text_decorations": "false"])
        #expect(request.headers["x-subscription-token"] == server.key)
        #expect(request.headers["accept"] == "application/json")
        #expect(request.headers["user-agent"] == AppIdentity.userAgent)
        #expect(request.headers["authorization"] == nil)
        #expect(request.headers["cookie"] == nil)
        #expect(request.body.isEmpty)
        // The first five the app can use: an FTP address and a result without one are left out.
        #expect(found.results.map(\.site) == ["L’Équipe", "RMC Sport", "psg.fr", "Wikipédia", "flashscore.fr"])
        #expect(found.found == 8)
        #expect(found.answer == nil)
        let first = try #require(found.results.first)
        // Highlighting and entities out, whatever the request asked.
        #expect(first.title == "PSG - Lens (2-1) : Paris s'impose")
        #expect(first.snippet == "Le PSG a battu Lens 2 à 1 au Parc des Princes & reste en tête…")
        #expect(first.url.absoluteString == "https://www.lequipe.fr/Football/match-direct/ligue-1/psg-lens")
        #expect(first.published == utc("2026-10-14T21:00:00Z"))
        let long = found.results[1]
        #expect(long.snippet.count <= WebResult.snippetLimit)
        #expect(long.snippet.hasSuffix("minute par minute, Un…"))  // between two words
        #expect(long.published == utc("2026-10-15T00:00:00Z"))  // its age, a day
        let club = found.results[2]
        #expect(club.title == "Calendrier & résultats - PSG.FR")
        #expect(club.snippet == "Tous les matchs du club. Moins de < 5 € la place ? Non : \"complet\".")
        #expect(club.published == nil)  // "2 days ago"
        #expect(found.results[3].published == utc("2026-09-30T00:00:00Z"))
        #expect(found.results[4].published == nil)

        _ = try await BraveSearchProvider(key: server.key, region: "FR", endpoint: server.endpoint, timeout: 2)
            .search("PSG", language: .english)
        #expect(server.requests.last?.query["search_lang"] == "en")
        #expect(server.requests.last?.query["ui_lang"] == "en-US")
    }

    /// The Mac's country first when Brave knows it, the interface language of that country when it has one.
    @Test func theMacsRegionAndTheConversationsLanguage() throws {
        let cases: [(region: String?, language: SpeechLanguage, country: String, interface: String)] = [
            ("FR", .french, "FR", "fr-FR"), ("BE", .french, "BE", "fr-BE"), ("ch", .french, "CH", "fr-CH"),
            ("CA", .english, "CA", "en-CA"), ("GB", .english, "GB", "en-GB"), ("FR", .english, "FR", "en-US"),
            ("US", .french, "US", "fr-FR"), ("LU", .french, "ALL", "fr-FR"), (nil, .english, "ALL", "en-US"),
        ]
        for (region, language, country, interface) in cases {
            let url = BraveSearchProvider(key: "k", region: region).url("PSG", language: language)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            #expect(fields["country"] == country, "\(String(describing: region)) \(language)")
            #expect(fields["ui_lang"] == interface, "\(String(describing: region)) \(language)")
            #expect(fields["search_lang"] == language.rawValue)
        }
        let url = BraveSearchProvider(key: "k", region: "FR").url("PSG", language: .french)
        #expect(url.absoluteString.hasPrefix("https://api.search.brave.com/res/v1/web/search?q=PSG&count=5&"))
    }

    @Test func aSearchThatFoundNothingIsNoError() async throws {
        let server = FakeBrave()
        try await server.start()
        defer { server.stop() }
        let provider = BraveSearchProvider(key: server.key, region: "FR", endpoint: server.endpoint, timeout: 2)
        for mode: FakeBrave.Mode in [.nothing, .noResults] {
            server.mode = mode
            let found = try await provider.search("xqzw", language: .french)
            #expect(found.isEmpty, "\(mode)")
            #expect(found.found == 0, "\(mode)")
        }
    }

    @Test func aKeyItRefuses() async throws {
        let server = FakeBrave()
        try await server.start()
        defer { server.stop() }
        let provider = BraveSearchProvider(key: "BSA-not-this-one", region: "FR", endpoint: server.endpoint, timeout: 2)
        await #expect(throws: WebSearchError.unauthorized) { try await provider.search("PSG", language: .french) }
        #expect(server.requests.last?.headers["x-subscription-token"] == "BSA-not-this-one")
    }

    @Test func failuresAreTold() async throws {
        let server = FakeBrave()
        try await server.start()
        defer { server.stop() }
        let provider = BraveSearchProvider(key: server.key, region: "FR", endpoint: server.endpoint, timeout: 0.5)
        let expected: [(FakeBrave.Mode, WebSearchError)] = [
            (.limit, .tooManyRequests), (.invalid, .unexpected(status: 422)), (.failing, .unexpected(status: 502)),
            (.emptyJSON, .unexpected(status: 200)), (.otherJSON, .unexpected(status: 200)), (.webPage, .unexpected(status: 200)),
        ]
        for (mode, error) in expected {
            server.mode = mode
            await #expect(throws: error, "\(mode)") { try await provider.search("PSG", language: .french) }
        }
        // Too slow: given up after the time limit.
        server.mode = .slow
        let start = ContinuousClock.now
        await #expect(throws: WebSearchError.unreachable) { try await provider.search("PSG", language: .french) }
        #expect(ContinuousClock.now - start < .seconds(1.5))
    }

    @Test func nobodyThereIsUnreachable() async throws {
        let server = FakeBrave()
        try await server.start()
        let endpoint = server.endpoint
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: WebSearchError.unreachable) {
            try await BraveSearchProvider(key: "k", region: "FR", endpoint: endpoint, timeout: 1).search("PSG", language: .french)
        }
    }

    @Test func htmlIsTakenOutOfTheTexts() {
        let cases = [
            "<strong>PSG</strong> &amp; Lens": "PSG & Lens",
            "l&#x27;OM et l&#39;OL, le &quot;derby&quot;": "l'OM et l'OL, le \"derby\"",
            "Moins de &lt; 5 € et plus de &gt; 2 €": "Moins de < 5 € et plus de > 2 €",
            "a < b et c > d": "a < b et c > d",
            "Ligne 1<br>Ligne 2<br/>Ligne 3": "Ligne 1 Ligne 2 Ligne 3",
            "<p>Un</p><p>Deux</p>": "Un Deux",
            "<a href=\"https://example.org\" target=\"_blank\">le lien</a>": "le lien",
            "&eacute;t&eacute; &hellip; &laquo;&nbsp;oui&nbsp;&raquo;": "été … « oui »",
            "&#128512; &#x1F600;": "😀 😀",
            "&inconnu; &amp co & fin &": "&inconnu; &amp co & fin &",
            "sans rien": "sans rien",
        ]
        for (html, text) in cases {
            #expect(WebResultText.clean(WebResultText.plain(html)) == text, "\(html)")
        }
    }

    @Test func theAgeWhenItIsADay() {
        #expect(BraveSearchProvider.day("October 15, 2026") == utc("2026-10-15T00:00:00Z"))
        #expect(BraveSearchProvider.day("Oct 15, 2026") == utc("2026-10-15T00:00:00Z"))
        #expect(BraveSearchProvider.day("2026-10-15T08:30:00") == utc("2026-10-15T08:30:00Z"))
        for text in ["2 days ago", "il y a 3 heures", "", nil] as [String?] {
            #expect(BraveSearchProvider.day(text) == nil, "\(String(describing: text))")
        }
    }
}
