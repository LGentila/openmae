import Foundation

@testable import VoiceCore

/// A pretend Brave Search API for the provider's tests: `GET /res/v1/web/search` on a local port, nothing else.
///
/// Its answers are made by hand, in the API's format (https://api-dashboard.search.brave.com/api-reference/web/search/get):
/// Brave's terms forbid keeping its real results. What it answers depends on its `mode`, and on the key: Brave checks
/// it first, and refuses another one than its own (422, "SUBSCRIPTION_TOKEN_INVALID").
final class FakeBrave: @unchecked Sendable {
    enum Mode: Sendable {
        /// Eight web results (two the app cannot use), with highlighting and entities in their texts.
        case results
        /// A search that found nothing: no web part at all.
        case nothing
        /// A web part without results.
        case noResults
        /// The key reached its limit: 429.
        case limit
        /// Answers after two seconds, longer than the tests' time limit.
        case slow
        /// An empty JSON object.
        case emptyJSON
        /// JSON, but not a search's.
        case otherJSON
        /// A web page instead of JSON (a hotel's Wi-Fi sign-in page, say).
        case webPage
        /// A request the API cannot take: 422, "VALIDATION".
        case invalid
        /// A server error: 502.
        case failing
    }

    typealias Request = LocalHTTPServer.Request

    /// The key it accepts.
    let key: String
    private let server = LocalHTTPServer()
    private let lock = NSLock()
    private var currentMode = Mode.results

    init(key: String = "BSA-pretend-key-of-the-tests") {
        self.key = key
    }

    var endpoint: URL { URL(string: "http://127.0.0.1:\(server.port)/res/v1/web/search")! }
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
        guard request.method == "GET", request.path == "/res/v1/web/search" else {
            return .json(Self.error("RESOURCE_NOT_FOUND", "Resource not found.", status: 404), status: 404)
        }
        guard let token = request.headers["x-subscription-token"] else {
            return .json(Self.error("VALIDATION", "Unable to validate request parameter(s)", status: 422), status: 422)
        }
        guard token == key else {
            return .json(Self.error("SUBSCRIPTION_TOKEN_INVALID", "The provided subscription token is invalid.", status: 422,
                                    meta: ["component": "authentication"]), status: 422)
        }
        let query = request.query["q"] ?? ""
        switch mode {
        case .results: return .json(Self.page(query))
        case .nothing: return .json(["type": "search", "query": Self.query(query)])
        case .noResults:
            return .json(["type": "search", "query": Self.query(query),
                          "web": ["type": "search", "results": [], "family_friendly": true]])
        case .limit:
            return .json(Self.error("RATE_LIMITED", "Request rate limit exceeded for plan.", status: 429,
                                    meta: ["component": "rate_limiter"]), status: 429)
        case .slow:
            var response = LocalHTTPServer.Response.json(Self.page(query))
            response.delay = 2
            return response
        case .emptyJSON: return .json([:])
        case .otherJSON: return .json(["status": "ok", "version": "1"])
        case .webPage:
            return .init(status: 200, body: "<!DOCTYPE html><html><body>Connecte-toi au Wi-Fi de l’hôtel</body></html>",
                         type: "text/html")
        case .invalid:
            return .json(Self.error("VALIDATION", "Unable to validate request parameter(s)", status: 422), status: 422)
        case .failing: return .init(status: 502, body: "Bad Gateway", type: "text/plain")
        }
    }

    /// An error as the API explains it.
    static func error(_ code: String, _ detail: String, status: Int, meta: JSONValue = [:]) -> JSONValue {
        ["type": "ErrorResponse", "error": ["code": .string(code), "detail": .string(detail), "meta": meta, "status": .int(status)]]
    }

    static func query(_ text: String) -> JSONValue {
        ["original": .string(text), "show_strict_warning": false, "is_navigational": false, "is_news_breaking": false,
         "spellcheck_off": true, "country": "fr", "bad_results": false, "should_fallback": false,
         "more_results_available": false]
    }

    /// A search's answer, its web part only (the API adds others the app does not read: news, videos…).
    static func page(_ text: String) -> JSONValue {
        func result(_ url: JSONValue, _ title: String, _ description: String, name: String? = nil, host: String? = nil,
                    pageAge: String? = nil, age: String? = nil) -> JSONValue
        {
            var fields: [String: JSONValue] = [
                "type": "search_result", "subtype": "generic", "title": .string(title), "url": url,
                "description": .string(description), "is_source_local": false, "is_source_both": false,
                "family_friendly": true, "language": "fr",
            ]
            if let name { fields["profile"] = ["name": .string(name), "url": url, "long_name": .string(host ?? ""),
                                               "img": "https://imgs.example.org/profile.png"] }
            if let host { fields["meta_url"] = ["scheme": "https", "netloc": .string(host), "hostname": .string(host),
                                                "favicon": "https://imgs.example.org/favicon.png", "path": "› sport"] }
            if let pageAge { fields["page_age"] = .string(pageAge) }
            if let age { fields["age"] = .string(age) }
            return .object(fields)
        }
        let long = String(repeating: "Un compte rendu très détaillé du match, minute par minute, ", count: 8)
        return [
            "type": "search",
            "query": query(text),
            "mixed": ["type": "mixed", "main": [["type": "web", "index": 0, "all": false]], "top": [], "side": []],
            "web": [
                "type": "search",
                "family_friendly": true,
                "results": [
                    result("https://www.lequipe.fr/Football/match-direct/ligue-1/psg-lens",
                           "PSG - Lens (2-1) : <strong>Paris</strong> s&#x27;impose",
                           "Le <strong>PSG</strong> a battu Lens 2 à 1\nau Parc des Princes &amp; reste en tête...",
                           name: "L’Équipe", host: "www.lequipe.fr", pageAge: "2026-10-14T21:00:00", age: "14 octobre 2026"),
                    result("ftp://archives.example.org/psg", "Archives", "Un serveur de fichiers."),
                    result(.null, "Sans adresse", "Un résultat sans adresse."),
                    result("https://rmcsport.bfmtv.com/football/psg-lens", "Le résumé de PSG-Lens", long,
                           name: "RMC Sport", host: "rmcsport.bfmtv.com", age: "October 15, 2026"),
                    result("https://www.psg.fr/calendrier", "Calendrier &amp; résultats - PSG.FR",
                           "Tous les matchs du club. Moins de &lt; 5 € la place ? Non : &quot;complet&quot;.",
                           host: "www.psg.fr", age: "2 days ago"),
                    result("https://fr.wikipedia.org/wiki/Paris_Saint-Germain", "Paris Saint-Germain — Wikipédia",
                           "Club de football fondé en 1970.", name: "Wikipédia", host: "fr.wikipedia.org",
                           pageAge: "2026-09-30"),
                    result("https://www.flashscore.fr/equipe/psg", "PSG : résultats en direct", "Résultats et calendrier."),
                    result("https://www.ouest-france.fr/sport/psg", "Le PSG enchaîne", "Une sixième victoire de suite.",
                           name: "Ouest-France", host: "www.ouest-france.fr"),
                ],
            ],
        ]
    }
}
