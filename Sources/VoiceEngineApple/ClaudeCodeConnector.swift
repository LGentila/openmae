import Darwin
import Foundation
import VoiceCore

/// Runs Claude Code for the tasks handed to it: one process per run, in the task's folder, its reports read as
/// they come (the arguments, the environment and the reading are in VoiceCore's ClaudeCode.swift). Quitting
/// OpenMaé stops the runs (`stopAll`).
public actor ClaudeCodeConnector: AgentConnector {
    public nonisolated let agentID = ClaudeCode.agentID
    public nonisolated let displayName = ClaudeCode.displayName
    private nonisolated let permissionMode: AgentSettings.PermissionMode

    /// The runs in progress, by task, whichever connector started them (the settings may have replaced it since).
    private static let processes = ProcessRegistry()

    public init(permissionMode: AgentSettings.PermissionMode = .acceptEdits) {
        self.permissionMode = permissionMode
    }

    /// The command, where the official installer or Homebrew put it; nil when Claude Code is not installed.
    public static func command() -> URL? {
        ClaudeCode.candidates(home: FileManager.default.homeDirectoryForCurrentUser.path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func availability() async -> AgentAvailability {
        guard let command = Self.command() else { return .notInstalled }
        let environment = Self.environment(for: command)
        let version = await Subprocess.run(command.path, ["--version"], timeout: .seconds(10), environment: environment)
        // Asked of the command itself: OpenMaé never looks at its credentials.
        let status = await Subprocess.run(command.path, ["auth", "status", "--json"], timeout: .seconds(15),
                                          environment: environment)
        // An answer that cannot be read (another version): the run will tell.
        if ClaudeCode.signedIn(fromStatus: status.output) == false { return .notLoggedIn }
        return .ready(version: ClaudeCode.version(fromOutput: version.output))
    }

    public nonisolated func start(_ task: AgentTask) -> AsyncThrowingStream<AgentUpdate, Error> {
        run(task, prompt: task.instruction, resume: false)
    }

    public nonisolated func followUp(_ task: AgentTask, message: String) -> AsyncThrowingStream<AgentUpdate, Error> {
        run(task, prompt: message, resume: true)
    }

    /// Like Ctrl-C in a terminal, then SIGTERM if it is still there after 5 seconds.
    public func cancel(_ task: AgentTask) async {
        guard let process = Self.processes.process(for: task.id), process.isRunning else { return }
        process.interrupt()
        for _ in 0..<50 {
            guard process.isRunning else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
    }

    /// The app is quitting: every run stops (synchronous, from the app's last moments).
    public static func stopAll() {
        processes.terminateAll()
    }

    public enum LaunchError: Error, CustomStringConvertible {
        case notInstalled, noFolder

        public var description: String {
            switch self {
            case .notInstalled: "Claude Code is not installed"
            case .noFolder: "the task has no folder"
            }
        }
    }

    private nonisolated func run(_ task: AgentTask, prompt: String, resume: Bool) -> AsyncThrowingStream<AgentUpdate, Error> {
        let permissionMode = permissionMode
        return AsyncThrowingStream { continuation in
            guard let command = Self.command() else { return continuation.finish(throwing: LaunchError.notInstalled) }
            guard let folder = task.folder else { return continuation.finish(throwing: LaunchError.noFolder) }
            let session = resume ? (task.externalRef ?? task.id.uuidString.lowercased()) : task.id.uuidString.lowercased()
            let process = Process()
            process.executableURL = command
            process.arguments = ClaudeCode.arguments(prompt: prompt, session: session, resume: resume,
                                                     permissionMode: permissionMode)
            process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
            process.environment = Self.environment(for: command)
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let (exits, exited) = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { process in
                exited.yield(process.terminationStatus)
                exited.finish()
            }
            do {
                try process.run()
            } catch {
                return continuation.finish(throwing: error)
            }
            Self.processes.add(process, for: task.id)
            DebugLog.log("claude: \(task.reference) started (pid \(process.processIdentifier), \(resume ? "follow-up" : "new session"))")
            // Each pipe on a thread of its own (PipeLines): read with FileHandle.bytes next to the error output, which
            // stays open and silent, the reports only came when the run ended.
            let reports = PipeLines.lines(of: output.fileHandleForReading)
            let errorLines = PipeLines.lines(of: errors.fileHandleForReading)
            // Its error output only goes to the debug log, but it must be read: a full pipe would block it.
            Task.detached {
                for await line in errorLines where !line.isEmpty {
                    DebugLog.log("claude: \(String(decoding: line, as: UTF8.self))")
                }
            }
            Task.detached {
                var reader = ClaudeCode.Reader()
                for await line in reports {
                    for update in reader.read(String(decoding: line, as: UTF8.self)) { continuation.yield(update) }
                }
                for await status in exits { DebugLog.log("claude: \(task.reference) ended (status \(status))") }
                Self.processes.remove(task.id)
                continuation.finish()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination, process.isRunning { process.terminate() }
            }
        }
    }

    /// The user's basics (home, account, shell, language), not the app's own environment.
    private static func environment(for command: URL) -> [String: String] {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let language = Locale.current.language
        let locale = [language.languageCode?.identifier, language.region?.identifier].compactMap { $0 }
            .joined(separator: "_")
        return ClaudeCode.environment(
            home: FileManager.default.homeDirectoryForCurrentUser.path, user: NSUserName(), shell: shell,
            temporary: NSTemporaryDirectory(), locale: (locale.isEmpty ? "en_US" : locale) + ".UTF-8",
            commandFolder: command.deletingLastPathComponent().path)
    }
}

/// The processes in progress, safe to reach from any thread (the app's last moments included).
private final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    func add(_ process: Process, for id: UUID) {
        lock.withLock { processes[id] = process }
    }

    func remove(_ id: UUID) {
        lock.withLock { processes[id] = nil }
    }

    func process(for id: UUID) -> Process? {
        lock.withLock { processes[id] }
    }

    func terminateAll() {
        let running = lock.withLock { Array(processes.values) }
        for process in running where process.isRunning { process.terminate() }
    }
}
