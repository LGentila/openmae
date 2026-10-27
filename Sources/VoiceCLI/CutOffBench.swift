// voice-cli cut-off-bench — answers cut off one after the other, as when the user speaks over Maé: does the model start
// writing the mark of a cut itself, and does it still take an answer cut off for one the user did not hear to its end?
// And answers cut by a drop (the device that has the conversation went out of reach): does the model then shorten its
// own answers?
//
// Text only. Each dialogue of the corpus (Tests/Fixtures/cut-offs-fr.json) is sent turn after turn with the app's
// system prompt, and the history is recorded as the app records it (`VoicePipeline`): a turn with "cutAfter" is cut
// once the model has written that many tokens, as after a barge-in; the history keeps what the voice had been given by
// then (the pieces of the answer the model had finished, `SentenceChunker`), cut off, and the model catches up with it
// (`LanguageModel.catchUp`). A turn with "droppedAfter" is cut by a drop once the device has heard that many pieces of
// the answer, and is not back in time to hear the rest (Tests/Fixtures/drops-fr.json): the model writes the answer to
// its end, and the history keeps it, cut by the drop (`VoicePipeline.recordHeard`); when the history keeps only what
// the device heard (--drop), the model stops once it has written the next piece. The other turns are heard to their
// end. Each dialogue runs --repeats times (default 10), each time in a new conversation. The report prints every
// answer, and counts the answers in which the model wrote an ellipsis in brackets (« […] », « [...] », « (…) »), the
// mark of a cut, and how many it wrote; those in which it copied a note that tells it an answer was cut off or cut by a
// drop; those the model stopped because they went round in circles (`RepetitionGuard`); and, per turn, the answers
// heard to their end that hold a single whole sentence (or none), and those that end in the middle of a sentence.
//
//   voice-cli cut-off-bench [--tier tier] [--llm folder] [--corpus Tests/Fixtures/cut-offs-fr.json] [--repeats 10]
//                           [--actions] [--now 2026-10-15T18:42] [--cut-off ahead|after-user-words|marker|none]
//                           [--note "(…)"] [--note-role system|user] [--drop written|heard|cut-off|none|whole]
//                           [--dialogue name] [--out measurements]
//
// --actions offers the app's actions as the model sees them when they are on (their instructions and tools, the date
// line in the user's messages; nothing is carried out: a call ends the answer). --cut-off says how the history tells the
// model that an answer was cut off; by default as the app does on the tier (`Conversation.cutOffPlacement(on:)`): "ahead",
// a note of its own right after the answer (`Conversation.cutOffMessage`), or "after-user-words", the note in the next
// message, after the user's words. For comparison, "marker" as the app did before (« […] » at the end of the answer),
// "none" not at all. --note tries another wording of the note, --note-role another role for its message when it is read
// ahead (either note). --drop says how the history keeps an answer cut by a drop: by default as the app does,
// "written", the answer as the model wrote it, to its end, then a note of its own that says how far the device heard it
// (`Conversation.dropNote`), where the note of an answer cut off goes; for comparison, "heard" what the device heard,
// then that note, "cut-off" what the device heard as an answer the user cut off (as the app did before), "none" what the
// device heard without a note, "whole" as if there had been no drop (the answer heard to its end). --dialogue runs those
// dialogues alone (their names, separated by commas).

import Foundation
import NaturalLanguage
import VoiceCore
import VoiceEngineApple

private struct CutOffCorpus: Decodable {
    var dialogues: [Dialogue]

    struct Dialogue: Decodable {
        var name: String
        var turns: [Turn]
    }

    struct Turn: Decodable {
        var user: String
        /// The answer is cut once the model has written this many tokens; nil: heard to its end.
        var cutAfter: Int?
        /// The answer is cut by a drop once the device has heard this many of its pieces; nil: heard to its end.
        var droppedAfter: Int?
    }
}

private struct CutOffTurn: Encodable {
    var user: String
    /// What the model wrote, up to the cut, as it wrote it.
    var written: String
    /// What the history keeps of the answer.
    var recorded: String
    var cut: Bool
    /// Cut by a drop: the device heard only its first pieces (`recorded` says what the history keeps of it).
    var dropped: Bool
    /// The whole sentences of the answer as the voice says it (as far as the model wrote it).
    var sentences: Int
    /// The answer ends in the middle of a sentence: its last words have no stop after them.
    var endsMidSentence: Bool
    /// The ellipses in brackets the model wrote (« […] », « [...] », « (…) »).
    var marks: Int
    /// The model wrote a note that tells it an answer was cut off or cut by a drop, or a part of it.
    var copiedNote: Bool
    /// The model stopped the answer: it went round in circles (`RepetitionGuard`).
    var looped: Bool
    /// The model wrote a tool call (then the answer ends: nothing is carried out).
    var call: String?
}

private struct CutOffRun: Encodable {
    var dialogue: String
    var run: Int
    var turns: [CutOffTurn]
}

/// How the history tells the model that an answer was cut off.
private enum CutOffStyle: String {
    /// A note of its own right after the answer, read ahead (`Conversation.CutOffPlacement.ahead`).
    case ahead
    /// The note in the next message, after the user's words (`Conversation.CutOffPlacement.afterUserWords`).
    case afterUserWords = "after-user-words"
    /// As the app did before: « […] » at the end of the answer.
    case marker
    /// Nothing.
    case none

    init(_ placement: Conversation.CutOffPlacement) {
        switch placement {
        case .ahead: self = .ahead
        case .afterUserWords: self = .afterUserWords
        }
    }

    /// Where the note goes, when there is one.
    var placement: Conversation.CutOffPlacement? {
        switch self {
        case .ahead: .ahead
        case .afterUserWords: .afterUserWords
        case .marker, .none: nil
        }
    }
}

/// How the history keeps an answer cut by a drop.
private enum DropStyle: String {
    /// As the app: the answer as the model wrote it, to its end, then `Conversation.dropNote` (how far the device heard
    /// it) where the note of an answer cut off goes.
    case written
    /// What the device heard, then `Conversation.dropNote`.
    case heard
    /// What the device heard, as an answer the user cut off (`Conversation.cutOffNote`): the app before.
    case cutOff = "cut-off"
    /// What the device heard, without a note.
    case none
    /// As if there had been no drop: the answer heard to its end.
    case whole
}

/// An ellipsis in brackets: « […] », « [...] », « (…) », « ( ... ) ».
private let bracketedEllipsis = #"[\[(]\s*(?:…|\.{2,})\s*[\])]"#

/// Words of `Conversation.cutOffNote` and `Conversation.dropNote` that an answer of the model would hardly hold unless
/// it copied the note.
private let noteParts = ["L'utilisateur t'a coupé", "liaison avec l'appareil", "l'utilisateur n'a entendu"]

func runCutOffBench(_ o: Options, arguments: [String]) async throws {
    func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    let tier = try tierOption(o)
    let style: CutOffStyle
    if let name = value("--cut-off") {
        guard let chosen = CutOffStyle(rawValue: name) else {
            throw CLIError("--cut-off: ahead, after-user-words, marker or none")
        }
        style = chosen
    } else {
        style = CutOffStyle(Conversation.cutOffPlacement(on: tier))  // as the app on this tier
    }
    let only = value("--dialogue").map { Set($0.split(separator: ",").map(String.init)) }
    let note = value("--note")
    let noteRole: ChatMessage.Role?
    switch value("--note-role") {
    case nil: noteRole = nil
    case "system": noteRole = .system
    case "user": noteRole = .user
    default: throw CLIError("--note-role: system or user")
    }
    if noteRole != nil, style != .ahead { throw CLIError("--note-role: only with the note read ahead (--cut-off ahead)") }
    let dropStyle: DropStyle
    if let name = value("--drop") {
        guard let chosen = DropStyle(rawValue: name) else {
            throw CLIError("--drop: written, heard, cut-off, none or whole")
        }
        dropStyle = chosen
    } else {
        dropStyle = .written  // as the app
    }
    if dropStyle == .cutOff, style.placement == nil {
        throw CLIError("--drop cut-off: only with a note of an answer cut off (--cut-off ahead|after-user-words)")
    }
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/cut-offs-fr.json")
    let corpus = try JSONDecoder().decode(CutOffCorpus.self, from: Data(contentsOf: corpusURL))
    let dialogues = corpus.dialogues.filter { only?.contains($0.name) ?? true }
    guard dialogues.count == only?.count ?? corpus.dialogues.count else {
        throw CLIError("--dialogue: the corpus has no dialogue named so (\(corpus.dialogues.map(\.name)))")
    }
    let drops = dialogues.contains { $0.turns.contains { $0.droppedAfter != nil } }
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
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue)) · an answer cut off: \(style.rawValue)"
          + (drops ? " · an answer cut by a drop: \(dropStyle.rawValue)" : "")
          + (o.actions ? " · with the actions" : "") + (note.map { " · note: \($0)" } ?? "")
          + (noteRole.map { " · the note's role: \($0.rawValue)" } ?? ""))
    // What the model would hardly write unless it copied a note.
    let copies = noteParts + (note.map { [$0.trimmingCharacters(in: CharacterSet(charactersIn: "()"))] } ?? [])
    let model = try await MLXChatModel.load(directory: folder)
    /// The history as the model reads it: with --note, the note after an answer cut off says that instead; with
    /// --note-role, the notes read ahead come in that role.
    func shown(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard note != nil || noteRole != nil else { return messages }
        return messages.map { message in
            if message == Conversation.cutOffMessage { return ChatMessage(noteRole ?? .system, note ?? message.content) }
            if let noteRole, message.role == .system, message.content.hasPrefix("(La liaison avec l'appareil a coupé") {
                return ChatMessage(noteRole, message.content)  // the note of a drop read ahead
            }
            guard let note, message.role == .user else { return message }
            var shown = message
            shown.content = message.content.replacingOccurrences(of: "\n" + Conversation.cutOffNote, with: "\n" + note)
            return shown
        }
    }

    // As the app: its system prompt; with the actions, their instructions and tools, and the date line; without them (no
    // tool at all), what the model is told then.
    var base = Conversation()
    base.cutOffPlacement = style.placement ?? Conversation.cutOffPlacement(on: tier)  // a drop's note goes there too
    var dateLine: String?
    if o.actions {
        await model.useTools(ActionCatalog.calendarTools(on: tier) + [ActionCatalog.timer])
        base.systemAddenda = [ActionCatalog.promptAddendum(exampleCall: await model.toolCallText(ActionCatalog.example.call))]
        if ActionCatalog.showsExamples(on: tier) { base.examples = ActionCatalog.examples(now: now, timeZone: timeZone) }
        dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
    } else {
        base.systemAddenda = [ActionCatalog.partWithoutTools]
    }

    let repeats = max(o.repeats ?? 10, 1)
    var runs: [CutOffRun] = []
    for dialogue in dialogues {
        for run in 1...repeats {
            print("■ \(dialogue.name) — run \(run)/\(repeats)")
            try await model.prefillBeginning(base.beginning)  // a new conversation
            var conversation = base
            var result = CutOffRun(dialogue: dialogue.name, run: run, turns: [])
            for (index, turn) in dialogue.turns.enumerated() {
                let message = conversation.nextUserMessage(turn.user, language: .french, dateLine: dateLine)
                let loopsBefore = await model.loopsStopped
                // A drop: the model writes on until it has written a piece the device did not hear.
                let piecesNeeded = [.whole, .written].contains(dropStyle) ? nil : turn.droppedAfter.map { $0 + 1 }
                let said = try await cutOffAnswer(model, shown(conversation.messages(adding: message)),
                                                  cutAfter: turn.cutAfter, piecesNeeded: piecesNeeded)
                let looped = await model.loopsStopped > loopsBefore
                let cut = turn.cutAfter != nil
                // Cut by a drop when the device did not hear all of it (`VoicePipeline.endCut`).
                let heard = turn.droppedAfter.map { Array(said.pieces.prefix($0)) } ?? said.pieces
                let dropped = !cut && heard.count < said.pieces.count && dropStyle != .whole
                var recorded = spoken(dropped && dropStyle != .written ? heard : said.pieces)
                let ending: Conversation.Ending
                if cut {
                    switch style {
                    case .ahead, .afterUserWords: ending = .cutOff
                    case .marker:
                        recorded += " […]"
                        ending = .whole
                    case .none: ending = .whole
                    }
                } else if dropped {
                    switch dropStyle {
                    case .written, .heard: ending = .dropped(lastHeard: heard.last?.text)
                    case .cutOff: ending = .cutOff
                    case .none, .whole: ending = .whole
                    }
                } else {
                    ending = .whole
                }
                conversation.record(user: message, steps: [], assistant: recorded, ending: ending)
                await model.catchUp(with: shown(conversation.messages))
                let marks = said.written.occurrences(of: bracketedEllipsis)
                let copiedNote = copies.contains { said.written.localizedCaseInsensitiveContains($0) }
                let (sentences, endsMidSentence) = sentenceCount(spoken(said.pieces))
                let outcome = CutOffTurn(user: turn.user, written: said.written, recorded: recorded, cut: cut,
                                         dropped: dropped, sentences: sentences, endsMidSentence: endsMidSentence,
                                         marks: marks, copiedNote: copiedNote, looped: looped, call: said.call)
                result.turns.append(outcome)
                print("  \(index + 1) 🗣 \(turn.user)")
                let mark = cut ? "✂️" : dropped ? "📵" : "🔊"
                print("      \(mark) \(said.written.trimmingCharacters(in: .whitespacesAndNewlines))"
                      + (cut || dropped ? "" : "  (\(sentences) whole sentence\(sentences > 1 ? "s" : "")"
                         + (endsMidSentence ? ", then one that does not end" : "") + ")")
                      + (marks > 0 ? "  ← \(marks) mark\(marks > 1 ? "s" : "")" : "")
                      + (copiedNote ? "  ← the note copied" : "")
                      + (looped ? "  ← stopped: it went round in circles" : "")
                      + (said.call.map { "  [call: \($0)]" } ?? ""))
                if dropped { print("      📵 the device heard: \(spoken(heard))") }
            }
            runs.append(result)
        }
    }
    summarizeCutOffs(runs, dialogues: dialogues)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let name = "cut-off-bench-\(tier.rawValue)-\(style.rawValue)" + (drops ? "-drop-\(dropStyle.rawValue)" : "")
    let url = o.out.appendingPathComponent("\(name)-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(runs).write(to: url)
    print("report: \(url.path)")
}

/// One answer, as the pipeline has it: what the model wrote up to the cut (`cutAfter` tokens: the user spoke over it
/// then), and the pieces that went to the voice by then (`SentenceChunker`), which the history keeps: those the model
/// had finished, the rest of a sentence under way dropped (`VoicePipeline.interruptAssistant`); an answer not cut,
/// whole. `piecesNeeded`: the model stops once it has written that many pieces (what follows a drop is not kept).
private func cutOffAnswer(_ model: MLXChatModel, _ request: [ChatMessage], cutAfter: Int?, piecesNeeded: Int? = nil)
    async throws -> (written: String, pieces: [SentenceChunker.Piece], call: String?)
{
    var written = ""
    var pieces: [SentenceChunker.Piece] = []
    var call: String?
    var filter = ReasoningFilter()
    var chunker = SentenceChunker()
    var tokens = 0
    var cut = false
    for try await output in model.reply(to: request) {
        switch output {
        case .text(let piece):
            written += piece
            pieces += chunker.pieces(adding: filter.push(piece))
        case .toolCall(let c): call = c.name
        case .unreadableToolCall(let raw): call = "unreadable: \(raw)"
        default: break
        }
        tokens += 1
        if let cutAfter, tokens >= cutAfter {
            cut = true
            break
        }
        if let piecesNeeded, pieces.count >= piecesNeeded {
            cut = true  // the rest goes nowhere
            break
        }
    }
    if !cut {
        pieces += chunker.pieces(adding: filter.flush())
        pieces += chunker.remainingPieces()
    }
    return (written, pieces, call)
}

/// The answer the voice says with these pieces, as the history keeps it (`VoicePipeline`'s `SpokenPiece.answer`).
private func spoken(_ pieces: [SentenceChunker.Piece]) -> String {
    var answer = ""
    for piece in pieces { SpeakableText.record(piece.text, after: piece.separator, in: &answer) }
    return answer
}

/// How many whole sentences `text` holds, as the system cuts French text into sentences, and whether it ends in the
/// middle of one: words with no stop after them (« Tout commence avec Louis treize, »).
private func sentenceCount(_ text: String) -> (whole: Int, endsMidSentence: Bool) {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    tokenizer.setLanguage(.french)
    var whole = 0
    var unfinished = false
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let sentence = text[range]
        guard sentence.contains(where: \.isLetter) else { return true }
        // Its last character that is neither a space nor a closing mark.
        let last = sentence.last { !$0.isWhitespace && !"»”\"')]".contains($0) }
        unfinished = !(last.map { ".!?…".contains($0) } ?? false)
        if !unfinished { whole += 1 }
        return true
    }
    return (whole, unfinished)
}

/// Per dialogue: the answers in which the model wrote a mark, and how many; per turn, the same over the runs, and the
/// answers heard to their end, or cut by a drop, that hold a single sentence.
private func summarizeCutOffs(_ runs: [CutOffRun], dialogues: [CutOffCorpus.Dialogue]) {
    for dialogue in dialogues {
        let mine = runs.filter { $0.dialogue == dialogue.name }
        let turns = mine.flatMap(\.turns)
        let marked = turns.filter { $0.marks > 0 }
        print("\n=== \(dialogue.name) — \(mine.count) runs ===")
        print("answers with a mark: \(marked.count) / \(turns.count) · marks in all: \(turns.map(\.marks).reduce(0, +))"
              + " · most in one answer: \(turns.map(\.marks).max() ?? 0)"
              + " · answers that copied the note: \(turns.filter(\.copiedNote).count)"
              + " · stopped going round in circles: \(turns.filter(\.looped).count)")
        let calls = turns.filter { $0.call != nil }.count
        if calls > 0 { print("answers that wrote a call: \(calls)") }
        for (index, turn) in dialogue.turns.enumerated() {
            let these = mine.compactMap { $0.turns.count > index ? $0.turns[index] : nil }
            let withMarks = these.filter { $0.marks > 0 }
            var line = "turn \(index + 1) “\(turn.user)”\(turn.cutAfter.map { " (cut after \($0) tokens)" } ?? "")"
                + "\(turn.droppedAfter.map { " (dropped after \($0) piece\($0 > 1 ? "s" : ""))" } ?? ""): "
                + "\(withMarks.count) / \(these.count) answers with a mark, \(these.map(\.marks).reduce(0, +)) marks"
            if turn.droppedAfter != nil {
                line += " · cut by the drop: \(these.filter(\.dropped).count) / \(these.count)"
            }
            let heard = these.filter { !$0.cut && !$0.dropped }  // the answers the model wrote to their end
            if !heard.isEmpty {
                let sentences = heard.map(\.sentences).sorted()
                line += " · heard to their end: \(heard.count), with a single whole sentence (or none): "
                    + "\(sentences.filter { $0 <= 1 }.count), ending in the middle of a sentence: "
                    + "\(heard.filter(\.endsMidSentence).count) · whole sentences: median "
                    + "\(sentences[sentences.count / 2]) (\(sentences[0])–\(sentences[sentences.count - 1]))"
            }
            print(line)
        }
    }
}

extension String {
    /// How many times the regular expression `pattern` is found, without overlaps.
    fileprivate func occurrences(of pattern: String) -> Int {
        var count = 0
        var rest = startIndex..<endIndex
        while let found = range(of: pattern, options: .regularExpression, range: rest) {
            count += 1
            guard found.upperBound < endIndex, !found.isEmpty else { break }
            rest = found.upperBound..<endIndex
        }
        return count
    }
}
