// voice-cli story-bench — words the voice is given misspelled, as « constru-ée » for « construite » (heard in the app with
// Gemma 4 26B, in a story of the Eiffel Tower): does the model write them, or does something on the way to the voice?
//
// Text only. Each request of the corpus (Tests/Fixtures/stories-fr.json: requests for a story) is sent --repeats times
// (default 20), each time in a new conversation with the app's system prompt; with --actions, --agents (Claude Code),
// --web, --sources, --news and --memory (with an empty sheet), their parts of the prompt and their tools as in the app
// when they are on, and the date line (nothing is carried out: a call ends the answer). With --hold, the model is held
// that many seconds after each piece of the answer, as the pipeline holds it while the voice needs the GPU.
//
// The answer goes to the voice as in the app (`ReasoningFilter`, `SentenceChunker`, then `SpeakableText.clean` and
// `SpeakableText.forVoice` for each piece), and every token the model drew is kept, with the chance the model gave it and
// the tokens it found likeliest there (`MLXChatModel.watchTokens`). A hyphenated word that the system's French spell
// checker does not know (`NSSpellChecker`: « peut-être », « Champ-de-Mars » and « dix-neuf » are words, « constru-ée » is
// not), or a hyphen followed by a space between two letters, is a split word; every word the spell checker does not know
// is reported too (misspelled words such as « Aujourd'elle », and names it does not have). The report prints every answer
// as the voice is given it, each such word with the tokens the model drew for it, and per request the answers holding
// one, in what the model wrote and in what the voice is given. With --reread, each answer is also read again in one pass
// as a prompt is read (`MLXChatModel.rereadChances`), in the model's own type and in float32, and each such word's tokens
// show the chances the model gives them then.
//
// With --speed, the tokens are not watched (reading every token's chances slows the writing), and each answer's speed is
// measured instead, as the app has it write: the time from the request to its first word (`MLXChatModel.lastPrefill`: the
// request's new tokens read), its writing speed from its first token to its last (`MLXChatModel.lastWriting`), and the GPU
// memory peak meanwhile; the memory after loading is printed first. Run it with the GPU kept to itself, as any timing.
//
//   voice-cli story-bench [--tier tier] [--llm folder] [--corpus Tests/Fixtures/stories-fr.json] [--request "…"]…
//                         [--repeats 20] [--actions] [--agents] [--web] [--sources] [--news] [--memory] [--hold 1]
//                         [--reread | --speed] [--now 2026-10-15T18:42] [--min-p 0.05] [--bfloat16-prompts]
//                         [--out measurements]
//
// --request sends that request instead of the corpus's (several times for several). --min-p draws the tokens with that
// min-p instead of the app's; --bfloat16-prompts computes the requests' new tokens and the history in bfloat16, as the
// app did before (`MLXChatModel.computePromptsInFloat32`).

import AppKit
import Foundation
import VoiceCore
import VoiceEngineApple

private struct StoryCorpus: Decodable {
    var requests: [String]
}

/// A split word (or a word the spell checker does not know), and the tokens the model drew for it, from the one
/// before it; with --reread, the chances the model gives them when it reads the answer again in one pass, in its own
/// type and in float32 (`MLXChatModel.rereadChances`).
private struct SplitWord: Encodable {
    var word: String
    var tokens: [WatchedToken]
    var reread: [MLXChatModel.RereadChance]?
    var rereadFloat32: [MLXChatModel.RereadChance]?
}

private struct StoryAnswer: Encodable {
    var request: String
    var run: Int
    /// What the model wrote, as it wrote it.
    var written: String
    /// What the voice is given, piece by piece.
    var voice: [String]
    /// The split words in what the model wrote, and in what the voice is given.
    var splitWritten: [SplitWord]
    var splitVoice: [String]
    /// Every word of what the model wrote that the French spell checker does not know (the split words included):
    /// misspelled words, and names it does not have.
    var unknownWords: [SplitWord]
    /// The model wrote a tool call (then the answer ends: nothing is carried out).
    var call: String?
    var tokens: [WatchedToken]
    /// With --speed.
    var speed: StorySpeed?
}

/// How fast an answer was written (--speed).
private struct StorySpeed: Encodable {
    /// From the request to the answer's first word.
    var firstWordMs: Double
    /// The request's new tokens, read before the first token (`MLXChatModel.lastPrefill`), and the time it took.
    var readTokens: Int
    var readMs: Double
    /// The answer's tokens (its last, which ends it, included), and the time from the first to the last.
    var tokens: Int
    var writingMs: Double
    /// Tokens written per second after the first one.
    var tokensPerSecond: Double?
    /// The GPU memory peak during the request (GB, the weights included).
    var peakGB: Double
}

func runStoryBench(_ o: Options) async throws {
    let tier = try tierOption(o)
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/stories-fr.json")
    let requests = o.requests.isEmpty
        ? try JSONDecoder().decode(StoryCorpus.self, from: Data(contentsOf: corpusURL)).requests : o.requests
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? "2026-10-15T18:42", in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    guard o.llm != nil || store.isComplete([pack]) else {
        throw CLIError("\(pack.displayName) is not on this Mac: run “voice-cli download --tier \(tier.rawValue)” first")
    }
    if o.speed, o.reread { throw CLIError("--reread needs the tokens watched, which --speed leaves out") }
    let model = try await MLXChatModel.load(directory: folder)
    await model.watchTokens(!o.speed)
    await model.computePromptsInFloat32(!o.bfloat16Prompts)
    if let minP = o.minP { await model.sampleWithMinP(minP) }
    let sampling = await model.sampling

    // As the app puts the system prompt together (`VoicePipeline.promptAddenda`), its tools in its order (the actions,
    // Claude Code, the web search, the built-in sources, the news, the memory last): with tools, the actions' part, or
    // without them what the date line is; then the tools' parts; the actions' example exchanges.
    var conversation = Conversation()
    let tools: [ToolSpec] = (o.actions ? ActionCatalog.calendarTools(on: tier) + [ActionCatalog.timer] : [])
        + (o.agents ? AgentCatalog.tools(agents: [(ClaudeCode.displayName, AgentCatalog.claudeCodeDescription)],
                                         folders: []) : [])
        + (o.web ? [WebSearchCatalog.search] : []) + (o.sources ? BuiltInSources.tools : [])
        + (o.news ? [NewsCatalog.read] : []) + (o.memory ? [MemoryCatalog.tool(journal: true)] : [])
    await model.useTools(tools)
    var dateLine: String?
    if !tools.isEmpty {
        let actionsPart = o.actions
            ? ActionCatalog.promptAddendum(exampleCall: await model.toolCallText(ActionCatalog.example.call))
            : ActionCatalog.dateLineRule
        let agentsPart = o.actions ? AgentCatalog.promptAddendum
            : AgentCatalog.promptAddendumWithoutActions(exampleCall: await model.toolCallText(AgentCatalog.example.call))
        conversation.systemAddenda = [actionsPart] + (o.agents ? [agentsPart] : [])
            + (o.web ? [WebSearchCatalog.promptAddendum] : [])
            + (o.sources ? [WeatherCatalog.promptAddendum, QuoteCatalog.promptAddendum, TravelTimeCatalog.promptAddendum] : [])
            + (o.news ? [NewsCatalog.promptAddendum] : [])
            + (o.memory ? [MemoryCatalog.promptAddendum(sheet: [], journal: true)] : [])
        if o.actions, ActionCatalog.showsExamples(on: tier) {
            conversation.examples = ActionCatalog.examples(now: now, timeZone: timeZone)
        }
        dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
    }
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue))"
          + (o.actions ? " · with the actions" : "") + (o.agents ? " · with Claude Code" : "")
          + (o.web ? " · with the web search" : "") + (o.sources ? " · with the built-in sources" : "")
          + (o.news ? " · with the news" : "") + (o.memory ? " · with the memory (empty)" : "")
          + (o.hold.map { " · generation held \($0) s after each piece" } ?? "")
          + String(format: " · sampling: temperature %.2f, top-p %.2f, min-p %.2f", sampling.temperature, sampling.topP,
                   sampling.minP)
          + (o.bfloat16Prompts ? " · requests and history computed in bfloat16 (--bfloat16-prompts)" : "")
          + (o.speed ? " · speed measured, tokens not watched" : ""))
    if o.speed {
        print(String(format: "memory after loading: %.2f GB (MLX: %.2f GB in use)", ProcessMemory.footprintGB,
                     MLXChatModel.activeMemoryGB))
    }

    let repeats = max(o.repeats ?? 20, 1)
    var answers: [StoryAnswer] = []
    for request in requests {
        for run in 1...repeats {
            try await model.prefillBeginning(conversation.beginning)  // a new conversation
            let message = conversation.nextUserMessage(request, language: .french, dateLine: dateLine)
            var written = ""
            var call: String?
            var filter = ReasoningFilter()
            var chunker = SentenceChunker()
            var pieces: [SentenceChunker.Piece] = []
            let clock = ContinuousClock()
            let requested = clock.now
            var firstWord: Duration?
            for try await output in model.reply(to: conversation.messages(adding: message)) {
                switch output {
                case .text(let piece):
                    if firstWord == nil, piece.contains(where: { !$0.isWhitespace }) { firstWord = clock.now - requested }
                    written += piece
                    let new = chunker.pieces(adding: filter.push(piece))
                    pieces += new
                    // As the pipeline holds the model while the voice needs the GPU (`YieldsToVoice`).
                    if let hold = o.hold, !new.isEmpty {
                        model.holdGeneration(true)
                        Task {
                            try? await Task.sleep(for: .seconds(hold))
                            model.holdGeneration(false)
                        }
                    }
                case .toolCall(let made): call = made.name
                case .unreadableToolCall(let raw): call = "unreadable: \(raw)"
                default: break
                }
            }
            pieces += chunker.pieces(adding: filter.flush())
            pieces += chunker.remainingPieces()
            // As `VoicePipeline.deliver` gives each piece to the voice.
            let voice = pieces.map { SpeakableText.clean($0.text) }.filter { !$0.isEmpty }
                .map { SpeakableText.forVoice($0, language: .french) }
            let tokens = await model.lastTokens
            var speed: StorySpeed?
            if o.speed {
                let read = await model.lastPrefill
                let writing = await model.lastWriting
                speed = StorySpeed(firstWordMs: firstWord.map(milliseconds) ?? 0, readTokens: read.computed,
                                   readMs: read.ms, tokens: writing.tokens, writingMs: writing.ms,
                                   tokensPerSecond: writing.tokens > 1 && writing.ms > 0
                                       ? Double(writing.tokens - 1) / (writing.ms / 1000) : nil,
                                   peakGB: await model.lastRequestPeakGB)
            }
            var reread: [MLXChatModel.RereadChance]?
            var rereadFloat32: [MLXChatModel.RereadChance]?
            if o.reread {
                let request = conversation.messages(adding: message)
                reread = try await model.rereadChances(request, answer: tokens.map(\.id), inFloat32: false)
                rereadFloat32 = try await model.rereadChances(request, answer: tokens.map(\.id), inFloat32: true)
            }
            func word(_ word: String, at range: NSRange) -> SplitWord {
                let indices = drawn(covering: range, in: tokens)
                return SplitWord(word: word, tokens: indices.map { tokens[$0] },
                                 reread: reread.map { all in indices.map { all[$0] } },
                                 rereadFloat32: rereadFloat32.map { all in indices.map { all[$0] } })
            }
            let splitWritten = await splitWords(in: written).map { word($0.word, at: $0.range) }
            let unknownWords = await wordsUnknown(in: written).map { word($0.word, at: $0.range) }
            let splitVoice = await voice.asyncFlatMap { await splitWords(in: $0).map(\.word) }
            let answer = StoryAnswer(request: request, run: run, written: written, voice: voice, splitWritten: splitWritten,
                                     splitVoice: splitVoice, unknownWords: unknownWords, call: call, tokens: tokens,
                                     speed: speed)
            answers.append(answer)
            print("■ \(request) — \(run)/\(repeats)")
            print("    🔊 \(voice.joined(separator: " | "))" + (call.map { "  [call: \($0)]" } ?? ""))
            if let speed {
                print(String(format: "    ⏱ first word %.0f ms (%d new tokens read in %.0f ms) · %d tokens in %.0f ms: %@ "
                             + "tokens/s · GPU peak %.2f GB", speed.firstWordMs, speed.readTokens, speed.readMs,
                             speed.tokens, speed.writingMs,
                             speed.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "—", speed.peakGB))
            }
            for split in splitWritten {
                print("    ⚠️ the model wrote « \(split.word) »: " + describe(split))
            }
            for unknown in unknownWords where !splitWritten.contains(where: { $0.word == unknown.word }) {
                print("    ❓ unknown word « \(unknown.word) »: " + describe(unknown))
            }
            for word in splitVoice where !splitWritten.contains(where: { $0.word == word }) {
                print("    ⚠️ the voice is given « \(word) », which the model did not write so")
            }
        }
    }
    summarizeStories(answers, requests: requests)
    if o.speed { summarizeSpeed(answers.compactMap(\.speed)) }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("story-bench-\(tier.rawValue)-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(answers).write(to: url)
    print("report: \(url.path)")
}

/// The tokens of a word as the report prints them, with the chances read again (--reread): `"-" 30 % (likeliest: …)
/// · read again 0.1 % ("ite" 99 %), in float32 0.1 % ("ite" 99 %)`.
private func describe(_ word: SplitWord) -> String {
    word.tokens.enumerated().map { index, token in
        var text = describe(token)
        if let reread = word.reread?[index], let float32 = word.rereadFloat32?[index] {
            text += " [read again: \(percent(reread.chance))"
                + (reread.likeliest == token.token ? "" : " (\(reread.likeliest.debugDescription) \(percent(reread.likeliestChance)))")
                + ", in float32: \(percent(float32.chance))"
                + (float32.likeliest == token.token ? "" : " (\(float32.likeliest.debugDescription) \(percent(float32.likeliestChance)))")
                + "]"
        }
        return text
    }.joined(separator: " · ")
}

/// A token as the report prints it: `"-" 21 % (likeliest: "ite" 62 %, "-" 21 %, …)`, the likeliest only when the model
/// gave the token drawn less than half.
private func describe(_ token: WatchedToken) -> String {
    let drawn = "\(token.token.debugDescription) \(percent(token.chance))"
    guard token.chance < 0.5 else { return drawn }
    return drawn + " (likeliest: "
        + token.likeliest.map { "\($0.token.debugDescription) \(percent($0.chance))" }.joined(separator: ", ") + ")"
}

private func percent(_ chance: Double) -> String {
    chance >= 0.01 ? String(format: "%.0f %%", chance * 100) : String(format: "%.2f %%", chance * 100)
}

/// The words of `text` split by a hyphen that French spelling does not have, with their place in `text` (UTF-16): a
/// hyphenated word the system's French spell checker does not know, or a hyphen followed by white space between two
/// letters (« constru- ite »).
private func splitWords(in text: String) async -> [(word: String, range: NSRange)] {
    let hyphenated = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}'’]+(?:-[\p{L}\p{M}\p{N}'’]+)+"#)
    let spaced = try! NSRegularExpression(pattern: #"\p{L}+-[ \t]+\p{L}+"#)
    let all = NSRange(text.startIndex..., in: text)
    var found: [(word: String, range: NSRange)] = []
    for match in hyphenated.matches(in: text, range: all) {
        let word = (text as NSString).substring(with: match.range)
        if await !frenchSpellingHas(word) { found.append((word, match.range)) }
    }
    for match in spaced.matches(in: text, range: all) {
        found.append(((text as NSString).substring(with: match.range), match.range))
    }
    return found.sorted { $0.range.location < $1.range.location }
}

/// The words of `text` the system's French spell checker does not know, with their place in `text` (UTF-16).
@MainActor private func wordsUnknown(in text: String) -> [(word: String, range: NSRange)] {
    var found: [(word: String, range: NSRange)] = []
    var start = 0
    let length = (text as NSString).length
    while start < length {
        let range = NSSpellChecker.shared.checkSpelling(of: text, startingAt: start, language: "fr", wrap: false,
                                                        inSpellDocumentWithTag: 0, wordCount: nil)
        guard range.location != NSNotFound, range.length > 0 else { break }
        found.append(((text as NSString).substring(with: range), range))
        start = range.location + range.length
    }
    return found
}

/// Whether the system's French spell checker knows `word`.
@MainActor private func frenchSpellingHas(_ word: String) -> Bool {
    NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "fr", wrap: false,
                                        inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

/// The indices of the tokens whose text covers part of `range` (UTF-16) of the answer they make up, with the one before
/// them.
private func drawn(covering range: NSRange, in tokens: [WatchedToken]) -> [Int] {
    var start = 0
    var covering: [Int] = []
    for (index, token) in tokens.enumerated() {
        let length = token.text.utf16.count
        if length > 0, start < range.location + range.length, start + length > range.location { covering.append(index) }
        start += length
    }
    guard let first = covering.first, let last = covering.last else { return [] }
    return Array(max(first - 1, 0)...last)
}

/// Per request: the answers holding a split word, in what the model wrote and in what the voice is given; the split words;
/// and, where the model drew a hyphen in one, the chance it gave the hyphen and the token it found likeliest there.
private func summarizeStories(_ answers: [StoryAnswer], requests: [String]) {
    for request in requests {
        let these = answers.filter { $0.request == request }
        print("\n=== “\(request)” — \(these.count) answers ===")
        print("answers with a split word: in what the model wrote \(these.filter { !$0.splitWritten.isEmpty }.count) / "
              + "\(these.count) · in what the voice is given \(these.filter { !$0.splitVoice.isEmpty }.count) / "
              + "\(these.count) · answers that wrote a call: \(these.filter { $0.call != nil }.count)")
        var unknown: [String: Int] = [:]
        for word in these.flatMap(\.unknownWords) { unknown[word.word, default: 0] += 1 }
        print("answers with a word the spell checker does not know: \(these.filter { !$0.unknownWords.isEmpty }.count) / "
              + "\(these.count)" + (unknown.isEmpty ? "" : ": " + unknown.sorted { $0.value > $1.value }
                .map { "« \($0.key) » ×\($0.value)" }.joined(separator: ", ")))
        let words = these.flatMap(\.splitWritten)
        guard !words.isEmpty else { continue }
        var counts: [String: Int] = [:]
        for word in words { counts[word.word, default: 0] += 1 }
        print("split words: " + counts.sorted { $0.value > $1.value }.map { "« \($0.key) » ×\($0.value)" }
            .joined(separator: ", "))
        for word in words {
            guard let hyphen = word.tokens.firstIndex(where: { $0.token.hasPrefix("-") }) else { continue }
            let drawnHyphen = word.tokens[hyphen]
            let before = hyphen > 0 ? word.tokens[hyphen - 1].token.debugDescription : "?"
            print("  « \(word.word) »: after \(before), the hyphen had \(percent(drawnHyphen.chance)); likeliest there: "
                  + drawnHyphen.likeliest.map { "\($0.token.debugDescription) \(percent($0.chance))" }.joined(separator: ", "))
        }
    }
    let all = answers.count
    print("\nall requests: answers with a split word in what the model wrote "
          + "\(answers.filter { !$0.splitWritten.isEmpty }.count) / \(all), in what the voice is given "
          + "\(answers.filter { !$0.splitVoice.isEmpty }.count) / \(all)")
}

/// The answers' speed (--speed): medians, with the range.
private func summarizeSpeed(_ speeds: [StorySpeed]) {
    func line(_ label: String, _ values: [Double], _ format: String) -> String {
        let sorted = values.sorted()
        guard let middle = median(sorted), let low = sorted.first, let high = sorted.last else { return "\(label): —" }
        return "\(label): median " + String(format: format, middle) + " (" + String(format: format, low) + " to "
            + String(format: format, high) + ")"
    }
    print("\nspeed of \(speeds.count) answers:")
    print("  " + line("from the request to the first word", speeds.map(\.firstWordMs), "%.0f ms"))
    print("  " + line("new tokens of the request read", speeds.map(\.readMs), "%.0f ms")
          + line(", tokens read", speeds.map { Double($0.readTokens) }, "%.0f"))
    print("  " + line("writing speed", speeds.compactMap(\.tokensPerSecond), "%.1f tokens/s")
          + line(", tokens per answer", speeds.map { Double($0.tokens) }, "%.0f"))
    print("  " + line("GPU memory peak during a request", speeds.map(\.peakGB), "%.2f GB"))
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

extension Array {
    fileprivate func asyncFlatMap<T>(_ transform: (Element) async -> [T]) async -> [T] {
        var out: [T] = []
        for element in self { out += await transform(element) }
        return out
    }
}
