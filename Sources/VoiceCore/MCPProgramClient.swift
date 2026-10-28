#if os(macOS)
import Darwin
import Foundation

/// Talks to one MCP server that is a program on this Mac, over its standard input and output (MCP's stdio transport):
/// one JSON-RPC message per line each way, what it writes on its error output to the debug log. Started without a shell,
/// as `MCPProgram.launch` says, in a process group of its own, so that ending it also ends the programs it started
/// (`npx` starts the server's own `node`).
///
/// A request starts it when it does not run, and connects (`initialize`, then `notifications/initialized`).
/// `keepRunning` keeps it running for as long as its tool is on: started at once, and after it ended, again after a delay
/// that grows while it keeps failing (1 s, 2 s, 4 s… up to 5 minutes; back to 1 s after a minute of running); a request
/// during the delay starts it at once. `stop` ends it for good, as the protocol says: its input closed, then SIGTERM to
/// its group after `grace`, then SIGKILL after `grace` again; and once it ended, whatever is left of its group goes the
/// same way. `stopAll` ends every program at once, when the app quits.
///
/// A line that is not JSON-RPC (a banner some servers print) is left aside; a program that only writes those is not an
/// MCP server. The server's own requests are answered: `ping`, and "not offered" to any other one (Maé offers no roots,
/// no sampling).
public actor MCPProgramClient: MCPConnection {
    /// Where the program stands, for `keepRunning`.
    public enum Status: Sendable, Equatable {
        /// It started and answered `initialize`.
        case running
        /// It could not start, ended before it answered, or did not answer: why.
        case failed(MCPError)
    }

    /// The longest line read: a longer one is left aside (the request it answered gets no answer).
    static let lineLimit = 16_000_000
    /// The longest delay before starting it again.
    static let longestDelay = Duration.seconds(300)
    /// A run that lasted this long was a good one: the next delay is the first one again.
    static let goodRun = Duration.seconds(60)

    private let launch: Result<MCPProgram.Launch, MCPError>
    private let label: String
    private let timeout: Duration
    private let startTimeout: Duration
    private let grace: Duration
    private let firstDelay: Duration
    /// Writes to its input in order, off the actor: a program that does not read its input would block the writer.
    private let writer = DispatchQueue(label: "openmae.mcp-program.input")

    // The run under way; none while `pid` is 0. `run` counts the starts: what an older run says is ignored.
    private var run = 0
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var ready = false
    private var startedAt = ContinuousClock.now
    private var starting: Task<Void, Error>?
    /// `stop` was called: it never starts again.
    private var closed = false
    /// Its output and its error output are still open: what it said last may still be on its way.
    private var outputsOpen = 0
    /// What the run said on its error output: its first lines, and its last one.
    private var errorLines: [String] = []
    private var lastErrorLine: String?
    /// The run's first line on its output that was not JSON-RPC (a banner, a usage line).
    private var otherLine: String?
    private var pending: [Int: (run: Int, answer: CheckedContinuation<JSONValue, Error>)] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextID = 1
    public private(set) var toolsChanged = false

    // keepRunning
    private var keeping = false
    private var report: @Sendable (Status) -> Void = { _ in }
    private var failures = 0
    private var restart: Task<Void, Never>?

    /// `launch`: `MCPProgram.launch` of its settings (a failure: it cannot start). `name`: in the debug log. `timeout`:
    /// for each request; `startTimeout`: for a start, `initialize` answered (`npx -y` downloads the server the first
    /// time). `grace`: what `stop` gives it at each step. `firstDelay`: before starting it again the first time.
    public init(launch: Result<MCPProgram.Launch, MCPError>, name: String, timeout: Duration = .seconds(15),
                startTimeout: Duration = .seconds(60), grace: Duration = .seconds(2), firstDelay: Duration = .seconds(1))
    {
        self.launch = launch
        label = name
        self.timeout = timeout
        self.startTimeout = startTimeout
        self.grace = grace
        self.firstDelay = firstDelay
    }

    /// The program's process while it runs (its group's id too).
    public var processID: pid_t? { pid == 0 ? nil : pid }

    /// Keeps it running until `stop`, and says how it goes: `.running` at each start that answered, `.failed` at each
    /// one that did not (a program that ended after it answered is started again without a word, unless that fails).
    public func keepRunning(_ report: @escaping @Sendable (Status) -> Void) {
        guard !closed else { return }
        keeping = true
        self.report = report
        Task { try? await self.connected() }
    }

    // MARK: - The protocol

    public func listTools() async throws -> [MCPTool] {
        try await connected()
        var tools: [MCPTool] = []
        var cursor: String?
        for _ in 0..<50 {
            let page = try MCPMessages.page(try await send("tools/list", cursor.map { ["cursor": .string($0)] } ?? [:]))
            tools += page.tools
            cursor = page.next
            if cursor == nil { break }
        }
        toolsChanged = false
        return tools
    }

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPCallResult {
        try await connected()
        return try MCPMessages.callResult(try await send("tools/call", ["name": .string(name),
                                                                        "arguments": .object(arguments)]))
    }

    /// Running and connected: started now when it is not (the start under way when there is one).
    private func connected() async throws {
        guard !closed else { throw MCPError.ended("") }
        if ready { return }
        if let starting { return try await starting.value }
        restart?.cancel()
        restart = nil
        let start = Task { try await self.startAndConnect() }
        starting = start
        try await start.value
    }

    private func startAndConnect() async throws {
        defer { starting = nil }
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            try spawn()
            _ = try MCPMessages.initialized(try await send("initialize", MCPMessages.initialize, timeout: startTimeout))
            try notify("notifications/initialized")
            ready = true
            DebugLog.log("mcp \(label): started (pid \(pid)), connected in \(clock.now - begin)")
            if keeping { report(.running) }
        } catch {
            var why = (error as? MCPError) ?? .ended("\(error)")
            // A program that only wrote something else than JSON-RPC does not speak MCP.
            if why == .noAnswer, let otherLine { why = .notMCP(otherLine) }
            DebugLog.log("mcp \(label): did not start: \(why)")
            if pid != 0 {
                let group = pid
                kill(-group, SIGTERM)
                if await !ended(run, within: grace) { kill(-group, SIGKILL) }
            }
            if keeping, !Self.runningGroups.isClosed {
                report(.failed(why))
                scheduleRestart()
            }
            throw why
        }
    }

    // MARK: - Stopping

    /// Ends it for good (see the top). Returns once it and its group ended.
    public func stop() async {
        closed = true
        keeping = false
        restart?.cancel()
        restart = nil
        guard pid != 0 else { return }
        let run = self.run
        let group = pid
        DebugLog.log("mcp \(label): stopping (pid \(group))")
        closeInput()
        if await !ended(run, within: grace) {
            kill(-group, SIGTERM)
            if await !ended(run, within: grace) {
                kill(-group, SIGKILL)
                _ = await ended(run, within: grace)
            }
        }
        await Self.endGroup(group, grace: grace)
    }

    /// Ends every program at once (synchronous, from the app's last moments): SIGTERM to their groups, then SIGKILL to
    /// what is left after half a second. None starts afterwards.
    public static func stopAll() {
        let groups = runningGroups.close()
        guard !groups.isEmpty else { return }
        for group in groups { kill(-group, SIGTERM) }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, groups.contains(where: { kill(-$0, 0) == 0 }) { usleep(20_000) }
        for group in groups { kill(-group, SIGKILL) }
    }

    /// Whether the run ended within `duration`.
    private func ended(_ run: Int, within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while self.run == run, pid != 0 {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// What is left of a group whose first program ended (a server `npx` started): SIGTERM, then SIGKILL after `grace`.
    private static func endGroup(_ group: pid_t, grace: Duration) async {
        guard kill(-group, SIGTERM) == 0 else { return }  // nothing left
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            if kill(-group, 0) != 0 { return }
        }
        kill(-group, SIGKILL)
    }

    private func scheduleRestart() {
        guard keeping, restart == nil, !Self.runningGroups.isClosed else { return }  // not once the app quits
        failures += 1
        let delay = min(firstDelay * (1 << min(failures - 1, 16)), Self.longestDelay)
        DebugLog.log("mcp \(label): starting it again in \(delay)")
        restart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.restartNow()
        }
    }

    private func restartNow() async {
        restart = nil
        try? await connected()
    }

    // MARK: - The process

    private func spawn() throws {
        let launch = try launch.get()
        // Stopped while its start waited for its turn, or the app quits.
        guard !closed, !Self.runningGroups.isClosed else { throw MCPError.ended("") }
        let started: (pid: pid_t, input: Int32, output: Int32, errors: Int32)
        do {
            started = try Self.spawn(launch)
        } catch MCPError.notFound {
            throw MCPError.notFound((launch.executable as NSString).lastPathComponent)
        }
        run += 1
        pid = started.pid
        input = started.input
        ready = false
        startedAt = .now
        outputsOpen = 2
        errorLines = []
        lastErrorLine = nil
        otherLine = nil
        if !Self.runningGroups.add(started.pid) { kill(-started.pid, SIGKILL) }  // the app quits
        readOutput(started.output, run: run)
        readErrors(started.errors, run: run)
        watchExit(started.pid, run: run)
    }

    /// Starts the program in a new process group, its standard input, output and error output on pipes (the app's ends
    /// closed in any other program it starts), with every signal as by default and nothing else of the app's.
    private static func spawn(_ launch: MCPProgram.Launch) throws -> (pid: pid_t, input: Int32, output: Int32,
                                                                       errors: Int32)
    {
        var ends = [Int32](repeating: -1, count: 6)  // input (read, write), output (read, write), errors (read, write)
        for i in stride(from: 0, to: 6, by: 2) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else {
                let why = String(cString: strerror(errno))
                ends.filter { $0 >= 0 }.forEach { close($0) }
                throw MCPError.ended(why)
            }
            ends[i] = pair[0]
            ends[i + 1] = pair[1]
        }
        let (childInput, input, output, childOutput, errors, childErrors) = (ends[0], ends[1], ends[2], ends[3], ends[4],
                                                                             ends[5])
        for end in [input, output, errors] { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input, F_SETNOSIGPIPE, 1)  // a write after it ended fails instead of ending the app
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, childInput, 0)
        posix_spawn_file_actions_adddup2(&actions, childOutput, 1)
        posix_spawn_file_actions_adddup2(&actions, childErrors, 2)
        posix_spawn_file_actions_addchdir_np(&actions, launch.directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                                        | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        sigdelset(&allSignals, SIGKILL)
        sigdelset(&allSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        let argv = ([launch.executable] + launch.arguments).map { strdup($0) } + [nil]
        let envp = launch.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, launch.executable, &actions, &attributes, argv, envp)
        for end in [childInput, childOutput, childErrors] { close(end) }
        guard result == 0 else {
            for end in [input, output, errors] { close(end) }
            throw result == ENOENT ? MCPError.notFound(launch.executable) : MCPError.ended(String(cString: strerror(result)))
        }
        return (pid, input, output, errors)
    }

    private nonisolated func readOutput(_ end: Int32, run: Int) {
        let lines = Self.lines(of: end)
        Task.detached { [weak self] in
            for await line in lines { await self?.received(line, run: run) }
            await self?.outputClosed(run: run)
        }
    }

    private nonisolated func readErrors(_ end: Int32, run: Int) {
        let lines = Self.lines(of: end)
        let label = label
        Task.detached { [weak self] in
            for await line in lines {
                let text = String(decoding: line, as: UTF8.self)
                DebugLog.log("mcp \(label): \(text)")
                await self?.said(text, run: run)
            }
            await self?.outputClosed(run: run)
        }
    }

    /// The lines `end` gives (without their line feed) until it ends, read on a thread of its own: a read waits, and
    /// must not hold one of the few threads Swift's tasks share (two programs' outputs, waiting, stalled the tests). A
    /// line longer than `lineLimit` is left aside.
    private nonisolated static func lines(of end: Int32) -> AsyncStream<Data> {
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var line = Data()
            var tooLong = false
            while true {
                let count = read(end, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                var start = 0
                while let newline = buffer[start..<count].firstIndex(of: 0x0A) {
                    if !tooLong {
                        line.append(contentsOf: buffer[start..<newline])
                        if line.count <= lineLimit { continuation.yield(line) }
                    }
                    line.removeAll(keepingCapacity: true)
                    tooLong = false
                    start = newline + 1
                }
                if !tooLong { line.append(contentsOf: buffer[start..<count]) }
                if line.count > lineLimit, !tooLong {
                    tooLong = true
                    line = Data()
                    DebugLog.log("mcp: a line longer than \(lineLimit) bytes was left aside")
                }
            }
            if !line.isEmpty, !tooLong { continuation.yield(line) }
            close(end)
            continuation.finish()
        }
        return lines
    }

    /// Waits for the program's end (and reaps it), off the actor.
    private nonisolated func watchExit(_ pid: pid_t, run: Int) {
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            Task { await self?.exited(pid, status: status, run: run) }
        }
    }

    private func exited(_ group: pid_t, status: Int32, run: Int) async {
        Self.runningGroups.remove(group)
        let grace = grace
        Task.detached { await Self.endGroup(group, grace: grace) }
        guard run == self.run, pid != 0 else { return }
        let lasted = ContinuousClock.now - startedAt
        pid = 0
        ready = false
        closeInput()
        let exit = (status & 0x7f) == 0 ? "status \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
        DebugLog.log("mcp \(label): ended (\(exit)) after \(lasted)")
        // Its last words may still be on their way (a program it started may also keep them open: not for long).
        for _ in 0..<25 where outputsOpen > 0 && run == self.run { try? await Task.sleep(for: .milliseconds(20)) }
        let why = MCPError.ended(lastWords)
        for (id, request) in pending where request.run == run { fail(id, with: why) }
        guard keeping, starting == nil else { return }  // a start under way says it failed itself
        if lasted >= Self.goodRun { failures = 0 }
        scheduleRestart()
    }

    /// What the run said that tells why it ended: on its error output, its first line about an error (Node's and
    /// Python's last lines are their version or the stack's end), else its last one; else its first line on its output
    /// that was not JSON-RPC (a usage line); "" when it said nothing.
    private var lastWords: String {
        let line = errorLines.first { $0.localizedCaseInsensitiveContains("error") } ?? lastErrorLine ?? otherLine ?? ""
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    private func said(_ line: String, run: Int) {
        guard run == self.run else { return }
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if errorLines.count < 20 { errorLines.append(line) }
        lastErrorLine = line
    }

    private func outputClosed(run: Int) {
        if run == self.run { outputsOpen -= 1 }
    }

    private func closeInput() {
        guard input >= 0 else { return }
        let end = input
        input = -1
        writer.async { close(end) }  // after the lines already on their way
    }

    // MARK: - JSON-RPC, one message per line

    /// Sends a request and gives its result, within `timeout`.
    private func send(_ method: String, _ params: [String: JSONValue], timeout: Duration? = nil) async throws -> JSONValue {
        guard pid != 0, input >= 0 else { throw MCPError.ended(lastWords) }
        let id = nextID
        nextID += 1
        let line = try Self.line(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": .object(params)])
        let run = self.run
        let timeout = timeout ?? self.timeout
        return try await withCheckedThrowingContinuation { answer in
            pending[id] = (run, answer)
            timers[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.fail(id, with: .noAnswer)
            }
            write(line)
        }
    }

    private func notify(_ method: String) throws {
        write(try Self.line(["jsonrpc": "2.0", "method": .string(method)]))
    }

    private func write(_ line: Data) {
        guard input >= 0 else { return }
        let end = input
        let label = label
        writer.async {
            var offset = 0
            let complete = line.withUnsafeBytes { bytes -> Bool in
                while offset < bytes.count {
                    let written = Darwin.write(end, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            // It closed its input, or ended: its end is reported by `exited`.
            if !complete { DebugLog.log("mcp \(label): could not write to it (\(String(cString: strerror(errno))))") }
        }
    }

    /// A message as one line: JSON never holds a line break of its own (they are written \n in strings).
    private static func line(_ message: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    private func fail(_ id: Int, with error: MCPError) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.answer.resume(throwing: error)
    }

    /// One line of its output: answers, its own requests and notifications, or something else (left aside).
    private func received(_ line: Data, run: Int) {
        guard run == self.run else { return }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else { return other(line) }
        let messages: [JSONValue] = if case .array(let batch) = value { batch } else { [value] }
        for message in messages {
            guard case .object(let object) = message else { return other(line) }
            if let method = object["method"]?.text {
                if let id = object["id"] {
                    // Its request: only `ping` is offered.
                    let reply: JSONValue = method == "ping" ? ["jsonrpc": "2.0", "id": id, "result": .object([:])]
                        : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
                    if let line = try? Self.line(reply) { write(line) }
                } else if method == "notifications/tools/list_changed" {
                    toolsChanged = true
                } else if method == "notifications/message", let params = object["params"] {
                    DebugLog.log("mcp \(label) says: \(params)")
                }
            } else if let id = object["id"]?.integer, object["result"] != nil || object["error"] != nil {
                timers.removeValue(forKey: id)?.cancel()
                guard let request = pending.removeValue(forKey: id) else { continue }  // too late: it timed out
                if case .object(let error)? = object["error"] {
                    request.answer.resume(throwing: MCPError.refused(error["message"]?.text
                            ?? "error \(error["code"]?.text ?? "")"))
                } else {
                    request.answer.resume(returning: object["result"] ?? .null)
                }
            } else {
                other(line)
            }
        }
    }

    private func other(_ line: Data) {
        let text = String(decoding: line.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        DebugLog.log("mcp \(label), not JSON-RPC: \(text)")
        if otherLine == nil { otherLine = text.count > 200 ? String(text.prefix(199)) + "…" : text }
    }

    // MARK: - Every program, for the app's last moments

    private static let runningGroups = ProcessGroups()

    /// The groups of the programs that run, safe to reach from any thread (the app's last moments included).
    private final class ProcessGroups: @unchecked Sendable {
        private let lock = NSLock()
        private var groups = Set<pid_t>()
        private var closed = false

        var isClosed: Bool { lock.withLock { closed } }

        /// false once closed: the app quits.
        func add(_ group: pid_t) -> Bool {
            lock.withLock {
                if !closed { groups.insert(group) }
                return !closed
            }
        }

        func remove(_ group: pid_t) {
            _ = lock.withLock { groups.remove(group) }
        }

        /// No group is added afterwards; the ones that run.
        func close() -> Set<pid_t> {
            lock.withLock {
                closed = true
                return groups
            }
        }
    }
}
#endif
