import Foundation
import Network

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

    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var form: [String: String]
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fake-searxng")
    private var listener: NWListener?
    private var log: [Request] = []
    private var currentMode = Mode.results
    private(set) var port: UInt16 = 0
    /// "user:password" when it asks for one.
    let credentials: String?

    init(username: String? = nil, password: String? = nil) {
        credentials = password.map { (username ?? "") + ":" + $0 }
    }

    var address: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [Request] { lock.withLock { log } }
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: queue)
        for await port in ready.stream {
            self.port = port
            break
        }
    }

    func stop() {
        listener?.cancel()
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.log.append(request) }
                self.route(request, connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// A whole request (headers, and as many bytes of body as they announce), or nil while it is incomplete.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        var form: [String: String] = [:]
        for pair in String(decoding: body.prefix(length), as: UTF8.self).split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if field.count == 2 { form[field[0]] = field[1] }
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, form: form)
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ body: String, type: String = "application/json",
                         extraHeaders: String = "")
    {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(data.count)\r\n\(extraHeaders)Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(_ connection: NWConnection, json: JSONValue) {
        let data = (try? JSONEncoder().encode(json)) ?? Data()
        respond(connection, 200, String(decoding: data, as: UTF8.self))
    }

    private func route(_ request: Request, _ connection: NWConnection) {
        guard request.path.split(separator: "?").first == "/search" else {
            return respond(connection, 404, "<html><body>Not Found</body></html>", type: "text/html")
        }
        if let credentials {
            let expected = "Basic " + Data(credentials.utf8).base64EncodedString()
            guard request.headers["authorization"] == expected else {
                return respond(connection, 401, "401 Unauthorized", type: "text/plain",
                               extraHeaders: "WWW-Authenticate: Basic realm=\"searxng\"\r\n")
            }
        }
        let query = request.form["q"] ?? ""
        switch mode {
        case .results: respond(connection, json: Self.page(query, answer: true))
        case .cardOnly: respond(connection, json: Self.page(query, answer: false))
        case .empty:
            respond(connection, json: ["query": .string(query), "number_of_results": 0, "results": [], "answers": [],
                                       "corrections": [], "infoboxes": [], "suggestions": [], "unresponsive_engines": []])
        case .jsonOff: respond(connection, 403, "<html><body><h1>Forbidden</h1></body></html>", type: "text/html")
        case .limiter: respond(connection, 429, "Too Many Requests", type: "text/plain")
        case .slow:
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.respond(connection, json: Self.page(query, answer: true))
            }
        case .otherJSON: respond(connection, json: ["status": "ok", "version": "2026.10.16"])
        case .webPage:
            respond(connection, 200, "<!DOCTYPE html><html><body>Vérification que vous n'êtes pas un robot…</body></html>",
                    type: "text/html")
        case .failing: respond(connection, 502, "Bad Gateway", type: "text/plain")
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
