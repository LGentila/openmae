// voice-cli web-search — one search on a SearXNG, made as the app makes it, and what the app keeps of it.
//
//   voice-cli web-search --searxng https://search.example.org [--searxng-user name] [--language fr|en] keywords…
//
// The password of the protection in front of it, if any, in the SEARXNG_PASSWORD environment variable. Prints the
// results the model would read (JSON, the shape of a benchmark corpus's "recorded"), then, apart, how many there were
// and how long the search took.

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
