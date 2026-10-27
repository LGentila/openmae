// voice-cli conversation --web-results corpus.json — the web search offered in a spoken conversation, as in the app, its
// searches answered offline with what a benchmark corpus recorded ("recorded": the results of a search, by request).
//
// Each search gets the results recorded for the request whose words its keywords share the most (« prix bitcoin » →
// "Combien vaut le bitcoin aujourd'hui ?"), so that the model sums up results that answer the question it was asked: the
// recordings to say are then the corpus's requests. A search none of them shares a word with gets the first recorded.

import Foundation
import VoiceCore

struct RecordedSearches: WebSearchProvider {
    private let recorded: [(words: Set<String>, results: WebSearchResults)]

    init(corpus: URL) throws {
        struct Corpus: Decodable {
            var recorded: [String: WebSearchResults]?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode(Corpus.self, from: Data(contentsOf: corpus)).recorded ?? [:]
        guard !entries.isEmpty else { throw CLIError("\(corpus.lastPathComponent): no recorded searches") }
        recorded = entries.sorted { $0.key < $1.key }.map { (Self.words($0.key), $0.value) }
        print("web search: \(recorded.count) searches recorded in \(corpus.lastPathComponent), answered offline")
    }

    func search(_ query: String, language: SpeechLanguage) async throws -> WebSearchResults {
        let asked = Self.words(query)
        let best = recorded.max { $0.words.intersection(asked).count < $1.words.intersection(asked).count }
        return best.flatMap { $0.words.isDisjoint(with: asked) ? nil : $0.results } ?? recorded[0].results
    }

    /// The words of three letters or more, lowercased, without accents.
    private static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        return Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
    }
}
