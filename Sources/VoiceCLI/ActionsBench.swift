// voice-cli actions-bench — does the language model pick the right action, with the right date?
//
// Text only: no microphone, no voice, and nothing is carried out (no event, reminder or timer is created).
// Each request of the corpus (Tests/Fixtures/actions-fr.json) is sent to the model with the same system
// prompt and tools as in the app, at a fixed reference time, and what the app would make of the call it writes
// (the tool its name stands for, misspelled or not; the date worked out from the words it copied, the length, the
// shortcut) is compared with the expected one.
//
//   voice-cli actions-bench [--tier minimum|standard|comfort|max] [--llm folder] [--now 2026-10-15T18:42]
//                           [--corpus Tests/Fixtures/actions-fr.json] [--out measurements] [--show-prompt]
//                           [--watch-calls]
//
// --watch-calls also reports, for each request, the chance the model gave to opening a tool call (at the
// first token of its answer, and at its most tempted token) and the answer as written, special tokens
// included. It slows generation a little: timings of such a run are not comparable.
// Experiments without rebuilding: --addendum <file> replaces the actions part of the system prompt, and
// --examples <file> records exchanges (the shape of a case's "before", plus an optional "dateLine") at the
// start of every conversation.

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
        /// Only for --examples (a case's earlier exchanges get the reference time's line).
        var dateLine: String?
    }
}

private struct CaseResult: Encodable {
    var phrase: String
    var expected: String
    var chosen: String
    /// The tool name as the model wrote it, when the app reads it as another tool's (`ToolNames`).
    var writtenName: String?
    var arguments: [String: JSONValue]?
    var text: String
    var toolOK: Bool
    var argumentsOK: Bool?
    /// What the app would make of the call: "2026-10-17T20:00 → 2026-10-17T21:00", "600 s".
    var resolved: String?
    /// What the app would say if it refused the call (date in the past, malformed…).
    var refusal: String?
    /// After a refusal, the call the model makes once it knows why (the app gives it that second try).
    var secondTry: String?
    var rightAfterSecondTry: Bool?
    var firstOutputMs: Double?
    var callMs: Double?
    /// With --watch-calls: the chance of opening a tool call at the first token, and at the most tempted one.
    var firstCallChance: Double?
    var bestCallChance: Double?
    var bestCallAt: Int?
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
    // As in the app (`ToolRunner.named`): a misspelled tool name is read as the tool's.
    func named(_ call: ToolCall) -> ToolCall {
        var named = call
        named.name = ToolNames.match(call.name, among: tools.map(\.name)) ?? call.name
        return named
    }
    await model.useTools(tools)
    await model.watchToolCalls(o.watchCalls)
    var conversation = Conversation()
    let exampleCall = await model.toolCallText(ActionCatalog.example.call)
    conversation.systemAddenda = [try o.addendum.map { try String(contentsOfFile: $0, encoding: .utf8) }
        ?? ActionCatalog.promptAddendum(exampleCall: exampleCall)]
    if let file = o.examples {
        // Experiment: exchanges shown at the start of every conversation, as if they had happened.
        let examples = try JSONDecoder().decode([Corpus.Exchange].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        for example in examples {
            conversation.record(user: Conversation.userMessage(example.user, language: .french, dateLine: example.dateLine),
                                steps: [.call(example.call), .result(of: example.call, example.result)],
                                assistant: example.answer, interrupted: false)
        }
    }
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
        let written = call?.name
        call = call.map(named)

        let expectedTool = item.expected?.tool ?? "aucun"
        let chosen = call?.name ?? (unreadable != nil ? "illisible" : "aucun")
        var result = CaseResult(phrase: item.phrase, expected: expectedTool, chosen: chosen,
                                writtenName: written == call?.name ? nil : written, arguments: call?.arguments,
                                text: text, toolOK: chosen == expectedTool, firstOutputMs: firstOutput, callMs: callTime)
        if o.watchCalls, let chances = await model.lastToolCallChances {
            result.firstCallChance = chances.first
            result.bestCallChance = chances.best
            result.bestCallAt = chances.bestAt
        }
        // As in the app: what the user said, this request then the earlier ones.
        let context = ToolContext(now: now, timeZone: timeZone, language: .french,
                                  userSaid: [item.phrase] + (item.before ?? []).reversed().map(\.user))
        let created = item.before?.last
        var refusal: ToolRefusal?
        if let call {
            do {
                let resolved = try resolve(call, created: created, context: context, shortcuts: corpus.shortcuts)
                result.resolved = resolved.description(timeZone)
                if result.toolOK, let expected = item.expected {
                    result.argumentsOK = matches(resolved, expected, context)
                }
            } catch let refused as ToolRefusal {
                refusal = refused
                result.refusal = refused.forModel
                if result.toolOK, item.expected != nil { result.argumentsOK = false }
            }
        }
        if let call, let refusal, refusal.retryable {
            // As in the app: the model sees why its call was refused and gets one more try.
            var retried: ToolCall?
            for try await output in model.reply(to: request + [.call(call), .result(of: call, ["erreur": .string(refusal.forModel)])]) {
                if case .toolCall(let made) = output, retried == nil { retried = made }
            }
            let writtenAgain = retried?.name
            retried = retried.map(named)
            result.secondTry = retried.map { describe($0, written: writtenAgain) } ?? "no call"
            if let retried, let expected = item.expected, retried.name == expectedTool,
               let resolved = try? resolve(retried, created: created, context: context, shortcuts: corpus.shortcuts)
            {
                result.secondTry! += " = " + resolved.description(timeZone)
                result.rightAfterSecondTry = matches(resolved, expected, context)
            } else {
                result.rightAfterSecondTry = false
            }
        }
        results.append(result)
        let mark = result.toolOK ? (result.argumentsOK == false ? "~" : "✓") : "✗"
        let detail = call.map { describe($0, written: written) } ?? (unreadable.map { "unreadable: \($0)" } ?? "“\(text.prefix(70))”")
        print(String(format: "%3d %@ %@", index + 1, mark, item.phrase))
        let watched = result.bestCallChance.map {
            String(format: "  call chance %.0f %% first, %.0f %% at token %d", (result.firstCallChance ?? 0) * 100,
                   $0 * 100, result.bestCallAt ?? 0)
        } ?? ""
        print("      → \(detail)" + (result.resolved.map { " = \($0)" } ?? "") + (result.refusal.map { "  [refused: \($0)]" } ?? "")
              + "  \(fmt(callTime ?? firstOutput))" + watched)
        if let second = result.secondTry {
            print("      second try → \(second)" + (result.rightAfterSecondTry == true ? "  ✓" : "  ✗"))
        }
        if o.watchCalls { print("      raw: \(await model.lastRawAnswer.debugDescription)") }
    }
    summarize(results, tier: tier, model: folder.lastPathComponent, options: o)
}

/// What the app would do with a call: the moment, end, length or shortcut it would use. Throws the refusal it would
/// give. `created`: for a change, the exchange that created the item.
private struct Resolved {
    var start: Date?
    var hasTime = false
    var end: Date?
    var seconds: Int?
    var name: String?

    func description(_ timeZone: TimeZone) -> String {
        var parts: [String] = []
        if let start { parts.append(LocalDateTime.format(start, in: timeZone, withTime: hasTime)) }
        if let end { parts.append("→ " + LocalDateTime.format(end, in: timeZone, withTime: hasTime)) }
        if let seconds { parts.append("\(seconds) s") }
        if let name { parts.append("“\(name)”") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " ")
    }
}

private func resolve(_ call: ToolCall, created: Corpus.Exchange?, context: ToolContext, shortcuts: [String]) throws -> Resolved {
    try ActionCatalog.check(call, context: context, shortcuts: shortcuts)
    switch call.name {
    case ActionCatalog.createEvent.name:
        let times = try ActionCatalog.eventTimes(call, context: context)
        return Resolved(start: times.start, hasTime: !times.allDay, end: times.end)
    case ActionCatalog.createReminder.name:
        let due = try ActionCatalog.reminderDue(call, context: context)
        return Resolved(start: due?.date, hasTime: due?.hasTime ?? false)
    case ActionCatalog.readAgenda.name, ActionCatalog.listReminders.name:
        let period = try ActionCatalog.period(call, context: context, required: call.name == ActionCatalog.readAgenda.name)
        return Resolved(start: period?.0, end: period?.1)
    case ActionCatalog.changeItem.name, ActionCatalog.deleteItem.name:
        // As the app: only an item created in this conversation (the corpus's earlier exchange) can be changed.
        guard case .object(let fields)? = created?.result, fields["id"] != nil else {
            throw ToolRefusal(forModel: "Aucun élément « \(call.text("reference") ?? "dernier") » créé dans cette "
                              + "conversation : seuls ceux-là peuvent être modifiés ou supprimés.",
                              spoken: ActionPhrases.nothingToChange(context.language))
        }
        guard call.name == ActionCatalog.changeItem.name else { return Resolved() }
        // The item as the app saved it.
        func saved(_ key: String) -> (date: Date, hasTime: Bool)? {
            guard case .object(let fields)? = created?.result, let text = fields[key]?.text else { return nil }
            return LocalDateTime.parse(text, in: context.timeZone)
        }
        if let start = saved("debut") {
            let end = saved("fin")?.date ?? start.date.addingTimeInterval(3600)
            let times = try ActionCatalog.changedEvent(call, start: start.date, end: end, allDay: !start.hasTime,
                                                       context: context)
            return times.map { Resolved(start: $0.start, hasTime: !$0.allDay, end: $0.end) } ?? Resolved()
        }
        let due = try ActionCatalog.changedDue(call, due: saved("echeance"), context: context)
        return Resolved(start: due?.date, hasTime: due?.hasTime ?? false)
    case ActionCatalog.timer.name:
        return Resolved(seconds: try ActionCatalog.timerSeconds(call, context: context))
    default:
        return Resolved(name: call.text("nom"))
    }
}

/// Compares what the app would do (dates to the minute, or to the day; length; shortcut) with the expected one.
private func matches(_ resolved: Resolved, _ expected: Corpus.Expected, _ context: ToolContext) -> Bool {
    let timeZone = context.timeZone
    if let when = expected.when {
        if when == "none" {
            guard resolved.start == nil else { return false }
        } else {
            guard let start = resolved.start, let wanted = LocalDateTime.parse(when, in: timeZone) else { return false }
            if wanted.hasTime ? !(resolved.hasTime && start == wanted.date)
                : !context.calendar.isDate(start, inSameDayAs: wanted.date)
            {
                return false
            }
        }
    }
    if let end = expected.end {
        guard let actual = resolved.end, let wanted = LocalDateTime.parse(end, in: timeZone) else { return false }
        if wanted.hasTime ? actual != wanted.date : !context.calendar.isDate(actual, inSameDayAs: wanted.date) {
            return false
        }
    }
    if let seconds = expected.seconds, resolved.seconds != seconds { return false }
    if let name = expected.name, resolved.name != name { return false }
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
    let rightInApp = rightAction + actions.filter { $0.rightAfterSecondTry == true }.count
    print(String(format: "  with the app's second try after a refused call: %d / %d (%.0f %%)", rightInApp,
                 actions.count, percent(rightInApp, actions.count)))
    print("requests without an action that triggered one: \(falseTriggers.count) / \(others.count)"
          + falseTriggers.map { "\n    · \($0.phrase) → \($0.chosen)" }.joined())
    print("action requests answered without a tool: \(missed)")
    print("calls the app would refuse: \(results.filter { $0.refusal != nil }.count)")
    let misspelled = results.filter { $0.writtenName != nil }
    print("misspelled tool names read as the tool's: \(misspelled.count)"
          + misspelled.map { "\n    · \($0.writtenName ?? "") → \($0.chosen)" }.joined())
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

    if results.contains(where: { $0.bestCallChance != nil }) {
        // How tempted the model was: a request it missed with a high chance could be caught at that token, as long
        // as the requests without an action stay low.
        let bins: [(String, Range<Double>)] = [("<1", 0..<0.01), ("1-5", 0.01..<0.05), ("5-20", 0.05..<0.2),
                                               ("20-50", 0.2..<0.5), ("≥50", 0.5..<1.01)]
        func histogram(_ values: [Double]) -> String {
            bins.map { label, range in "\(label) %: \(values.filter(range.contains).count)" }.joined(separator: "  ")
        }
        let missedActions = actions.filter { $0.chosen == "aucun" }
        print("\nchance of opening a call (missed actions / requests without an action):")
        print("  first token   missed: " + histogram(missedActions.compactMap(\.firstCallChance)))
        print("                none:   " + histogram(others.compactMap(\.firstCallChance)))
        print("  most tempted  missed: " + histogram(missedActions.compactMap(\.bestCallChance)))
        print("                none:   " + histogram(others.compactMap(\.bestCallChance)))
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

/// "creer_rappel {quand: …}", after the name the model wrote when the app read it as another ("crer_rappel → …").
private func describe(_ call: ToolCall, written: String?) -> String {
    (written.flatMap { $0 == call.name ? nil : "\($0) → " } ?? "") + "\(call.name) \(describe(call.arguments))"
}

private func describe(_ arguments: [String: JSONValue]) -> String {
    "{" + arguments.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.text ?? "\($0.value)")" }
        .joined(separator: ", ") + "}"
}

private func percent(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) * 100 / Double(whole) }

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
