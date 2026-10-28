// voice-cli fake-home-assistant — the pretend Home Assistant (FakeHomeAssistant) as a program on this Mac: its MCP
// server on standard input and output, one JSON-RPC message per line, until its input ends. What `connected-program`
// starts by default; also a program to add in the app's settings where Node is not installed (command: this voice-cli's
// path; arguments: fake-home-assistant).
//
// voice-cli connected-program — a connected tool that is a program on this Mac, as the app has it: found and started by
// `MCPProgram.launch` and `MCPProgramClient`, its actions listed, then typed turns through the whole pipeline (the voice
// speaks into a silent speaker), with « Oui » when Maé asks first; at the end it is stopped: is anything of it left?
//
//   voice-cli connected-program [--command "<command>"] [--arguments "<arguments>"] [--name <name>] [--request "…"]…
//                               [--tier minimum|standard|comfort]
//   voice-cli connected-program --lifecycle
//
// Without --command: this voice-cli's pretend Home Assistant, named "Home Assistant", with the requests « Allume le
// salon » and « Est-ce que la lumière de la cuisine est allumée ? ».
//
// --lifecycle: no model. The pretend Home Assistant as a connected tool of the engine (AssistantHost, its settings
// changed as the app changes them): turned on, killed (started again?), turned off, on, removed, on, then the app's quit
// (`AssistantHost.stopProgramsNow`). After each step: is its program running?

import Darwin
import FakeHomeAssistant
import Foundation
import VoiceCore
import VoiceEngineApple

/// `voice-cli fake-home-assistant` (see the top of this file). Never returns.
func serveFakeHomeAssistant() -> Never {
    let server = FakeHomeAssistant()
    DebugLog.writeToStandardError("fake Home Assistant: serving MCP on standard input and output\n")
    while let line = readLine(strippingNewline: true) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let reply = server.reply(to: message), let data = try? JSONEncoder().encode(reply)
        else { continue }
        print(String(decoding: data, as: UTF8.self))  // stdout is written a line at a time (`setvbuf` at the entry)
    }
    exit(0)
}

/// The connected tool's log lines, kept in order.
private actor ProgramLog {
    var entries: [ConnectedToolLogEntry] = []
    func add(_ report: ConnectedToolReport) {
        if case .log(_, let entry) = report { entries.append(entry) }
    }
}

func runConnectedProgram(_ o: Options, arguments: [String]) async throws {
    var command: String?
    var programArguments = ""
    var name: String?
    var lifecycle = false
    var it = arguments.dropFirst(2).makeIterator()
    while let a = it.next() {
        switch a {
        case "--command": command = it.next()
        case "--arguments": programArguments = it.next() ?? ""
        case "--name": name = it.next()
        case "--lifecycle": lifecycle = true
        default: continue  // the common options (--tier, --request…), which `Options` reads
        }
    }
    // This voice-cli, quoted as one would type it.
    let fake = "'\(Bundle.main.executablePath ?? CommandLine.arguments[0])'"
    if lifecycle { return try await runProgramLifecycle(fake) }
    let program = ConnectedToolSettings.Program(command: command ?? fake,
                                                arguments: command == nil ? "fake-home-assistant" : programArguments)
    let toolName = name ?? (command == nil ? "Home Assistant" : "Programme")
    let launch = MCPProgram.launch(program)
    switch launch {
    case .success(let launch):
        print("program: \(launch.executable) \(launch.arguments.joined(separator: " "))")
        print("  in \(launch.directory), PATH=\(launch.environment["PATH"] ?? ""), environment: "
              + launch.environment.keys.sorted().joined(separator: " "))
    case .failure(let error):
        throw CLIError("the program cannot start: \(error)")
    }
    let client = MCPProgramClient(launch: launch, name: toolName)
    let clock = ContinuousClock()
    let listing = clock.now
    let tools = try await client.listTools()
    print("started, connected and listed: \(tools.count) actions in \(clock.now - listing) "
          + "(pid \(await client.processID.map(String.init) ?? "—"))")
    for tool in tools {
        print("  · \(tool.name)\(ConnectedTools.reads(tool) ? " (reads)" : ""): \(tool.description.prefix(90))")
    }
    var settings = ConnectedToolSettings(name: toolName, address: "", access: .none, program: program)
    settings.actions = settings.merging(tools)
    let provider = ConnectedTools()
    let log = ProgramLog()
    await provider.observe { report in Task { await log.add(report) } }
    await provider.configure([ConnectedTools.Connection(settings: settings, client: client)])

    let e = try await buildEngine(o, tools: ToolRunner(providers: [provider], actions: false))
    let mic = SimulatedMicrophone(pipeline: e.pipeline)
    func turn(_ text: String) async -> String {
        let lines = await log.entries.count
        await mic.silence(0.5)
        let before = await e.log.completedTurns
        await e.pipeline.submit(text: text)
        await waitForAnswer(e, mic: mic, after: before, timeout: 90)
        await mic.silence(0.3)
        let said = await e.log.turns.last?.assistantText ?? ""
        print("■ « \(text) »\n    Maé: \(said)")
        for line in await log.entries.dropFirst(lines) { print("    log: \(line.title) — \(line.result)") }
        return said
    }
    let requests = !o.requests.isEmpty ? o.requests
        : command == nil ? ["Allume le salon", "Est-ce que la lumière de la cuisine est allumée ?"] : []
    for request in requests {
        let said = await turn(request)
        if said.contains("On y va") { _ = await turn("Oui") }
    }
    let entries = await log.entries
    let done = entries.filter { $0.result == .done }.count
    print("\n=== \(done) of \(requests.count) requests carried out by the program (\(entries.count - done) other log lines) ===")

    let group = await client.processID
    let stopping = clock.now
    await client.stop()
    var left = group.map { kill(-$0, 0) == 0 } ?? false
    for _ in 0..<50 where left {
        try? await Task.sleep(for: .milliseconds(20))
        left = group.map { kill(-$0, 0) == 0 } ?? false
    }
    print("stopped in \(clock.now - stopping): "
          + (left ? "✗ something of its process group is still running" : "✓ nothing of it is left"))
}

/// --lifecycle (see the top of this file).
private func runProgramLifecycle(_ fake: String) async throws {
    // A word of its own in its arguments, so that its processes can be found (`pgrep -f`); the fake ignores it.
    let marker = "lifecycle-\(UUID().uuidString)"
    let folder = FileManager.default.temporaryDirectory.appending(path: "voice-cli-\(marker)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = AssistantHost(actionsTestCollection: "voice-cli", agentsTestFolder: folder)
    let tool = ConnectedToolSettings(name: "Home Assistant", address: "", access: .none,
                                     program: .init(command: fake, arguments: "fake-home-assistant \(marker)"))
    let connections = Connections()
    Task {
        for await event in host.events {
            if case .connectedToolState(tool.id, .connected) = event { await connections.add() }
            if case .connectedToolTested(tool.id, .failed(let error)) = event { print("  (the engine says: \(error))") }
        }
    }
    var settings = AssistantSettings()
    func set(_ tools: [ConnectedToolSettings]) {
        settings.connectedTools = tools
        host.send(.updateSettings(settings))
    }
    let clock = ContinuousClock()
    var checks: [(String, Bool)] = []
    func check(_ what: String, _ ok: Bool) {
        checks.append((what, ok))
        print("  \(ok ? "✓" : "✗") \(what)")
    }
    /// Waits until its processes are as wanted (some, or none): the time it took, nil after `seconds`.
    func until(running: Bool, seconds: Double = 8) async -> Duration? {
        let start = clock.now
        while clock.now - start < .seconds(seconds) {
            if processes(marker).isEmpty != running { return clock.now - start }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
    func turnOn(_ step: String) async {
        let before = await connections.count
        set([tool])
        let started = await until(running: true)
        var connected = false
        for _ in 0..<160 where !connected {
            connected = await connections.count > before
            if !connected { try? await Task.sleep(for: .milliseconds(50)) }
        }
        check("\(step): its program runs (pid \(processes(marker).map(String.init).joined(separator: ", "))), "
              + "connected" + (started.map { ", started in \($0)" } ?? ""), started != nil && connected)
    }

    print("=== a program on this Mac, as a connected tool of the engine ===")
    await turnOn("on")
    let first = processes(marker)
    for pid in first { kill(pid, SIGKILL) }
    let before = await connections.count
    var restarted: Duration?
    let killed = clock.now
    while clock.now - killed < .seconds(10), restarted == nil {
        if await connections.count > before { restarted = clock.now - killed }
        try? await Task.sleep(for: .milliseconds(50))
    }
    let second = processes(marker)
    check("killed: started again\(restarted.map { " \($0) later" } ?? ""), as pid \(second.map(String.init).joined(separator: ", "))",
          restarted != nil && !second.isEmpty && Set(second).isDisjoint(with: first))
    var off = tool
    off.enabled = false
    set([off])
    let stoppedOff = await until(running: false)
    check("turned off: no program left" + (stoppedOff.map { " (\($0))" } ?? ""), stoppedOff != nil)
    await turnOn("on again")
    set([])
    let stoppedRemoved = await until(running: false)
    check("removed: no program left" + (stoppedRemoved.map { " (\($0))" } ?? ""), stoppedRemoved != nil)
    await turnOn("added again")
    let quitting = clock.now
    AssistantHost.stopProgramsNow()
    let quitTook = clock.now - quitting
    let stoppedQuit = await until(running: false, seconds: 1)
    check("the app's quit: no program left (stopProgramsNow took \(quitTook))", stoppedQuit != nil)
    try? await Task.sleep(for: .seconds(2))
    check("2 s after the quit: none started again", processes(marker).isEmpty)
    let passed = checks.filter(\.1).count
    print("\n=== \(passed) of \(checks.count) checks passed ===")
    for (what, ok) in checks where !ok { print("✗ \(what)") }
}

/// The processes whose arguments hold `marker`.
private func processes(_ marker: String) -> [pid_t] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", marker]
    let output = Pipe()
    pgrep.standardOutput = output
    guard (try? pgrep.run()) != nil else { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    pgrep.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
}

/// Counts the times the engine said the program connected.
private actor Connections {
    var count = 0
    func add() { count += 1 }
}
