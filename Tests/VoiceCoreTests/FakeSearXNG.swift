import Foundation

@testable import VoiceCore

/// A pretend SearXNG for the provider's tests: its search API (`POST /search`, `format=json`) on a local port, nothing
/// else. What it answers depends on its `mode`, and on a password when it has one (HTTP Basic Auth, as a protection in
/// front of SearXNG would ask).
final class FakeSearXNG: @unchecked Sendable {
    enum Mode: Sendable {
        /// Seven results (two the app cannot use), a direct answer and a card.
        case results
        /// Results and a card, without a direct answer.
        case cardOnly
        /// A search that found nothing.
        case empty
        /// Its JSON format is off: 403.
        case jsonOff
        /// Its limiter takes the app for a robot: 429.
        case limiter
        /// Answers after two seconds, longer than the tests' time limit.
        case slow
        /// JSON, but not a search's.
        case otherJSON
        /// A web page ("are you a robot?") instead of JSON.
        case webPage
        /// A server error: 502.
        case failing
    }

    typealias Request = LocalHTTPServer.Request

    private let server = LocalHTTPServer()
    private let lock = NSLock()
    private var currentMode = Mode.results
    /// "user:password" when it asks for one.
    let credentials: String?

    init(username: String? = nil, password: String? = nil) {
        credentials = password.map { (username ?? "") + ":" + $0 }
    }

    var address: URL { URL(string: "http://127.0.0.1:\(server.port)")! }
    var requests: [Request] { server.requests }
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    func start() async throws {
        try await server.start { [weak self] request in
            self?.route(request) ?? LocalHTTPServer.Response(status: 503, body: "", type: "text/plain")
        }
    }

    func stop() {
        server.stop()
    }

    private func route(_ request: Request) -> LocalHTTPServer.Response {
        guard request.path == "/search" else {
            return .init(status: 404, body: "<html><body>Not Found</body></html>", type: "text/html")
        }
        if let credentials {
            let expected = "Basic " + Data(credentials.utf8).base64EncodedString()
            guard request.headers["authorization"] == expected else {
                return .init(status: 401, body: "401 Unauthorized", type: "text/plain",
                             headers: "WWW-Authenticate: Basic realm=\"searxng\"\r\n")
            }
        }
        let query = request.form["q"] ?? ""
        switch mode {
        case .results: return .json(Self.page(query, answer: true))
        case .cardOnly: return .json(Self.page(query, answer: false))
        case .empty:
            return .json(["query": .string(query), "number_of_results": 0, "results": [], "answers": [],
                          "corrections": [], "infoboxes": [], "suggestions": [], "unresponsive_engines": []])
        case .jsonOff: return .init(status: 403, body: "<html><body><h1>Forbidden</h1></body></html>", type: "text/html")
        case .limiter: return .init(status: 429, body: "Too Many Requests", type: "text/plain")
        case .slow:
            var response = LocalHTTPServer.Response.json(Self.page(query, answer: true))
            response.delay = 2
            return response
        case .otherJSON: return .json(["status": "ok", "version": "2026.10.16"])
        case .webPage:
            return .init(status: 200, body: "<!DOCTYPE html><html><body>Vérification que vous n'êtes pas un robot…</body></html>",
                         type: "text/html")
        case .failing: return .init(status: 502, body: "Bad Gateway", type: "text/plain")
        }
    }

    /// A SearXNG answer, as its JSON format gives it (fields it adds that the app does not read left out).
    static func page(_ query: String, answer: Bool) -> JSONValue {
        func result(_ url: JSONValue, _ title: String, _ content: String, _ date: JSONValue = .null) -> JSONValue {
            ["url": url, "title": .string(title), "content": .string(content), "publishedDate": date,
             "engine": "duckduckgo", "engines": ["duckduckgo", "google"], "score": 1, "category": "general",
             "template": "default.html"]
        }
        let long = String(repeating: "Un compte rendu très détaillé du match, minute par minute, ", count: 8)
        return [
            "query": .string(query),
            "number_of_results": 0,
            "results": [
                result("https://www.lequipe.fr/Football/match-direct/ligue-1/psg-lens", "PSG - Lens (2-1) : Paris s’impose",
                       "Le PSG a battu Lens 2 à 1\nau Parc des Princes...", "2026-10-14T21:00:00"),
                result("ftp://archives.example.org/psg", "Archives", "Un serveur de fichiers."),
                result(.null, "Sans adresse", "Un résultat sans adresse."),
                result("https://rmcsport.bfmtv.com/football/psg-lens", "Le résumé de PSG-Lens", long, "2026-10-15"),
                result("https://www.psg.fr/calendrier", "Calendrier & résultats - PSG.FR", "Tous les matchs du club."),
                result("https://fr.wikipedia.org/wiki/Paris_Saint-Germain", "Paris Saint-Germain — Wikipédia",
                       "Club de football fondé en 1970."),
                result("https://www.flashscore.fr/equipe/psg", "PSG : résultats en direct", "Résultats et calendrier."),
                result("https://www.ouest-france.fr/sport/psg", "Le PSG enchaîne", "Une sixième victoire de suite."),
            ],
            "answers": answer ? [["url": "https://fr.wikipedia.org/wiki/Paris_Saint-Germain", "engine": "duckduckgo",
                                  "answer": "Le Paris Saint-Germain est un club de football. More at Wikipedia (FR)"]] : [],
            "corrections": [],
            "infoboxes": [["infobox": "Paris Saint-Germain", "id": "https://fr.wikipedia.org/wiki/Paris_Saint-Germain",
                           "content": "Le Paris Saint-Germain Football Club est un club de football français.",
                           "urls": [["title": "Wikipedia", "url": "https://fr.wikipedia.org/wiki/Paris_Saint-Germain"]],
                           "engine": "wikidata", "attributes": []]],
            "suggestions": ["psg lens"],
            "unresponsive_engines": [["brave", "too many requests"]],
        ]
    }
}
