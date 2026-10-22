// voice-cli read-sizes — how long the language model takes to read a request's new tokens, by their number. After a
// conversation of about 1,500 tokens (the system prompt with the actions as cache-check has it, then one exchange), the
// first N tokens of the next request are read as a request reads them (`MLXChatModel.readTimes`: in float32, up to the
// answer's first token, everything waited for), for N from --from to --to, --runs times each after a first pass that is
// not kept, each N in turn so that every N sees the same Mac. Run it with the GPU kept to itself, as any timing.
//
//   voice-cli read-sizes [--tier comfort] [--llm folder] [--from 32] [--to 96] [--runs 5] [--compare-padding]
//                        [--unpadded-experts]
//
// The experts of a mixture-of-experts model (Gemma 4 26B's) pad their rows as in the app (`MLXChatModel.padExpertRows`);
// --unpadded-experts never pads them, as before; --compare-padding reads each N in every way, one right after the other:
// never padded, padded whenever the rows are sorted (from 8 tokens on), and as in the app when it differs.

import Foundation
import VoiceCore
import VoiceEngineApple

func runReadSizes(_ o: Options, arguments: [String]) async throws {
    func value(_ name: String) -> Int? {
        arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
    }
    let from = value("--from") ?? 32
    let to = value("--to") ?? 96
    let runs = value("--runs") ?? 5
    guard from >= 1, to >= from, runs >= 1 else { throw CLIError("--from, --to, --runs: 1 ≤ from ≤ to, runs ≥ 1") }
    let compare = arguments.contains("--compare-padding")
    let tier = try tierOption(o)
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue))")
    let model = try await MLXChatModel.load(directory: folder)
    let app = MLXChatModel.expertRowsPaddedFrom
    let ways: [(name: String, padding: Int?)] = compare
        ? [("never padded", nil), ("padded when sorted", 0)] + (app == 0 ? [] : [("as in the app", app)])
        : [o.unpaddedExperts ? ("never padded", nil) : ("as in the app", app)]

    let timeZone = TimeZone.current
    let now = LocalDateTime.parse(o.now ?? "2026-10-15T18:42", in: timeZone)?.date ?? Date()
    await model.useTools(ActionCatalog.calendarTools + [ActionCatalog.timer])
    var conversation = Conversation()
    conversation.systemAddenda = [
        ActionCatalog.promptAddendum(exampleCall: await model.toolCallText(ActionCatalog.example.call)),
    ]
    if ActionCatalog.showsExamples(on: tier) { conversation.examples = ActionCatalog.examples(now: now, timeZone: timeZone) }
    try await model.prefillBeginning(conversation.beginning)
    conversation.record(user: "Bonjour, tu vas bien aujourd'hui ?", language: .french,
                        assistant: "Bonjour ! Je vais très bien, merci. Et toi, comment se passe ta journée ?",
                        interrupted: false)
    let next = conversation.nextUserMessage(
        "J'aimerais préparer un dîner pour six personnes samedi soir, avec une entrée, un plat et un dessert, sans "
            + "trop de travail le jour même. Deux de mes amis ne mangent pas de viande, et l'un d'eux est allergique aux "
            + "noisettes. Qu'est-ce que tu me proposerais comme menu, et qu'est-ce que je peux préparer la veille pour "
            + "gagner du temps ? Dis-moi aussi combien de temps il faut compter pour chaque plat.",
        language: .french, dateLine: ActionCatalog.dateLine(now, timeZone: timeZone))
    let historyTokens = try await model.tokenCount(conversation.messages)
    print("history: \(historyTokens) tokens · new tokens \(from) to \(to), \(runs) runs each (after one not kept) · "
          + ways.map { "\($0.name) (\($0.padding.map { "from \($0) rows" } ?? "never"))" }.joined(separator: ", ") + "\n")

    let times = try await model.readTimes(after: conversation.messages, next: next, counts: Array(from...to),
                                          paddings: ways.map(\.padding), runs: runs)
    func right(_ text: String, _ width: Int = 26) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }
    print("new tokens" + ways.map { right($0.name) }.joined() + "   (median, min–max, ms)")
    for count in from...to {
        var line = right(String(count), 10)
        for way in ways.indices {
            let values = (times[way][count] ?? []).sorted()
            guard let middle = median(values) else { continue }
            line += right(String(format: "%.0f (%.0f–%.0f)", middle, values.first ?? 0, values.last ?? 0))
        }
        print(line)
    }
    if ways.count > 1 {
        print("")
        for way in ways.indices.dropFirst() {
            let gains = (from...to).compactMap { count -> Double? in
                guard let before = median(times[0][count] ?? []), let after = median(times[way][count] ?? [])
                else { return nil }
                return before - after
            }
            print(String(format: "%@ against never padded: %.0f ms less in median over the %d counts (most %.0f, least "
                         + "%.0f)", ways[way].name as NSString, median(gains) ?? 0, gains.count, gains.max() ?? 0,
                         gains.min() ?? 0))
        }
    }
}
