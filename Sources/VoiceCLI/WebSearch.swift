// voice-cli web-search — one search on a SearXNG, made as the app makes it, and what the app keeps of it.
//
//   voice-cli web-search --searxng https://search.example.org [--searxng-user name] [--language fr|en] keywords…
//
// The password of the protection in front of it, if any, in the SEARXNG_PASSWORD environment variable. Prints the
// results the model would read (JSON, the shape of a benchmark corpus's "recorded"), then, apart, how many there were
// and how long the search took.
//
// voice-cli read-page — one result's page, read as the app reads it for the model.
//
//   voice-cli read-page https://www.example.org/page [--words "prix action Apple"] [--language fr|en] [--repeats 1]
//
// Prints the page as the model would read it with these words looked for (JSON, the shape of a benchmark corpus's
// "pages"), then, apart, how long the page took to come (each time, with --repeats), to be read, and how much of its
// text there was.

import Foundation
import VoiceCore

func runWebSearch(_ arguments: [String]) async throws {
    var address: String?
    var user = ""
    var language = SpeechLanguage.french
    var words: [String] = []
    var it = arguments.dropFirst(2).makeIterator()
    while let argument = it.next() {
        switch argument {
        case "--searxng": address = it.next()
        case "--searxng-user": user = it.next() ?? ""
        case "--language": language = SpeechLanguage(rawValue: it.next() ?? "") ?? .french
        default: words.append(argument)
        }
    }
    guard let url = address.flatMap(SearXNGProvider.address) else {
        throw CLIError("--searxng: expected an address like http://127.0.0.1:8888")
    }
    guard !words.isEmpty else { throw CLIError("expected the keywords to search for") }
    let provider = SearXNGProvider(address: url, username: user,
                                   password: ProcessInfo.processInfo.environment["SEARXNG_PASSWORD"] ?? "")
    let start = ContinuousClock.now
    let found = try await provider.search(words.joined(separator: " "), language: language)
    let elapsed = ContinuousClock.now - start
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(found), as: UTF8.self))
    let summary = "\(found.results.count) results kept of \(found.found)"
        + (found.answer == nil ? "" : ", and a direct answer") + ", in \(elapsed)\n"
    DebugLog.writeToStandardError(summary)
}

func runReadPage(_ arguments: [String]) async throws {
    var address: String?
    var words: [String] = []
    var language = SpeechLanguage.french
    var repeats = 1
    var it = arguments.dropFirst(2).makeIterator()
    while let argument = it.next() {
        switch argument {
        case "--words": words.append(it.next() ?? "")
        case "--language": language = SpeechLanguage(rawValue: it.next() ?? "") ?? .french
        case "--repeats": repeats = max(1, Int(it.next() ?? "") ?? 1)
        default: address = argument
        }
    }
    guard let address, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
        throw CLIError("expected a page's address, like https://www.example.org/page")
    }
    let reader = HTTPPageReader()
    var times: [String] = []
    var page: WebPage?
    for _ in 0..<repeats {
        let start = ContinuousClock.now
        do {
            page = try await reader.read(url, language: language)
            times.append("\(ContinuousClock.now - start)")
        } catch let error as WebPageError {
            times.append("\(ContinuousClock.now - start) (\(error))")
            print(#"{"error": "\#(BenchPages.name(of: error))"}"#)
        }
    }
    if let page {
        let context = ToolContext(now: Date(), language: language)
        let forModel = WebSearchCatalog.forModel(page, words: words, context: context)
        let text = BenchPages.field(forModel, "texte") ?? ""
        let recorded = BenchPages.Recorded(site: page.site, title: page.title, text: text, published: page.published)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(recorded), as: UTF8.self))
        let start = ContinuousClock.now
        _ = ReadablePage.excerpt(page.text, words: words)
        DebugLog.writeToStandardError("page: \(page.text.count) characters of text, \(text.count) "
            + "read by the model (cut in \(ContinuousClock.now - start))\n")
    }
    DebugLog.writeToStandardError("fetched and read in: \(times.joined(separator: ", "))\n")
}

/// The pages a benchmark corpus recorded (its "pages", by address), as the app gave them to the model, or why they could
/// not be read.
enum BenchPages {
    struct Recorded: Codable {
        var site: String?
        var title: String?
        /// The text the model read: the page's passages around the words looked for when it was recorded.
        var text: String?
        var published: Date?
        /// "refused", "consentWall", "notFound", "unreachable", "notReadable", "unexpected".
        var error: String?

        var page: WebPage? {
            guard error == nil, let text else { return nil }
            return WebPage(site: site ?? "", title: title ?? "", text: text, published: published)
        }

        var failure: WebPageError? { error.map(BenchPages.error(named:)) }
    }

    /// A text field of what the model reads ("texte", "erreur").
    static func field(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let fields) = value, case .string(let text)? = fields[key] else { return nil }
        return text
    }

    static func name(of error: WebPageError) -> String {
        switch error {
        case .refused: "refused"
        case .consentWall: "consentWall"
        case .notFound: "notFound"
        case .unreachable: "unreachable"
        case .notReadable: "notReadable"
        case .unexpected: "unexpected"
        }
    }

    static func error(named name: String) -> WebPageError {
        switch name {
        case "refused": .refused
        case "consentWall": .consentWall
        case "notFound": .notFound
        case "unreachable": .unreachable
        case "notReadable": .notReadable
        default: .unexpected(status: 0)
        }
    }
}
