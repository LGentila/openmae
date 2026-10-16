// voice-cli delegate — hands a task to Claude Code the way the app does (same tools, same folder rules, same
// process), without the app or a language model: for trying the connector, its reports, a follow-up, a stop.
//
//   voice-cli delegate --check
//   voice-cli delegate --instruction "Crée un fichier bonjour.txt…" [--title "fichier bonjour"]
//                      [--folder <where tasks and their folders go>] [--mode acceptEdits|auto]
//                      [--follow-up "Ajoute…"] [--stop-after <seconds>]
//
// It uses the Claude Code signed in on this Mac (the user's own account).

import Foundation
import VoiceCore
import VoiceEngineApple

func runDelegate(_ arguments: [String]) async throws {
    var instruction: String?
    var title = "essai de délégation"
    var folder: String?
    var mode = AgentSettings.PermissionMode.acceptEdits
    var followUp: String?
    var stopAfter: Double?
    var check = false
    var it = arguments.dropFirst(2).makeIterator()
    while let a = it.next() {
        switch a {
        case "--check": check = true
        case "--instruction": instruction = it.next()
        case "--title": title = it.next() ?? title
        case "--folder": folder = it.next()
        case "--mode": mode = AgentSettings.PermissionMode(rawValue: it.next() ?? "") ?? mode
        case "--follow-up": followUp = it.next()
        case "--stop-after": stopAfter = Double(it.next() ?? "")
        default: throw CLIError("delegate: unknown option \(a)")
        }
    }

    let connector = ClaudeCodeConnector(permissionMode: mode)
    let clock = ContinuousClock()
    let checkStart = clock.now
    let availability = await connector.availability()
    print("Claude Code: \(availability) (checked in \(clock.now - checkStart))")
    if check { return }
    guard case .ready = availability else { throw CLIError("Claude Code is not ready") }
    guard let instruction else { throw CLIError("delegate: --instruction is needed") }

    let base = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appending(path: "openmae-delegate", directoryHint: .isDirectory)
    let tools = AgentTools(store: TaskStore(folder: base.appending(path: "Tasks")),
                           workspace: base.appending(path: "OpenMae"))
    let (ends, ended) = AsyncStream<AgentTask>.makeStream()
    let printer = ChangePrinter()
    await tools.observe(onChange: { tasks in Task { await printer.show(tasks.last) } },
                        onEnd: { ended.yield($0) })
    await tools.configure(agents: [AgentTools.Agent(connector: connector, review: true)], folders: [])
    let runner = ToolRunner(providers: [tools])
    _ = await runner.tools()
    var endings = ends.makeAsyncIterator()

    func context() -> ToolContext { ToolContext(now: Date(), language: .french) }
    func ask(_ call: ToolCall) async -> ToolRunner.Reply {
        var reply = await runner.handle(call, context: context())
        print("Maé: \(reply.spoken)")
        if case .object(let status) = reply.forModel, status["statut"] == "en attente du oui de l'utilisateur",
           let confirmed = await runner.resolve(.confirm, context: context())
        {
            print("toi : oui\nMaé: \(confirmed.spoken)")
            reply = confirmed
        }
        return reply
    }

    let start = clock.now
    _ = await ask(ToolCall(name: AgentCatalog.delegateName, arguments: ["titre": .string(title),
                                                                         "consigne": .string(instruction)]))
    if let stopAfter {
        try await Task.sleep(for: .seconds(stopAfter))
        let stopStart = clock.now
        _ = await ask(ToolCall(name: AgentCatalog.cancelName, arguments: ["reference": .string(title)]))
        print("stopped in \(clock.now - stopStart)")
        try await Task.sleep(for: .milliseconds(300))
        await report(runner)
        return
    }
    guard let finished = await endings.next() else { return }
    print("ended after \(clock.now - start)")
    let notification = AgentPhrases.notification(for: finished)
    print("notification: \(notification.title) — \(notification.body)")
    await report(runner)

    if let followUp {
        let again = clock.now
        _ = await ask(ToolCall(name: AgentCatalog.followUpName, arguments: ["reference": .string(title),
                                                                             "message": .string(followUp)]))
        guard await endings.next() != nil else { return }
        print("follow-up ended after \(clock.now - again)")
        await report(runner)
    }
}

/// What etat_taches gives: what Maé says, and what the model gets to sum up.
private func report(_ runner: ToolRunner) async {
    let status = await runner.handle(ToolCall(name: AgentCatalog.statusName), context: ToolContext(now: Date(), language: .french))
    print("etat_taches → \(status.modelSpeaks ? "(the model sums it up) " : "")Maé: \(status.spoken)")
    if let data = try? JSONEncoder().encode(status.forModel), let json = String(data: data, encoding: .utf8) {
        print("  for the model: \(json)")
    }
}

/// Prints a task's state and step each time one changes.
private actor ChangePrinter {
    private var last = ""

    func show(_ task: AgentTask?) {
        guard let task else { return }
        let step = task.lastStep.map { AgentPhrases.describe($0, .french) } ?? "—"
        let line = "  [\(task.reference) \(task.status.rawValue)] \(step)"
        guard line != last else { return }
        last = line
        print(line + (task.status == .running && task.externalRef != nil ? "" : task.folder.map { "  (\($0))" } ?? ""))
    }
}
