import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif

// Searching the internet: a few keywords the model wrote go to a search service, and the first results come back
// as short texts for the model to sum up, naming the site. Only those keywords leave the Mac: never the
// conversation, never the voice.

/// A search result, as the model reads it.
public struct WebResult: Sendable, Codable, Equatable {
    public var title: String
    /// The host without "www.": the site the model names ("lequipe.fr").
    public var site: String
    public var url: URL
    /// What the search shows of the page, at most `SearXNGProvider.snippetLimit` characters.
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
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// What a search found.
public struct WebSearchResults: Sendable, Codable, Equatable {
    /// A direct answer or a card (an infobox, often Wikipedia's), when the search service gives one.
    public var answer: WebResult?
    /// The first results, at most `SearXNGProvider.resultLimit`.
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
    /// 401: the server refuses the user name or the password.
    case unauthorized
    /// 403: the server does not accept programs (SearXNG's JSON format is off).
    case forbidden
    /// 429: the server takes the app for a robot (SearXNG's limiter).
    case tooManyRequests
    /// No answer in time, or no connection to it.
    case unreachable
    /// An answer that is not a search's: another HTTP status, or a page that is not SearXNG's JSON (status 200).
    case unexpected(status: Int)
}

/// A search service. One for now: the user's own SearXNG (`SearXNGProvider`).
public protocol WebSearchProvider: Sendable {
    /// The first results for a few keywords, in the conversation's language.
    func search(_ query: String, language: SpeechLanguage) async throws -> WebSearchResults
}

/// Searches the user's own SearXNG (its search API: https://docs.searxng.org/dev/search_api.html), as an app that
/// says its name, never as a browser. `POST <address>/search`, so that the query stays out of the addresses its
/// server may log; no cookies, no cache.
///
/// That SearXNG has to accept the JSON format (off by default: it answers 403 otherwise), and is better protected by
/// a password in front of it (HTTP Basic Auth) than by its own limiter, which takes any program for a robot (429).
public final class SearXNGProvider: WebSearchProvider {
    /// How many results the model reads, and how much of each.
    public static let resultLimit = 5
    public static let snippetLimit = 300
    /// The longest a search may take before Maé says she cannot reach the server.
    public static let defaultTimeout: TimeInterval = 5

    public let address: URL
    /// "Basic …", or nil without a user name and a password. Never logged.
    private let authorization: String?
    private let userAgent: String
    private let session: URLSession

    /// `address`: the SearXNG's, e.g. https://search.example.org (its search page, …/search, works too).
    /// `username` and `password`: for a password protection in front of it; none when both are empty.
    public init(address: URL, username: String = "", password: String = "", timeout: TimeInterval = defaultTimeout,
                userAgent: String = AppIdentity.userAgent)
    {
        self.address = address
        let credentials = username + ":" + password
        authorization = username.isEmpty && password.isEmpty ? nil : "Basic " + Data(credentials.utf8).base64EncodedString()
        self.userAgent = userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
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
        request.httpBody = Self.form([("q", query), ("format", "json"), ("language", language.rawValue),
                                      ("safesearch", "1"), ("categories", "general")])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw WebSearchError.unreachable
        }
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw WebSearchError.unexpected(status: 0) }
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
        let results = Array(items.compactMap(result).prefix(resultLimit))
        let total = body["number_of_results"]?.integer ?? 0
        return WebSearchResults(answer: answer(body), results: results, found: max(total, items.count))
    }

    private static func result(_ item: JSONValue) -> WebResult? {
        guard case .object(let fields) = item, let link = webAddress(fields["url"]), let site = WebResult.site(of: link)
        else { return nil }
        let title = clean(fields["title"]?.text)
        let snippet = clean(fields["content"]?.text)
        guard !title.isEmpty || !snippet.isEmpty else { return nil }
        return WebResult(title: title, site: site, url: link, snippet: shortened(snippet),
                         published: date(fields["publishedDate"]?.text ?? fields["pubdate"]?.text))
    }

    /// The first direct answer that names its page ("La tour Eiffel est une tour de 330 m…"), or else the first card.
    private static func answer(_ body: [String: JSONValue]) -> WebResult? {
        if let answers = body["answers"]?.array {
            for case .object(let fields) in answers {
                // DuckDuckGo's answers end with where they come from: "… More at Wikipedia (FR)".
                let text = clean(fields["answer"]?.text)
                    .replacingOccurrences(of: #"\s*More at [^.]*$"#, with: "", options: .regularExpression)
                guard !text.isEmpty, let link = webAddress(fields["url"]), let site = WebResult.site(of: link) else { continue }
                return WebResult(title: "", site: site, url: link, snippet: shortened(text))
            }
        }
        if let boxes = body["infoboxes"]?.array {
            for case .object(let fields) in boxes {
                let text = clean(fields["content"]?.text)
                let links = (fields["urls"]?.array ?? []).map { $0["url"] }
                guard !text.isEmpty, let link = ([fields["url"], fields["id"]] + links).lazy.compactMap(webAddress).first,
                      let site = WebResult.site(of: link)
                else { continue }
                return WebResult(title: clean(fields["infobox"]?.text), site: site, url: link, snippet: shortened(text))
            }
        }
        return nil
    }

    private static func webAddress(_ value: JSONValue?) -> URL? {
        guard let text = value?.text, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil
        else { return nil }
        return url
    }

    /// One line: no line breaks, single spaces, "..." as "…".
    static func clean(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "...", with: "…")
            .trimmingCharacters(in: .whitespaces)
    }

    /// At most `snippetLimit` characters, cut between two words.
    static func shortened(_ text: String) -> String {
        guard text.count > snippetLimit else { return text }
        let cut = text.prefix(snippetLimit - 1)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-…")) + "…"
    }

    /// SearXNG's dates: ISO 8601, with or without a time zone (then UTC), or the day alone.
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

    /// An HTML form's body: every byte but letters, digits and "-._~" percent-encoded.
    static func form(_ fields: [(String, String)]) -> Data {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: plain) ?? "" }
        return Data(fields.map { encoded($0.0) + "=" + encoded($0.1) }.joined(separator: "&").utf8)
    }
}
