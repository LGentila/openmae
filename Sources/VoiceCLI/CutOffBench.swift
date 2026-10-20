// voice-cli cut-off-bench — answers cut off one after the other, as when the user speaks over Maé: does the model start
// writing the mark of a cut itself, and does it still take an answer cut off for one the user did not hear to its end?
//
// Text only. Each dialogue of the corpus (Tests/Fixtures/cut-offs-fr.json) is sent turn after turn with the app's
// system prompt, and the history is recorded as the app records it (`VoicePipeline`): a turn with "cutAfter" is cut
// once the model has written that many tokens, as after a barge-in; the history keeps what the voice had been given by
// then (the pieces of the answer the model had finished, `SentenceChunker`), cut off, and the model catches up with it
// (`LanguageModel.catchUp`). The other turns are heard to their end. Each dialogue runs --repeats times (default 10),
// each time in a new conversation. The report prints every answer, and counts the answers in which the model wrote an
// ellipsis in brackets (« […] », « [...] », « (…) »), the mark of a cut, and how many it wrote; those in which it
// copied the note that tells it an answer was cut off; and those the model stopped because they went round in circles
// (`RepetitionGuard`).
//
//   voice-cli cut-off-bench [--tier tier] [--llm folder] [--corpus Tests/Fixtures/cut-offs-fr.json] [--repeats 10]
//                           [--actions] [--now 2026-10-15T18:42] [--cut-off note|marker|none] [--note "(…)"]
//                           [--dialogue name] [--out measurements]
//
// --actions offers the app's actions as the model sees them when they are on (their instructions and tools, the date
// line in the user's messages; nothing is carried out: a call ends the answer). --cut-off says how the history tells the
// model that an answer was cut off: "note" as the app does (a note in the next message, `Conversation.cutOffNote`);
// for comparison, "marker" as the app did before (« […] » at the end of the answer), "none" not at all. --note tries
// another wording of the note. --dialogue runs those dialogues alone (their names, separated by commas).

import Foundation
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
    }
}

private struct CutOffTurn: Encodable {
    var user: String
    /// What the model wrote, up to the cut, as it wrote it.
    var written: String
    /// What the history keeps of the answer.
    var recorded: String
    var cut: Bool
    /// The ellipses in brackets the model wrote (« […] », « [...] », « (…) »).
    var marks: Int
    /// The model wrote the note that tells it an answer was cut off, or a part of it.
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
    /// As the app: a note in the next message (`Conversation.cutOffNote`).
    case note
    /// As the app did before: « […] » at the end of the answer.
    case marker
    /// Nothing.
    case none
}

/// An ellipsis in brackets: « […] », « [...] », « (…) », « ( ... ) ».
private let bracketedEllipsis = #"[\[(]\s*(?:…|\.{2,})\s*[\])]"#

/// Words of `Conversation.cutOffNote` that an answer of the model would hardly hold unless it copied the note.
private let noteParts = ["L'utilisateur t'a coupé"]

func runCutOffBench(_ o: Options, arguments: [String]) async throws {
    func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    guard let style = CutOffStyle(rawValue: value("--cut-off") ?? CutOffStyle.note.rawValue) else {
        throw CLIError("--cut-off: note, marker or none")
    }
    let only = value("--dialogue").map { Set($0.split(separator: ",").map(String.init)) }
    let note = value("--note")
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/cut-offs-fr.json")
    let corpus = try JSONDecoder().decode(CutOffCorpus.self, from: Data(contentsOf: corpusURL))
    let dialogues = corpus.dialogues.filter { only?.contains($0.name) ?? true }
    guard dialogues.count == only?.count ?? corpus.dialogues.count else {
        throw CLIError("--dialogue: the corpus has no dialogue named so (\(corpus.dialogues.map(\.name)))")
    }
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? "2026-10-15T18:42", in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }
    let tier = try tierOption(o)
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    guard o.llm != nil || store.isComplete([pack]) else {
        throw CLIError("\(pack.displayName) is not on this Mac: run “voice-cli download --tier \(tier.rawValue)” first")
    }
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue)) · an answer cut off: \(style.rawValue)"
          + (o.actions ? " · with the actions" : "") + (note.map { " · note: \($0)" } ?? ""))
    // What the model would hardly write unless it copied the note.
    let copies = noteParts + (note.map { [$0.trimmingCharacters(in: CharacterSet(charactersIn: "()"))] } ?? [])
    let model = try await MLXChatModel.load(directory: folder)

    // As the app: its system prompt; with the actions, their instructions and tools, and the date line.
    var base = Conversation()
    var dateLine: String?
    if o.actions {
        await model.useTools(ActionCatalog.calendarTools + [ActionCatalog.timer])
        base.systemAddenda = [ActionCatalog.promptAddendum(exampleCall: await model.toolCallText(ActionCatalog.example.call))]
        if ActionCatalog.showsExamples(on: tier) { base.examples = ActionCatalog.examples(now: now, timeZone: timeZone) }
        dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
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
                let afterCutOff = style == .note && conversation.endsCutOff
                let message = if let note, afterCutOff {
                    Conversation.userMessage(turn.user + "\n" + note, language: .french, dateLine: dateLine)
                } else {
                    Conversation.userMessage(turn.user, language: .french, dateLine: dateLine, afterCutOff: afterCutOff)
                }
                let loopsBefore = await model.loopsStopped
                let said = try await cutOffAnswer(model, conversation.messages(adding: message), cutAfter: turn.cutAfter)
                let looped = await model.loopsStopped > loopsBefore
                let cut = turn.cutAfter != nil
                switch style {
                case .note:
                    conversation.record(user: message, steps: [], assistant: said.recorded, interrupted: cut)
                case .marker:
                    conversation.record(user: message, steps: [], assistant: said.recorded + (cut ? " […]" : ""),
                                        interrupted: false)
                case .none:
                    conversation.record(user: message, steps: [], assistant: said.recorded, interrupted: false)
                }
                await model.catchUp(with: conversation.messages)
                let marks = said.written.occurrences(of: bracketedEllipsis)
                let copiedNote = copies.contains { said.written.localizedCaseInsensitiveContains($0) }
                let outcome = CutOffTurn(user: turn.user, written: said.written, recorded: said.recorded, cut: cut,
                                         marks: marks, copiedNote: copiedNote, looped: looped, call: said.call)
                result.turns.append(outcome)
                print("  \(index + 1) 🗣 \(turn.user)")
                print("      \(cut ? "✂️" : "🔊") \(said.written.trimmingCharacters(in: .whitespacesAndNewlines))"
                      + (marks > 0 ? "  ← \(marks) mark\(marks > 1 ? "s" : "")" : "")
                      + (copiedNote ? "  ← the note copied" : "")
                      + (looped ? "  ← stopped: it went round in circles" : "")
                      + (said.call.map { "  [call: \($0)]" } ?? ""))
            }
            runs.append(result)
        }
    }
    summarizeCutOffs(runs, dialogues: dialogues)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("cut-off-bench-\(tier.rawValue)-\(style.rawValue)-\(stamp).json")
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    try encoder.encode(runs).write(to: url)
    print("report: \(url.path)")
}

/// One answer, as the pipeline has it: what the model wrote up to the cut (`cutAfter` tokens: the user spoke over it
/// then), and what went to the voice, as the history keeps it: the pieces the model had finished by then, the rest of a
/// sentence under way dropped (`VoicePipeline.interruptAssistant`); an answer not cut, whole.
private func cutOffAnswer(_ model: MLXChatModel, _ request: [ChatMessage], cutAfter: Int?) async throws
    -> (written: String, recorded: String, call: String?)
{
    var written = ""
    var recorded = ""
    var call: String?
    var filter = ReasoningFilter()
    var chunker = SentenceChunker()
    func send(_ piece: SentenceChunker.Piece) { SpeakableText.record(piece.text, after: piece.separator, in: &recorded) }
    var tokens = 0
    var cut = false
    for try await output in model.reply(to: request) {
        switch output {
        case .text(let piece):
            written += piece
            chunker.pieces(adding: filter.push(piece)).forEach(send)
        case .toolCall(let c): call = c.name
        case .unreadableToolCall(let raw): call = "unreadable: \(raw)"
        default: break
        }
        tokens += 1
        if let cutAfter, tokens >= cutAfter {
            cut = true
            break
        }
    }
    if !cut {
        chunker.pieces(adding: filter.flush()).forEach(send)
        chunker.remainingPieces().forEach(send)
    }
    return (written, recorded, call)
}

/// Per dialogue: the answers in which the model wrote a mark, and how many; per turn, the same over the runs.
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
            print("turn \(index + 1) “\(turn.user)”\(turn.cutAfter.map { " (cut after \($0) tokens)" } ?? ""): "
                  + "\(withMarks.count) / \(these.count) answers with a mark, \(these.map(\.marks).reduce(0, +)) marks")
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
