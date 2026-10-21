// voice-cli cache-check — how much of each request the language model finds in its memory (KV cache), in the
// sequences of requests the app sends: plain turns, an action, two actions in one request (the app carries out the
// first and says it does one thing at a time), what the app says on its own (an announcement, and a request sent while
// the model computes it in the background), a refused call and its second try, a long result the model sums up (as
// after a web search), that summing up cancelled while the model reads the result (the user spoke over the waiting
// phrase), a turn dropped after its second try (the user spoke again before any voice), a speculative answer abandoned,
// an interrupted answer (while the model writes it, or once written, while the voice says it), an answer in paragraphs,
// a speculative answer abandoned after an answer cut off, the tools
// changing, the history shortened, a new conversation; and answers that the history keeps otherwise than the model
// wrote them, after a request computed from scratch or not.
//
// Text only, as the app would send it with actions on (the same system prompt, tools and date line); no call is
// carried out: an action "succeeds" or is refused as each scenario says.
//
//   voice-cli cache-check [--tier comfort] [--llm folder] [--now 2026-10-15T18:42] [--agents] [--scenario name]
//                         [--cut-off ahead|after-user-words] [--bfloat16-prompts] [--bfloat16-experts]
//                         [--unpadded-experts]
//
// --cut-off says where the history tells the model that an answer was cut off; by default as the app does on the tier
// (`Conversation.cutOffPlacement(on:)`): "ahead", a note of its own right after the answer, or "after-user-words", the
// note in the next message, after the user's words.
//
// Each request prints the tokens found in memory ("reused"), the tokens computed, the time to compute them, the GPU
// memory in use after it and its peak during the request (and how long it waited for the model, when it did); and after
// an exchange is recorded, what the model computes of the history while nobody waits, as in the app ("the history caught
// up"): an answer cut off, or what the model never wrote (an announcement, a tool's result and the app's own sentences).
// A request after which the model counts other tokens in its memory than the memory holds is marked "out of step" (the
// next one would be computed from the wrong place). VOICE_DEBUG=1 adds the model's own lines ("the request leaves the
// cache at token N", with the text on each side; "restored the snapshot"; "prefill N tokens (reused M)"; "computed N of
// M tokens of the history ahead").
// --bfloat16-prompts computes the requests' new tokens and the history in bfloat16, as the app did before (comparisons in
// one build). --bfloat16-experts computes a mixture-of-experts model's experts' products (Gemma 4 26B's) in bfloat16 as
// the requests and the history are computed in float32 (the app computes them in float32 too). --unpadded-experts never
// pads the rows of a mixture-of-experts model's experts (Gemma 4 26B's) to the count MLX's batched kernel takes, as before
// (`MLXChatModel.padExpertRows`; the app pads them).

import Foundation
import Synchronization
import VoiceCore
import VoiceEngineApple

private struct Step {
    var label: String
    var promptTokens: Int
    var reused: Int
    var computed: Int
    var prefillMs: Double
    var firstOutputMs: Double?
    /// The GPU memory peak during the request (GB, the weights included).
    var peakGB: Double
    var rebuilt: Bool
    var restored: Bool
    var fromBeginning: Bool
}

private actor CacheCheck {
    let model: MLXChatModel
    let base: Conversation
    let dateLine: String
    /// The calls the app carries out in one request (`PipelineConfig.actionsPerRequest`).
    let maxCalls: Int
    var conversation: Conversation
    var steps: [Step] = []
    /// Time of each `catchUp` that computed something.
    var catchUps: [Double] = []
    /// Requests after which the model counted other tokens in its cache than the cache held (`MLXChatModel.cacheCounts`).
    var outOfStep = 0
    let clock = ContinuousClock()

    init(model: MLXChatModel, base: Conversation, dateLine: String, maxCalls: Int) {
        self.model = model
        self.base = base
        self.dateLine = dateLine
        self.maxCalls = maxCalls
        conversation = base
    }

    /// As "Nouvelle conversation" in the app: the model goes back to the beginning it keeps.
    func newConversation() async throws {
        conversation = base
        let start = clock.now
        try await model.prefillBeginning(conversation.beginning)
        print(String(format: "  %-46@ prefill of the system prompt: %.0f ms · GPU memory %.2f GB",
                     "new conversation" as NSString, milliseconds(clock.now - start), MLXChatModel.activeMemoryGB))
    }

    /// The user's message as the app makes it: after an answer cut off, with the note after their words when it goes
    /// there (`Conversation.CutOffPlacement.afterUserWords`).
    private func message(_ text: String) -> ChatMessage {
        conversation.nextUserMessage(text, language: .french, dateLine: dateLine)
    }

    /// The model's counts of requests computed from scratch, gone back to a snapshot, and to the conversations' beginning.
    typealias WentBack = (rebuilds: Int, restores: Int, beginnings: Int)

    private func wentBack() async -> WentBack {
        (await model.cacheRebuilds, await model.snapshotRestores, await model.beginningRestores)
    }

    /// Sends a request; `stopAfter`: stop reading (cancel) after this many pieces of output. `wentBackBefore`: the
    /// model's counts, read before something else started on the model (read here, they would wait for it, and so would
    /// the request).
    /// `moreCalls`: the model went on to another call than those it may write (`ModelOutput.moreToolCalls`).
    private func request(_ label: String, _ messages: [ChatMessage], stopAfter: Int? = nil,
                         wentBackBefore: WentBack? = nil) async throws -> (text: String, calls: [ToolCall], moreCalls: Bool)
    {
        let before: WentBack
        if let wentBackBefore { before = wentBackBefore } else { before = await wentBack() }
        var text = ""
        var calls: [ToolCall] = []
        var moreCalls = false
        var first: Double?
        var pieces = 0
        let start = clock.now
        for try await output in model.reply(to: messages) {
            if first == nil { first = milliseconds(clock.now - start) }
            switch output {
            case .text(let piece): text += piece
            case .toolCall(let call): calls.append(call)
            case .moreToolCalls: moreCalls = true
            default: break
            }
            pieces += 1
            if let stopAfter, pieces >= stopAfter { break }
        }
        let prefill = await model.lastPrefill
        let after = await wentBack()
        let step = Step(label: label, promptTokens: try await model.tokenCount(messages), reused: prefill.reused,
                        computed: prefill.computed, prefillMs: prefill.ms, firstOutputMs: first,
                        peakGB: await model.lastRequestPeakGB,
                        rebuilt: after.rebuilds > before.rebuilds, restored: after.restores > before.restores,
                        fromBeginning: after.beginnings > before.beginnings)
        steps.append(step)
        let note = step.rebuilt ? "  ← rebuilt from scratch"
            : step.reused == 0 ? "  ← from scratch" : step.fromBeginning ? "  ← back to the conversations' beginning"
            : step.restored ? "  ← back to a snapshot" : ""
        let waited = prefill.waitedMs >= 1 ? String(format: " · waited %.0f ms for the model", prefill.waitedMs) : ""
        print(String(format: "  %-46@ %5d tokens: reused %5d, computed %5d in %6.0f ms · GPU memory %.2f GB (peak %.2f)"
                     + "%@%@%@", label as NSString, step.promptTokens, step.reused, step.computed, step.prefillMs,
                     MLXChatModel.activeMemoryGB, step.peakGB, waited, note, await outOfStepNote()))
        return (text, calls, moreCalls)
    }

    /// A request the user cancels while the model reads its prompt (they spoke over the waiting phrase while it read a
    /// long result): it is cancelled once the model has read the first chunk of its new tokens (more than 512 are read in
    /// chunks), and gives no output. Prints what the model had read then, and whether it still counts the tokens its
    /// cache holds.
    private func cancelledRequest(_ label: String, _ messages: [ChatMessage]) async throws {
        let promptTokens = try await model.tokenCount(messages)
        let progress = PrefillProgress()
        await model.watchPrefill { read, total in
            // On the request's own task: cancelled as the app cancels a turn, it stops before the next chunk.
            if read < total, progress.firstChunk(read, of: total) { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var outputs = 0
        var failure: (any Error)?
        do {
            for try await _ in model.reply(to: messages) { outputs += 1 }
        } catch is CancellationError {
        } catch {
            failure = error
        }
        await model.watchPrefill(nil)
        if let failure { throw failure }
        let what = if let read = progress.read {
            "cancelled after reading \(read.read) of its \(read.total) new tokens"
        } else {
            "not cancelled (new tokens read in one go), \(outputs) outputs"
        }
        let counts = await model.cacheCounts
        if counts.counted != counts.held { outOfStep += 1 }
        print(String(format: "  %-46@ %5d tokens: %@ · the cache holds %d tokens, the model counts %d%@",
                     label as NSString, promptTokens, what, counts.held, counts.counted,
                     counts.counted != counts.held ? "  ← out of step" : ""))
    }

    /// After a request: a note when the model counts other tokens in its cache than the cache holds (the next request
    /// would be computed from the wrong place).
    private func outOfStepNote() async -> String {
        let counts = await model.cacheCounts
        guard counts.counted != counts.held else { return "" }
        outOfStep += 1
        return "  ← out of step: the model counts \(counts.counted) tokens, its cache holds \(counts.held)"
    }

    /// One turn as the pipeline runs it (`VoicePipeline.answerWithTools`): the answer goes into the history the way the
    /// pipeline records it (pieces cut and cleaned for the voice, `SpeakableText.record`). The calls the model writes, at
    /// most `maxCalls`, succeed, and the app says "C'est noté." for each; with `refuse`, the first one is refused and the
    /// model gets a second try (its calls then succeed); with `summarize`, the first one gets that result and the model
    /// sums it up (as after a web search or an agent's report). Each pass's calls go into the history as the model wrote
    /// them, in one assistant message, then their results. When the model asked for more calls than `maxCalls`, the app
    /// then says how many it does at a time. `record: false`: the turn is dropped (the user spoke again before any voice);
    /// `interrupted`: the answer is recorded as cut off. `cancelSumming`: the summing up is cancelled while the model reads
    /// the result (`cancelledRequest`). `wentBackBefore`: see `request`. `catchingUp: false`: recorded without catching up.
    func turn(_ label: String, _ text: String, refuse: Bool = false, summarize: JSONValue? = nil, record: Bool = true,
              stopAfter: Int? = nil, interrupted: Bool = false, cancelSumming: Bool = false,
              wentBackBefore: WentBack? = nil, catchingUp: Bool = true) async throws
    {
        let user = message(text)
        var request = conversation.messages(adding: user)
        var steps: [ChatMessage] = []
        var answer = ""
        var filter = ReasoningFilter()
        var chunker = SentenceChunker()
        func send(_ piece: SentenceChunker.Piece) {
            SpeakableText.record(piece.text, after: piece.separator, in: &answer)
        }
        var secondTry = false
        var summing = false
        var askedForMore = false
        while true {
            let pass = summing ? " (summing up)" : secondTry ? " (second try)" : ""
            if summing, cancelSumming {
                try await cancelledRequest(label + pass, request)
                break
            }
            let output = try await self.request(label + pass, request, stopAfter: stopAfter,
                                                wentBackBefore: pass.isEmpty ? wentBackBefore : nil)
            chunker.pieces(adding: filter.push(output.text)).forEach(send)
            chunker.pieces(adding: filter.flush()).forEach(send)
            chunker.remainingPieces().forEach(send)
            // Calls written while summing up are ignored (the pipeline then sums up once more only after calls alone).
            guard !summing, !output.calls.isEmpty else { break }
            if output.moreCalls || output.calls.count > maxCalls { askedForMore = true }
            let calls = Array(output.calls.prefix(maxCalls))
            var results: [JSONValue] = []
            for (index, _) in calls.enumerated() {
                if index == 0, refuse, !secondTry {
                    results.append(["erreur": .string(
                        "Cette date est déjà passée. Demande à l'utilisateur de préciser, ou propose une date à venir.")])
                } else if index == 0, let summarize, !secondTry {
                    results.append(summarize)
                } else {
                    results.append(["ok": .bool(true), "id": .string("r\(self.steps.count)-\(index + 1)")])
                    SpeakableText.record("C'est noté.", in: &answer)
                }
            }
            steps += [.calls(calls)] + zip(calls, results).map { .result(of: $0, $1) }
            if refuse, !secondTry {
                secondTry = true
                request = conversation.messages(adding: user) + steps
                continue
            }
            if summarize != nil, !secondTry {
                summing = true
                request = conversation.messages(adding: user) + steps
                continue
            }
            break
        }
        chunker.remainingPieces().forEach(send)
        if askedForMore { SpeakableText.record(ActionPhrases.atMost(maxCalls, .french), in: &answer) }
        if record {
            conversation.record(user: user, steps: steps, assistant: answer, interrupted: interrupted)
            if catchingUp { await catchUp(userSpeaks: interrupted) }
        }
    }

    /// What the app says on its own (a timer that rang, received information), recorded as the pipeline does: the note
    /// as the user's message, what was said as the answer, without asking the model anything.
    func announcement(note: String, said: String) async {
        recordAnnouncement(note: note, said: said)
        await catchUp()
    }

    /// An announcement recorded as `announcement` does, and a request sent `after` the model started computing it ahead
    /// (the user typed at once): the model gives way to the request once the chunk it computes is done, and the request
    /// computes the rest. Prints what was computed ahead before the request.
    func announcement(note: String, said: String, thenRequest label: String, _ text: String, after delay: Duration)
        async throws
    {
        recordAnnouncement(note: note, said: said)
        let before = await wentBack()  // read now: read with the request, they would wait for the computation ahead
        let history = conversation.messages
        let ahead = Task { [model] () -> (computed: Int, ms: Double) in
            await model.catchUp(with: history)
            return await model.lastCatchUp
        }
        try await Task.sleep(for: delay)
        try await turn(label, text, wentBackBefore: before, catchingUp: false)
        let done = await ahead.value  // read before the next catch-up
        if done.computed > 0 { catchUps.append(done.ms) }
        print(String(format: "  %-46@ %5d tokens computed ahead in %6.0f ms, then the request went first",
                     "  before it, the history caught up" as NSString, done.computed, done.ms))
        await catchUp()
    }

    private func recordAnnouncement(note: String, said: String) {
        var answer = ""
        SpeakableText.record(said, in: &answer)
        conversation.record(user: conversation.nextNoteMessage(note), steps: [], assistant: answer, interrupted: false)
        print(String(format: "  %-46@ recorded, no request", "announcement" as NSString))
    }

    /// As the pipeline does once an exchange is recorded: the model computes what of the history its memory no longer
    /// holds, and what it never wrote (`MLXChatModel.catchUp`), while nobody waits for an answer. `userSpeaks`: after an
    /// answer cut off, the user speaks over it, and background work is not allowed meanwhile, as in the app
    /// (`allowBackgroundWork`).
    private func catchUp(userSpeaks: Bool = false) async {
        if userSpeaks { await model.allowBackgroundWork(false) }
        await model.catchUp(with: conversation.messages)
        if userSpeaks { await model.allowBackgroundWork(true) }
        let done = await model.lastCatchUp
        guard done.computed > 0 else { return }
        catchUps.append(done.ms)
        print(String(format: "  %-46@ %5d tokens computed while %@, in %6.0f ms · GPU memory %.2f GB",
                     "  the history caught up" as NSString, done.computed,
                     (userSpeaks ? "the user speaks" : "nobody waits") as NSString, done.ms, MLXChatModel.activeMemoryGB))
    }

    /// The tools changed (a shortcut added): the prompt is computed again, the conversation goes on (as the app does:
    /// the new beginning first, which the model keeps, then the conversation on it).
    func toolsChanged(_ tools: [ToolSpec], label: String = "tools changed") async throws {
        await model.useTools(tools)
        let start = clock.now
        try await model.prefillBeginning(conversation.beginning)
        let beginningMs = milliseconds(clock.now - start)
        let beginning = await model.lastBeginning
        try await model.prefill(conversation.messages)
        print(String(format: "  %-46@ prefill of the whole conversation: %.0f ms (the beginning: %d tokens in %.0f ms, "
                     + "GPU memory peak %.2f GB; then the conversation) · GPU memory %.2f GB", label as NSString,
                     milliseconds(clock.now - start), beginning?.computed ?? 0, beginningMs, beginning?.peakGB ?? 0,
                     MLXChatModel.activeMemoryGB))
    }

    /// The history grew too long: the oldest exchanges are dropped once the model has prepared the shorter one.
    func shortenHistory(dropping count: Int) async throws {
        var shortened = conversation
        shortened.dropOldestExchanges(count)
        let start = clock.now
        try await model.prepareShortenedHistory(shortened.messages)
        conversation = shortened
        print(String(format: "  %-46@ prepared in the background in %.0f ms", "history shortened" as NSString,
                     milliseconds(clock.now - start)))
    }

    /// The history renders differently from its first answer on (as when the arguments of old calls, kept as the model
    /// wrote them, are forgotten after 50 calls): the next request is computed from scratch.
    func rewriteFirstAnswer() {
        var rewritten = base
        var user: ChatMessage?
        var steps: [ChatMessage] = []
        for message in conversation.exchanges {
            if message.role == .user {
                user = message
                steps = []
            } else if message.role == .assistant, message.toolCalls.isEmpty, let asked = user {
                let first = rewritten.exchanges.isEmpty
                rewritten.record(user: asked, steps: steps, assistant: message.content + (first ? " Bonne journée." : ""),
                                 interrupted: false)
                user = nil
            } else {
                steps.append(message)
            }
        }
        conversation = rewritten
        print("  history rewritten from its first answer on")
    }

    func summary() {
        let firstOutputs = steps.compactMap(\.firstOutputMs).sorted()
        let fromScratch = steps.filter { $0.reused == 0 }
        let restored = steps.filter(\.restored)
        let fromBeginning = steps.filter(\.fromBeginning)
        print(String(format: "\n%d requests · computed from scratch: %d (%.0f ms in all) · back to a snapshot: %d (%.0f ms in all)"
                     + " · back to the beginning: %d (%.0f ms in all) · first output: median %.0f ms, max %.0f ms",
                     steps.count, fromScratch.count, fromScratch.map(\.prefillMs).reduce(0, +), restored.count,
                     restored.map(\.prefillMs).reduce(0, +), fromBeginning.count,
                     fromBeginning.map(\.prefillMs).reduce(0, +),
                     firstOutputs.isEmpty ? 0 : firstOutputs[firstOutputs.count / 2], firstOutputs.last ?? 0))
        print(String(format: "the history caught up while nobody waits: %d times (%.0f ms in all)", catchUps.count,
                     catchUps.reduce(0, +)))
        print("requests after which the model counted other tokens than its cache held: \(outOfStep)")
        let prefills = steps.map(\.prefillMs).sorted()
        let peaks = steps.map(\.peakGB).sorted()
        if !prefills.isEmpty {
            print(String(format: "computing the requests' new tokens: median %.0f ms, max %.0f ms · GPU memory peak during a "
                         + "request: median %.2f GB, max %.2f GB", prefills[prefills.count / 2], prefills.last ?? 0,
                         peaks[peaks.count / 2], peaks.last ?? 0))
        }
    }
}

/// What the model had read of a request's new tokens when it was cancelled (set on the request's task).
private final class PrefillProgress: Sendable {
    private let value = Mutex<(read: Int, total: Int)?>(nil)

    /// Records the first chunk read; false for the next ones.
    func firstChunk(_ read: Int, of total: Int) -> Bool {
        value.withLock { recorded in
            guard recorded == nil else { return false }
            recorded = (read, total)
            return true
        }
    }

    var read: (read: Int, total: Int)? { value.withLock { $0 } }
}

func runCacheCheck(_ o: Options, arguments: [String]) async throws {
    let scenario = arguments.firstIndex(of: "--scenario").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    let agents = arguments.contains("--agents")
    let timeZone = TimeZone.current
    guard let now = LocalDateTime.parse(o.now ?? "2026-10-15T18:42", in: timeZone)?.date else {
        throw CLIError("--now: expected a date like 2026-10-15T18:42")
    }
    let tier = try tierOption(o)
    var placement = Conversation.cutOffPlacement(on: tier)  // as the app on this tier
    if let name = arguments.firstIndex(of: "--cut-off").flatMap({ $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }) {
        guard let chosen = Conversation.CutOffPlacement(rawValue: name) else {
            throw CLIError("--cut-off: ahead or after-user-words")
        }
        placement = chosen
    }
    let store = ModelStore()
    guard let pack = ModelCatalog.languageModel(for: tier) else { throw CLIError("no language model for this tier") }
    let folder = o.llm.map { URL(fileURLWithPath: $0) } ?? store.folder(pack)
    print("model: \(folder.lastPathComponent) (tier \(tier.rawValue)) · the note of an answer cut off: \(placement.rawValue)")
    let model = try await MLXChatModel.load(directory: folder)
    await model.computePromptsInFloat32(!o.bfloat16Prompts)
    if o.bfloat16Prompts { print("requests and history computed in bfloat16 (--bfloat16-prompts)") }
    await model.computeExpertsInHalfPrecision(o.bfloat16Experts)
    if o.bfloat16Experts { print("experts' products in bfloat16 in the requests and the history (--bfloat16-experts)") }
    if o.unpaddedExperts {
        await model.padExpertRows(from: nil)
        print("experts' rows never padded (--unpadded-experts)")
    }

    let tools = ActionCatalog.calendarTools + [ActionCatalog.timer]
        + (agents ? AgentCatalog.tools(agents: [(ClaudeCode.displayName, AgentCatalog.claudeCodeDescription)], folders: [])
            : [])
    await model.useTools(tools)
    let maxCalls = max(1, o.maxCalls ?? ActionCatalog.actionsPerRequest(on: tier))
    await model.limitToolCalls(maxCalls)
    print("calls carried out in one request: \(maxCalls) at most")
    var base = Conversation()
    base.cutOffPlacement = placement
    base.systemAddenda = [ActionCatalog.promptAddendum(exampleCall: await model.toolCallText(ActionCatalog.example.call))]
        + (agents ? [AgentCatalog.promptAddendum] : [])
    if ActionCatalog.showsExamples(on: tier) { base.examples = ActionCatalog.examples(now: now, timeZone: timeZone) }
    // As the app does at start: the model computes the beginning of every conversation, and keeps it.
    let computeStart = ContinuousClock.now
    try await model.prefillBeginning(base.beginning)
    let computeMs = milliseconds(ContinuousClock.now - computeStart)
    let promptTokens = try await model.tokenCount(base.messages)
    print(String(format: "system prompt with %d tools: %d tokens, computed in %.0f ms (GPU memory peak %.2f GB) · GPU "
                 + "memory %.2f GB\n", tools.count, promptTokens, computeMs, await model.lastBeginning?.peakGB ?? 0,
                 MLXChatModel.activeMemoryGB))

    let check = CacheCheck(model: model, base: base, dateLine: ActionCatalog.dateLine(now, timeZone: timeZone),
                           maxCalls: maxCalls)
    let scenarios: [(String, () async throws -> Void)] = [
        ("plain", {
            try await check.newConversation()
            try await check.turn("plain answer 1", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("plain answer 2", "Donne-moi une idée de dessert facile à faire.")
            try await check.turn("plain answer 3", "Et sans four, qu'est-ce que je peux faire ?")
            try await check.turn("plain answer 4", "Merci, c'est parfait.")
        }),
        ("action", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("action", "Rappelle-moi d'appeler maman demain à dix heures.")
            try await check.turn("plain answer after the action", "Qu'est-ce que je pourrais lui offrir pour son anniversaire ?")
            try await check.turn("plain answer", "Merci beaucoup.")
        }),
        ("announcement", {
            // Received information said at rest between two turns (as a timer that rings).
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            await check.announcement(note: InboundPhrases.note(source: "Home Assistant", receivedAt: now),
                                     said: "Le lave-linge a fini son cycle.")
            try await check.turn("plain answer after the announcement", "Merci. Je l'étends maintenant ou j'attends ?")
            await check.announcement(note: InboundPhrases.note(source: "Home Assistant", receivedAt: now),
                                     said: "Sonnette\u{00A0}: quelqu'un est à la porte.")
            try await check.turn("plain answer after the second", "Qui ça peut bien être à cette heure-ci ?")
        }),
        ("announcement-request", {
            // A request sent while the model computes an announcement ahead (the user typed at once, 50 ms after it was
            // said): the model gives way to it once the chunk it computes is done. A long announcement, as received
            // information can be, so that more than one chunk is left to compute.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.announcement(
                note: InboundPhrases.note(source: "Home Assistant", receivedAt: now),
                said: "Le lave-linge a fini son cycle il y a cinq minutes. La fenêtre de la chambre est restée ouverte, "
                    + "il fait quatorze degrés dans la pièce, et le facteur a déposé un colis devant la porte d'entrée.",
                thenRequest: "plain answer, sent while it is computed", "Merci. Je fais quoi en premier, à ton avis ?",
                after: .milliseconds(50))
            try await check.turn("plain answer", "D'accord, merci beaucoup.")
        }),
        ("second-try", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("action refused", "Mets un rendez-vous chez le dentiste demain à quinze heures.", refuse: true)
            try await check.turn("plain answer after the second try", "Merci, et qu'est-ce que je dois apporter chez le dentiste ?")
            try await check.turn("plain answer", "D'accord, merci.")
            try await check.turn("plain answer", "Tu as une idée de dîner rapide pour ce soir ?")
        }),
        ("two-actions", {
            // Several actions in one request: the app carries out as many as it does at once (the tier's, or --max-calls),
            // the history keeps them as the model wrote them.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("two actions in one request", "Mets un minuteur de deux minutes et un autre de cinq minutes.")
            try await check.turn("plain answer after the two actions", "Merci. Tu as une idée de dessert rapide ?")
            try await check.turn("two actions in one request",
                                 "Mets un minuteur de dix minutes et rappelle-moi d'appeler Paul demain à 9 h.")
            try await check.turn("two actions after the two actions",
                                 "Rappelle-moi d'acheter du pain demain matin et d'appeler ma mère ce soir.")
            try await check.turn("plain answer after the two actions", "Merci beaucoup.")
            try await check.turn("three actions in one request",
                                 "Mets un minuteur de vingt minutes, rappelle-moi de sortir les poubelles ce soir à 21 h "
                                     + "et ajoute un dîner chez Léa samedi à 20 h.")
            try await check.turn("plain answer after the three actions", "Super. Qu'est-ce que je pourrais apporter chez Léa ?")
            try await check.turn("two actions, the first refused",
                                 "Ajoute un rendez-vous chez le kiné hier à 17 h et mets un minuteur de dix minutes.",
                                 refuse: true)
            try await check.turn("plain answer after the refused one", "D'accord, merci.")
            try await check.turn("four actions in one request",
                                 "Mets un minuteur de cinq minutes, un de dix minutes, un de quinze minutes et un de vingt "
                                     + "minutes.")
            try await check.turn("plain answer after the four actions", "Merci, c'est tout pour l'instant.")
        }),
        ("summary", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("action, its result summed up", "Qu'est-ce que j'ai de prévu cette semaine ?",
                                 summarize: weekAgenda)
            try await check.turn("plain answer after the summary", "Merci. Et le dentiste, c'est à quelle heure déjà ?")
            try await check.turn("plain answer", "D'accord, merci beaucoup.")
        }),
        ("cancelled-summary", {
            // The user speaks over the waiting phrase while the model reads a long result (as after a web search): the
            // summing up is cancelled once the model has read the first chunk of it, and the turn is recorded as
            // interrupted, with the call and its result, as the app does. The next turns go on from what the cache holds.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("action, its summing up cancelled", "Qu'est-ce que j'ai de prévu cette semaine ?",
                                 summarize: weekAgenda, interrupted: true, cancelSumming: true)
            try await check.turn("plain answer after the cancellation", "Et le dentiste, c'est à quelle heure déjà ?")
            try await check.turn("plain answer", "D'accord, merci beaucoup.")
        }),
        ("dropped", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("action refused, turn dropped", "Mets un rendez-vous chez le dentiste demain à quinze heures.",
                                 refuse: true, record: false)
            try await check.turn("the same turn, heard in full", "Mets un rendez-vous chez le dentiste demain à quinze heures, non, plutôt à seize heures.")
            try await check.turn("plain answer", "Merci, et qu'est-ce que je dois apporter chez le dentiste ?")
            try await check.turn("plain answer", "Tu as une idée de dîner rapide pour ce soir ?")
            try await check.turn("plain answer", "Super, merci.")
        }),
        ("speculative", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("speculative answer, abandoned", "Raconte-moi", record: false, stopAfter: 1)
            try await check.turn("the same turn, heard in full", "Raconte-moi une blague courte.")
            try await check.turn("plain answer", "Ha ha, une autre ?")
        }),
        ("paragraphs", {
            // An answer in several paragraphs, heard in full: the model separates them with "\n\n".
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("answer in paragraphs",
                                 "Raconte-moi une très courte histoire de chat, en deux petits paragraphes.")
            try await check.turn("plain answer after the paragraphs",
                                 "Merci, elle est jolie. Tu as une idée de prénom pour un chat ?")
            try await check.turn("plain answer", "Super, merci.")
        }),
        ("speculative-after-cut", {
            // An answer cut off, so the next request computes it again from a snapshot; that request is speculative and
            // abandoned (the user went on), then the same turn comes back with a longer transcript.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("answer interrupted", "Raconte-moi une histoire de pirates.", stopAfter: 150,
                                 interrupted: true)
            try await check.turn("speculative answer, abandoned", "Donne-moi une idée de dessert", record: false,
                                 stopAfter: 1)
            try await check.turn("the same turn, heard in full", "Donne-moi une idée de dessert sans four, s'il te plaît.")
            try await check.turn("plain answer", "Merci, c'est parfait.")
        }),
        ("interrupted", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("answer interrupted", "Raconte-moi une histoire de pirates.", stopAfter: 12, interrupted: true)
            try await check.turn("plain answer after the interruption", "Plutôt une histoire de dragons, très courte.")
            try await check.turn("plain answer", "Merci, c'était bien.")
        }),
        ("interrupted-at-the-end", {
            // The model has written the whole answer, and the user speaks over the voice while it says it: the history
            // keeps the answer cut off, all of it, as the model wrote it.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("answer interrupted at its end", "Donne-moi une idée de dessert facile à faire.",
                                 interrupted: true)
            try await check.turn("plain answer after the interruption", "Et sans four, qu'est-ce que je peux faire ?")
            try await check.turn("plain answer", "Merci, c'est parfait.")
        }),
        ("tools-changed", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("plain answer", "Donne-moi une idée de dessert facile à faire.")
            try await check.toolsChanged(tools + [ActionCatalog.runShortcut(names: ["Mode concentration"])].compactMap { $0 })
            try await check.turn("plain answer after the tools changed", "Et sans four, qu'est-ce que je peux faire ?")
            try await check.turn("plain answer", "Merci, c'est parfait.")
            try await check.toolsChanged(tools, label: "tools back")
        }),
        ("shortened", {
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("plain answer", "Donne-moi une idée de dessert facile à faire.")
            try await check.turn("plain answer", "Et sans four, qu'est-ce que je peux faire ?")
            try await check.shortenHistory(dropping: 2)
            try await check.turn("plain answer after the shortening", "Merci, et pour le dîner ?")
            try await check.turn("plain answer", "Parfait.")
        }),
        ("cut-offs", {
            // Each answer is recorded as cut off, so that the next request cannot extend the cache.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("plain answer", "Donne-moi une idée de dessert facile à faire.")
            await check.rewriteFirstAnswer()
            try await check.turn("after the history changed, cut off", "Et sans four, qu'est-ce que je peux faire ?",
                                 interrupted: true)
            try await check.turn("plain answer, cut off", "Et avec des fraises ?", interrupted: true)
            try await check.turn("plain answer, cut off", "Tu as une idée de boisson pour aller avec ?", interrupted: true)
            try await check.turn("plain answer", "Merci, c'est parfait.")
        }),
        ("rebuilt", {
            // The tools change without the prompt being computed again: the next request is computed from scratch. Then
            // each answer is recorded as cut off, so that the next request cannot extend the cache.
            try await check.newConversation()
            try await check.turn("plain answer", "Bonjour, tu vas bien aujourd'hui ?")
            try await check.turn("plain answer", "Donne-moi une idée de dessert facile à faire.")
            await model.useTools(tools + [ActionCatalog.runShortcut(names: ["Mode concentration"])].compactMap { $0 })
            try await check.turn("after the tools changed, cut off", "Et sans four, qu'est-ce que je peux faire ?",
                                 interrupted: true)
            try await check.turn("plain answer, cut off", "Et avec des fraises ?", interrupted: true)
            try await check.turn("plain answer, cut off", "Tu as une idée de boisson pour aller avec ?", interrupted: true)
            try await check.turn("plain answer", "Merci, c'est parfait.")
            await model.useTools(tools)
        }),
    ]
    for (name, run) in scenarios where scenario == nil || scenario == name {
        print("■ \(name)")
        try await run()
        print("")
    }
    await check.summary()
}

/// A long result to sum up (about 600 tokens, like a web search's).
private let weekAgenda: JSONValue = ["evenements": [
    ["titre": "Dentiste", "debut": "2026-10-16T09:30", "fin": "2026-10-16T10:15", "lieu": "Cabinet du docteur Martin, 12 rue des Lilas",
     "notes": "Apporter la carte vitale et l'ordonnance de la dernière visite. Prévoir vingt minutes de trajet."],
    ["titre": "Réunion d'équipe", "debut": "2026-10-16T14:00", "fin": "2026-10-16T15:30", "lieu": "Salle Jupiter",
     "notes": "Ordre du jour : budget du trimestre, planning des congés, point sur le nouveau site."],
    ["titre": "Cours de yoga", "debut": "2026-10-16T18:30", "fin": "2026-10-16T19:30", "lieu": "Studio Zen, avenue Victor Hugo",
     "notes": "Ne pas oublier le tapis. Le cours de la semaine prochaine est annulé."],
    ["titre": "Dîner chez Paul et Léa", "debut": "2026-10-17T20:00", "fin": "2026-10-17T23:00", "lieu": "8 place de la Mairie",
     "notes": "Apporter le dessert. Léa est allergique aux noix."],
    ["titre": "Marché", "debut": "2026-10-18T09:00", "fin": "2026-10-18T10:30", "lieu": "Place du marché",
     "notes": "Acheter des légumes pour la semaine, du fromage et des fleurs pour la table."],
    ["titre": "Anniversaire de maman", "debut": "2026-10-18T12:30", "fin": "2026-10-18T17:00", "lieu": "Chez maman",
     "notes": "Le cadeau est chez la voisine. Toute la famille sera là, penser à appeler l'oncle Jacques."],
    ["titre": "Rendez-vous à la banque", "debut": "2026-10-19T11:00", "fin": "2026-10-19T11:45", "lieu": "Agence du centre-ville",
     "notes": "Questions sur le prêt immobilier. Prendre les trois derniers bulletins de salaire."],
    ["titre": "Kiné", "debut": "2026-10-20T08:00", "fin": "2026-10-20T08:45", "lieu": "Cabinet de kinésithérapie, rue Pasteur",
     "notes": "Séance numéro six sur dix. Faire les exercices du dos la veille au soir."],
]]

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}
