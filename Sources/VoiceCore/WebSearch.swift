import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif

// Searching the internet: a few keywords the model wrote go to a search service, and the first results come back
// as short texts for the model to sum up, naming the site. Only those keywords leave the Mac: never the
// conversation, never the voice.

/// A search result, as the model reads it.
public struct WebResult: Sendable, Codable, Equatable {
    /// How much of a page's text the model reads.
    public static let snippetLimit = 300

    public var title: String
    /// The site the model names: the host without "www." ("lequipe.fr"), or the site's own name when the search service
    /// gives one ("L’Équipe").
    public var site: String
    public var url: URL
    /// What the search shows of the page, at most `snippetLimit` characters.
    public var snippet: String
    public var published: Date?

    public init(title: String, site: String, url: URL, snippet: String, published: Date? = nil) {
        self.title = title
        self.site = site
        self.url = url
        self.snippet = snippet
        self.published = published
    }

    /// "https://www.lequipe.fr/Football/" → "lequipe.fr".
    public static func site(of url: URL) -> String? {
        guard let host = url.host() else { return nil }
        return site(host: host)
    }

    /// "www.lequipe.fr" → "lequipe.fr".
    static func site(host: String) -> String? {
        var host = host.lowercased().trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}

/// What a search found.
public struct WebSearchResults: Sendable, Codable, Equatable {
    /// How many results the model reads.
    public static let limit = 5

    /// A direct answer or a card (an infobox, often Wikipedia's), when the search service gives one.
    public var answer: WebResult?
    /// The first results, at most `limit`.
    public var results: [WebResult]
    /// How many results the search found in all, before the first ones were kept.
    public var found: Int

    public init(answer: WebResult? = nil, results: [WebResult], found: Int? = nil) {
        self.answer = answer
        self.results = results
        self.found = found ?? results.count
    }

    public var isEmpty: Bool { answer == nil && results.isEmpty }
}

/// Why a search failed, as the settings' test explains it.
public enum WebSearchError: Error, Sendable, Codable, Equatable {
    /// The service refuses the user name and the password (SearXNG, 401), or the key (Brave Search).
    case unauthorized
    /// 403: the server does not accept programs (SearXNG's JSON format is off).
    case forbidden
    /// 429: the server takes the app for a robot (SearXNG's limiter), or the key reached its limit (Brave Search: per
    /// second, or its credit of the month).
    case tooManyRequests
    /// No answer in time, or no connection to it.
    case unreachable
    /// An answer that is not a search's: another HTTP status, or a page that is not the service's JSON (status 200).
    case unexpected(status: Int)
}

/// A search service: the user's own SearXNG (`SearXNGProvider`), or Brave Search with the user's own key
/// (`BraveSearchProvider`).
public protocol WebSearchProvider: Sendable {
    /// The first results for a few keywords, in the conversation's language.
    func search(_ query: String, language: SpeechLanguage) async throws -> WebSearchResults
}

extension WebSearchProvider {
    /// The longest a search may take before Maé says she cannot reach the service.
    public static var defaultTimeout: TimeInterval { 5 }
}

/// Searches the user's own SearXNG (its search API: https://docs.searxng.org/dev/search_api.html), as an app that
/// says its name, never as a browser. `POST <address>/search`, so that the query stays out of the addresses its
/// server may log; no cookies, no cache.
///
/// That SearXNG has to accept the JSON format (off by default: it answers 403 otherwise), and is better protected by
/// a password in front of it (HTTP Basic Auth) than by its own limiter, which takes any program for a robot (429).
public final class SearXNGProvider: WebSearchProvider {
    public let address: URL
    /// "Basic …", or nil without a user name and a password. Never logged.
    private let authorization: String?
    private let userAgent: String
    private let session: URLSession

    /// `address`: the SearXNG's, e.g. https://search.example.org (its search page, …/search, works too).
    /// `username` and `password`: for a password protection in front of it; none when both are empty.
    public init(address: URL, username: String = "", password: String = "",
                timeout: TimeInterval = SearXNGProvider.defaultTimeout, userAgent: String = AppIdentity.userAgent)
    {
        self.address = address
        let credentials = username + ":" + password
        authorization = username.isEmpty && password.isEmpty ? nil : "Basic " + Data(credentials.utf8).base64EncodedString()
        self.userAgent = userAgent
        session = .forWebSearch(timeout: timeout)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The address typed in the settings ("search.example.org", "https://search.example.org/"), nil when it cannot be
    /// one. Without a scheme: https, except on this Mac or the local network (http).
    public static func address(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var written = text
        if !text.contains("://") {
            let host = text.split(separator: "/").first?.split(separator: ":").first.map(String.init) ?? ""
            let local = ["localhost", "127.0.0.1", "[::1]"].contains(host) || host.hasSuffix(".local")
            written = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: written), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Where the searches go: the address's search page.
    var endpoint: URL {
        address.lastPathComponent == "search" ? address : address.appending(path: "search")
    }

    public func search(_ query: String, language: SpeechLanguage) async throws -> WebSearchResults {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(WebResultText.form([("q", query), ("format", "json"), ("language", language.rawValue),
                                                    ("safesearch", "1"), ("categories", "general")]).utf8)
        let (data, status) = try await session.searchResponse(for: request)
        switch status {
        case 200..<300: break
        case 401: throw WebSearchError.unauthorized
        case 403: throw WebSearchError.forbidden
        case 429: throw WebSearchError.tooManyRequests
        default: throw WebSearchError.unexpected(status: status)
        }
        return try Self.read(data, status: status)
    }

    /// What a search answered: its first results, its first direct answer or card. Throws when it is not SearXNG's
    /// JSON (a web page asking whether you are a robot, a sign-in page…).
    static func read(_ data: Data, status: Int = 200) throws -> WebSearchResults {
        guard case .object(let body)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              let items = body["results"]?.array
        else { throw WebSearchError.unexpected(status: status) }
        let results = Array(items.compactMap(result).prefix(WebSearchResults.limit))
        let total = body["number_of_results"]?.integer ?? 0
        return WebSearchResults(answer: answer(body), results: results, found: max(total, items.count))
    }

    private static func result(_ item: JSONValue) -> WebResult? {
        guard case .object(let fields) = item, let link = WebResultText.webAddress(fields["url"]),
              let site = WebResult.site(of: link)
        else { return nil }
        let title = WebResultText.clean(fields["title"]?.text)
        let snippet = WebResultText.clean(fields["content"]?.text)
        guard !title.isEmpty || !snippet.isEmpty else { return nil }
        return WebResult(title: title, site: site, url: link, snippet: WebResultText.shortened(snippet),
                         published: WebResultText.date(fields["publishedDate"]?.text ?? fields["pubdate"]?.text))
    }

    /// The first direct answer that names its page ("La tour Eiffel est une tour de 330 m…"), or else the first card.
    private static func answer(_ body: [String: JSONValue]) -> WebResult? {
        if let answers = body["answers"]?.array {
            for case .object(let fields) in answers {
                // DuckDuckGo's answers end with where they come from: "… More at Wikipedia (FR)".
                let text = WebResultText.clean(fields["answer"]?.text)
                    .replacingOccurrences(of: #"\s*More at [^.]*$"#, with: "", options: .regularExpression)
                guard !text.isEmpty, let link = WebResultText.webAddress(fields["url"]), let site = WebResult.site(of: link)
                else { continue }
                return WebResult(title: "", site: site, url: link, snippet: WebResultText.shortened(text))
            }
        }
        if let boxes = body["infoboxes"]?.array {
            for case .object(let fields) in boxes {
                let text = WebResultText.clean(fields["content"]?.text)
                let links = (fields["urls"]?.array ?? []).map { $0["url"] }
                guard !text.isEmpty,
                      let link = ([fields["url"], fields["id"]] + links).lazy.compactMap(WebResultText.webAddress).first,
                      let site = WebResult.site(of: link)
                else { continue }
                return WebResult(title: WebResultText.clean(fields["infobox"]?.text), site: site, url: link,
                                 snippet: WebResultText.shortened(text))
            }
        }
        return nil
    }
}

/// Searches Brave Search, which has its own index (neither Google's nor Bing's), through its API and with the user's own
/// key (API reference: https://api-dashboard.search.brave.com/api-reference/web/search/get). `GET
/// …/res/v1/web/search`, the key in the `X-Subscription-Token` header; no cookies.
///
/// Brave's terms forbid keeping its results without a plan with storage rights: nothing is cached, and they live only
/// in the conversation in progress.
public final class BraveSearchProvider: WebSearchProvider {
    public static let defaultEndpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    /// The countries the API can favour (`country`); from anywhere else, the searches are not tied to one ("ALL").
    static let countries: Set<String> = [
        "AR", "AU", "AT", "BE", "BR", "CA", "CL", "DK", "FI", "FR", "DE", "GR", "HK", "IN", "ID", "IT", "JP", "KR", "MY",
        "MX", "NL", "NZ", "NO", "CN", "PL", "PT", "PH", "RU", "SA", "ZA", "ES", "SE", "CH", "TW", "TR", "GB", "US",
    ]
    /// The API's interface languages (`ui_lang`) for French and English; elsewhere, those of France and the United States.
    static let interfaceLanguages: Set<String> = [
        "fr-BE", "fr-CA", "fr-CH", "fr-FR",
        "en-AU", "en-CA", "en-GB", "en-ID", "en-IN", "en-MY", "en-NZ", "en-PH", "en-US", "en-ZA",
    ]

    /// The user's key. Never logged.
    private let key: String
    private let endpoint: URL
    /// The Mac's region ("FR"), nil when it has none.
    private let region: String?
    private let userAgent: String
    private let session: URLSession

    /// `region`: the country whose results come first, the Mac's own by default.
    public init(key: String, region: String? = Locale.current.region?.identifier,
                endpoint: URL = BraveSearchProvider.defaultEndpoint, timeout: TimeInterval = BraveSearchProvider.defaultTimeout,
                userAgent: String = AppIdentity.userAgent)
    {
        self.key = key
        self.region = region?.uppercased()
        self.endpoint = endpoint
        self.userAgent = userAgent
        session = .forWebSearch(timeout: timeout)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func search(_ query: String, language: SpeechLanguage) async throws -> WebSearchResults {
        var request = URLRequest(url: url(query, language: language))
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, status) = try await session.searchResponse(for: request)
        switch status {
        case 200..<300: return try Self.read(data, status: status)
        // Brave answers a wrong key with a 422 ("SUBSCRIPTION_TOKEN_INVALID"), as it answers any request it cannot take.
        case 422 where Self.errorCode(data) == "SUBSCRIPTION_TOKEN_INVALID": throw WebSearchError.unauthorized
        case 401, 403: throw WebSearchError.unauthorized
        case 429: throw WebSearchError.tooManyRequests
        default: throw WebSearchError.unexpected(status: status)
        }
    }

    /// The search's address: the keywords; five results; the Mac's country first; pages in the conversation's language;
    /// moderate safe search (Brave's default, as with SearXNG); snippets without highlighting.
    func url(_ query: String, language: SpeechLanguage) -> URL {
        let country = region.flatMap { Self.countries.contains($0) ? $0 : nil } ?? "ALL"
        let regional = language.rawValue + "-" + (region ?? "")
        let interface = Self.interfaceLanguages.contains(regional) ? regional : language == .french ? "fr-FR" : "en-US"
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = WebResultText.form([
            ("q", query), ("count", String(WebSearchResults.limit)), ("country", country),
            ("search_lang", language.rawValue), ("ui_lang", interface), ("safesearch", "moderate"),
            ("text_decorations", "false"),
        ])
        return components.url!
    }

    /// What a search answered: its first web results. A search that found nothing has no `web` part. Throws when it is
    /// not Brave's JSON.
    static func read(_ data: Data, status: Int = 200) throws -> WebSearchResults {
        guard case .object(let body)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              body["type"]?.text == "search" || body["web"]?["results"]?.array != nil
        else { throw WebSearchError.unexpected(status: status) }
        let items = body["web"]?["results"]?.array ?? []
        return WebSearchResults(results: Array(items.compactMap(result).prefix(WebSearchResults.limit)), found: items.count)
    }

    /// A web result: its title, its address, its description (the snippet), the site's name and the page's date when
    /// Brave gives them. Highlighting and entities ("&#x27;") are taken out, whatever the request asked.
    private static func result(_ item: JSONValue) -> WebResult? {
        guard case .object(let fields) = item, let link = WebResultText.webAddress(fields["url"]) else { return nil }
        let name = WebResultText.clean(WebResultText.plain(fields["profile"]?["name"]?.text))
        let host = fields["meta_url"]?["hostname"]?.text.flatMap(WebResult.site(host:))
        guard let site = name.isEmpty ? (host ?? WebResult.site(of: link)) : name else { return nil }
        let title = WebResultText.clean(WebResultText.plain(fields["title"]?.text))
        let snippet = WebResultText.clean(WebResultText.plain(fields["description"]?.text))
        guard !title.isEmpty || !snippet.isEmpty else { return nil }
        let published = WebResultText.date(fields["page_age"]?.text) ?? day(fields["age"]?.text)
        return WebResult(title: title, site: site, url: link, snippet: WebResultText.shortened(snippet), published: published)
    }

    /// `age`, when it is a day ("2026-10-14", "October 14, 2026") rather than a time ago ("2 days ago").
    static func day(_ text: String?) -> Date? {
        if let date = WebResultText.date(text) { return date }
        guard let text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["MMMM d, yyyy", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The code of an error Brave explains, as its API writes it: {"error": {"code": "…", "detail": "…", "status": 422}}.
    static func errorCode(_ data: Data) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?["code"]?.text
    }
}

/// Tidying up what a search service gives, for the model to read.
enum WebResultText {
    /// One line: "..." as "…", none of the model's own marks (`ModelMarkers`: in a title or a snippet, they could pass for
    /// the end of the results and the start of something else; `plain` has already written the entities as characters),
    /// no line breaks, single spaces.
    static func clean(_ text: String?) -> String {
        ModelMarkers.strip((text ?? "").replacingOccurrences(of: "...", with: "…"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// At most `WebResult.snippetLimit` characters, cut between two words.
    static func shortened(_ text: String) -> String {
        guard text.count > WebResult.snippetLimit else { return text }
        let cut = text.prefix(WebResult.snippetLimit - 1)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-…")) + "…"
    }

    /// The text of a little HTML ("<strong>PSG</strong> &amp; Lens"): its tags out, its entities written as the
    /// characters they stand for. A "<" that does not open a tag ("moins de < 5 €") stays.
    static func plain(_ html: String?) -> String {
        guard var text = html else { return "" }
        if text.contains("<") {
            text = text.replacingOccurrences(of: #"<(br|p|div|li)\b[^<>]*>"#, with: " ",
                                             options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"</?[A-Za-z][A-Za-z0-9]*(\s[^<>]*)?/?>"#, with: "", options: .regularExpression)
        }
        guard text.contains("&") else { return text }
        var plain = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            plain += rest[..<ampersand]
            let entity = rest[rest.index(after: ampersand)...].prefix(10)
            if let end = entity.firstIndex(of: ";"), let character = character(of: entity[..<end]) {
                plain.append(character)
                rest = rest[rest.index(after: end)...]
            } else {
                plain.append("&")
                rest = rest[rest.index(after: ampersand)...]
            }
        }
        return plain + rest
    }

    /// "amp" → "&", "#39" → "'", "#x27" → "'"; nil for a name it does not know. A control character becomes a space.
    private static func character(of entity: Substring) -> Character? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap(Unicode.Scalar.init).map { $0.value < 32 ? " " : Character($0) }
        }
        return namedEntities[String(entity)]
    }

    private static let namedEntities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "hellip": "…", "laquo": "«",
        "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "ndash": "–", "mdash": "—", "euro": "€",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "agrave": "à", "acirc": "â", "ccedil": "ç",
        "icirc": "î", "iuml": "ï", "ocirc": "ô", "ugrave": "ù", "ucirc": "û", "oelig": "œ", "Eacute": "É", "deg": "°",
    ]

    /// A web page's address (http or https), nil for anything else.
    static func webAddress(_ value: JSONValue?) -> URL? {
        guard let text = value?.text, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil
        else { return nil }
        return url
    }

    /// The services' dates: ISO 8601, with or without a time zone (then UTC), or the day alone.
    static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.count >= 10 else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    /// Fields as an HTML form writes them (a POST body, or the query of an address): every byte but letters, digits and
    /// "-._~" percent-encoded, so that a "+" or a "&" of the keywords stays one.
    static func form(_ fields: [(String, String)]) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: plain) ?? "" }
        return fields.map { encoded($0.0) + "=" + encoded($0.1) }.joined(separator: "&")
    }
}

extension URLSession {
    /// A session for the searches: it keeps nothing (no cookies, no cache on disk or in memory) and gives up after
    /// `timeout` seconds.
    static func forWebSearch(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// A search service's answer and its HTTP status. No answer in time, or no connection: `.unreachable`.
    func searchResponse(for request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw WebSearchError.unreachable
        }
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw WebSearchError.unexpected(status: 0) }
        return (data, status)
    }
}
