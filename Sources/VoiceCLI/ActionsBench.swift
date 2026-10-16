// voice-cli actions-bench — does the language model pick the right action, with the right date?
//
// Text only: no microphone, no voice, and nothing is carried out (no event, reminder or timer is created).
// Each request of the corpus (Tests/Fixtures/actions-fr.json) is sent to the model with the same system
// prompt and tools as in the app, at a fixed reference time, and the call it writes is compared with the
// expected one.
//
//   voice-cli actions-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                           [--corpus Tests/Fixtures/actions-fr.json] [--out measurements]

import Foundation
import VoiceCore
import VoiceEngineApple

private struct Corpus: Decodable {
    var now: String
    var shortcuts: [String]
    var cases: [Case]

    struct Case: Decodable {
        var phrase: String
        var expected: Expected?
        var before: [Exchange]?
    }

    struct Expected: Decodable {
        var tool: String
        /// The date the call carries: "2026-10-16T15:00" (to the minute), "2026-10-16" (the day), "none".
        var when: String?
        var end: String?
        var seconds: Int?
        var name: String?
    }

    /// An earlier exchange, for corrections ("décale-le").
    struct Exchange: Decodable {
        var user: String
        var call: ToolCall
        var result: JSONValue
        var answer: String
    }
}

private struct CaseResult: Encodable {
    var phrase: String
    var expected: String
    var chosen: String
    var arguments: [String: JSONValue]?
    var text: String
    var toolOK: Bool
    var argumentsOK: Bool?
    /// What the app would say if it refused the call (date in the past, malformed…).
    var refusal: String?
    var firstOutputMs: Double?
    var callMs: Double?
}

func runActionsBench(_ o: Options) async throws {
    let corpusURL = URL(fileURLWithPath: o.corpus ?? "Tests/Fixtures/actions-fr.json")
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? corpus.now, in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }

    let tier = try tierOption(o)
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    guard o.llm != nil || store.isComplete([pack]) else {
        throw CLIError("\(pack.displayName) is not on this Mac: run “voice-cli download --tier \(tier.rawValue)” first")
    }
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue)) · reference time \(LocalDateTime.format(now, in: timeZone))")
    let clock = ContinuousClock()
    let loadStart = clock.now
    let model = try await MLXChatModel.load(directory: folder)
    print("loaded in \(clock.now - loadStart)")

    let tools = ActionCatalog.calendarTools + [ActionCatalog.timer]
        + [ActionCatalog.runShortcut(names: corpus.shortcuts)].compactMap { $0 }
    await model.useTools(tools)
    var conversation = Conversation()
    conversation.systemAddenda = [ActionCatalog.promptAddendum]
    let dateLine = ActionCatalog.dateLine(now, timeZone: timeZone)
    let prefixStart = clock.now
    try await model.prefill(conversation.messages)
    let prefixTokens = try await model.tokenCount(conversation.messages)
    print("system prompt with \(tools.count) tools: \(prefixTokens) tokens, computed in \(clock.now - prefixStart)\n")
    if o.showPrompt { print(try await model.promptText(conversation.messages) + "\n") }

    var results: [CaseResult] = []
    for (index, item) in corpus.cases.enumerated() {
        var history = conversation
        for exchange in item.before ?? [] {
            history.record(user: Conversation.userMessage(exchange.user, language: .french, dateLine: dateLine),
                           steps: [.call(exchange.call), .result(of: exchange.call, exchange.result)],
                           assistant: exchange.answer, interrupted: false)
        }
        let request = history.messages(adding: Conversation.userMessage(item.phrase, language: .french, dateLine: dateLine))
        var text = ""
        var call: ToolCall?
        var unreadable: String?
        var firstOutput: Double?
        var callTime: Double?
        let start = clock.now
        for try await output in model.reply(to: request) {
            if firstOutput == nil { firstOutput = milliseconds(clock.now - start) }
            switch output {
            case .text(let piece): text += piece
            case .toolCallStarted: break
            case .toolCall(let made):
                if call == nil {
                    call = made
                    callTime = milliseconds(clock.now - start)
                }
            case .unreadableToolCall(let raw): unreadable = raw
            }
        }
        var filter = ReasoningFilter()
        text = (filter.push(text) + filter.flush()).trimmingCharacters(in: .whitespacesAndNewlines)

        let expectedTool = item.expected?.tool ?? "aucun"
        let chosen = call?.name ?? (unreadable != nil ? "illisible" : "aucun")
        var result = CaseResult(phrase: item.phrase, expected: expectedTool, chosen: chosen, arguments: call?.arguments,
                                text: text, toolOK: chosen == expectedTool, firstOutputMs: firstOutput, callMs: callTime)
        let context = ToolContext(now: now, timeZone: timeZone, language: .french)
        if let call {
            do { try ActionCatalog.check(call, context: context, shortcuts: corpus.shortcuts) } catch let refusal as ToolRefusal {
                result.refusal = refusal.forModel
            }
        }
        if result.toolOK, let expected = item.expected, let call {
            result.argumentsOK = argumentsMatch(call, expected, context) && result.refusal == nil
        }
        results.append(result)
        let mark = result.toolOK ? (result.argumentsOK == false ? "~" : "✓") : "✗"
        let detail = call.map { "\($0.name) \(describe($0.arguments))" } ?? (unreadable.map { "unreadable: \($0)" } ?? "“\(text.prefix(70))”")
        print(String(format: "%3d %@ %@", index + 1, mark, item.phrase))
        print("      → \(detail)" + (result.refusal.map { "  [refused: \($0)]" } ?? "")
              + "  \(fmt(callTime ?? firstOutput))")
    }
    summarize(results, tier: tier, model: folder.lastPathComponent, options: o)
}

/// Compares the call's dates (to the minute, or to the day), length or shortcut with the expected ones.
private func argumentsMatch(_ call: ToolCall, _ expected: Corpus.Expected, _ context: ToolContext) -> Bool {
    let timeZone = context.timeZone
    func sameMoment(_ actual: String?, _ wanted: String) -> Bool {
        if wanted == "none" { return actual == nil }
        guard let actual, let a = LocalDateTime.parse(actual, in: timeZone),
              let w = LocalDateTime.parse(wanted, in: timeZone) else { return false }
        if w.hasTime { return a.hasTime && a.date == w.date }
        return context.calendar.isDate(a.date, inSameDayAs: w.date)
    }
    if let when = expected.when {
        let actual: String? = switch call.name {
        case ActionCatalog.createReminder.name: call.text("echeance")
        case ActionCatalog.changeItem.name: call.text("debut") ?? call.text("echeance")
        case ActionCatalog.readAgenda.name, ActionCatalog.listReminders.name: call.text("debut") ?? call.text("fin")
        default: call.text("debut")
        }
        guard sameMoment(actual, when) else { return false }
    }
    if let end = expected.end {
        guard let times = try? ActionCatalog.eventTimes(call, context: context),
              let wanted = LocalDateTime.parse(end, in: timeZone) else { return false }
        if wanted.hasTime ? times.end != wanted.date : !context.calendar.isDate(times.end, inSameDayAs: wanted.date) {
            return false
        }
    }
    if let seconds = expected.seconds, call.arguments["duree_secondes"]?.integer != seconds { return false }
    if let name = expected.name, call.text("nom") != name { return false }
    return true
}

private func summarize(_ results: [CaseResult], tier: HardwareTier, model: String, options o: Options) {
    let actions = results.filter { $0.expected != "aucun" }
    let others = results.filter { $0.expected == "aucun" }
    let rightTool = actions.filter(\.toolOK).count
    let rightAction = actions.filter { $0.toolOK && $0.argumentsOK != false }.count
    let falseTriggers = others.filter { !$0.toolOK }
    let missed = actions.filter { $0.chosen == "aucun" }.count

    print("\n=== \(model) — \(results.count) requests ===")
    print(String(format: "right tool: %d / %d (%.0f %%)", rightTool, actions.count, percent(rightTool, actions.count)))
    print(String(format: "right tool and right date / length / name: %d / %d (%.0f %%)", rightAction, actions.count,
                 percent(rightAction, actions.count)))
    print("requests without an action that triggered one: \(falseTriggers.count) / \(others.count)"
          + falseTriggers.map { "\n    · \($0.phrase) → \($0.chosen)" }.joined())
    print("action requests answered without a tool: \(missed)")
    print("calls the app would refuse: \(results.filter { $0.refusal != nil }.count)")
    let copied = results.filter { $0.text.range(of: #"\(\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil }
    print("answers copying the date line (removed before the voice): \(copied.count) / \(results.filter { !$0.text.isEmpty }.count)")

    // Expected / chosen.
    let tools = ["creer_evenement", "creer_rappel", "lire_agenda", "lister_rappels", "modifier_element",
                 "supprimer_element", "minuteur", "lancer_raccourci", "aucun"]
    let others2 = Set(results.map(\.chosen)).subtracting(tools).sorted()
    let columns = tools + others2
    print("\nexpected ↓ / chosen →")
    print("".padding(toLength: 18, withPad: " ", startingAt: 0)
          + columns.map { String($0.prefix(8)).padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
    for expected in tools {
        let row = results.filter { $0.expected == expected }
        guard !row.isEmpty else { continue }
        print(expected.padding(toLength: 18, withPad: " ", startingAt: 0)
              + columns.map { chosen in
                  let n = row.filter { $0.chosen == chosen }.count
                  return (n == 0 ? "·" : String(n)).padding(toLength: 9, withPad: " ", startingAt: 0)
              }.joined())
    }

    let callTimes = actions.compactMap(\.callMs)
    let textTimes = others.filter(\.toolOK).compactMap(\.firstOutputMs)
    print("\ntime to a complete call: median \(fmt(median(callTimes))), worst \(fmt(callTimes.max()))")
    print("time to the first word of an answer without action: median \(fmt(median(textTimes))), worst \(fmt(textTimes.max()))")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let url = o.out.appendingPathComponent("actions-bench-\(tier.rawValue)-\(stamp).json")
    do {
        try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
        try encoder.encode(results).write(to: url)
        print("report: \(url.path)")
    } catch {
        print("could not write the report: \(error)")
    }
}

private func describe(_ arguments: [String: JSONValue]) -> String {
    "{" + arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text ?? "\($0.value)")" }
        .joined(separator: ", ") + "}"
}

private func percent(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) * 100 / Double(whole) }

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
