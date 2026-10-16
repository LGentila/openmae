import Foundation
import VoiceCore

/// Runs the user's Apple Shortcuts. Only those in the "OpenMaé" folder of the Shortcuts app are offered: the
/// user decides what Maé may run by putting shortcuts there. A shortcut can be marked "ask first" in the
/// settings; Maé then reads what it is about to run and waits for a "oui".
public actor ShortcutTools: ToolProvider {
    public nonisolated let identifier = "shortcuts"
    /// The folder of the Shortcuts app whose shortcuts Maé may run.
    public static let folder = "OpenMaé"
    private static let command = "/usr/bin/shortcuts"

    public private(set) var names: [String] = []
    private var needingConfirmation: Set<String> = []

    public init() {}

    /// Reads the folder again; returns true when the list changed.
    @discardableResult
    public func refresh() async -> Bool {
        // `shortcuts list --folder-name` lists EVERY shortcut when the folder does not exist: check it first.
        let folders = await lines(["list", "--folders"])
        let folder = folders.first { $0 == Self.folder }
            ?? folders.first { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == "openmae" }
        let found = if let folder { await lines(["list", "--folder-name", folder]) } else { [String]() }
        guard found != names else { return false }
        DebugLog.log("shortcuts: \(found.count) in the \(Self.folder) folder")
        names = found
        return true
    }

    private func lines(_ arguments: [String]) async -> [String] {
        let result = await Subprocess.run(Self.command, arguments, timeout: .seconds(10))
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func setNeedingConfirmation(_ names: Set<String>) {
        needingConfirmation = names
    }

    public func tools() -> [ToolSpec] {
        ActionCatalog.runShortcut(names: names).map { [$0] } ?? []
    }

    public func risk(of call: ToolCall) -> ToolRisk {
        needingConfirmation.contains(call.text("nom") ?? "") ? .sensitive : .undoable
    }

    public func check(_ call: ToolCall, context: ToolContext) throws {
        try ActionCatalog.check(call, context: context, shortcuts: names)
    }

    public func summary(of call: ToolCall, context: ToolContext) -> String {
        ActionPhrases.confirmShortcut(name: call.text("nom") ?? "", context.language)
    }

    public func perform(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        let name = call.text("nom") ?? ""
        let folder = FileManager.default.temporaryDirectory.appending(path: "openmae-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputFile = folder.appending(path: "output.txt")
        var arguments = ["run", name, "--output-path", outputFile.path, "--output-type", "public.plain-text"]
        if let input = call.text("entree") {
            let inputFile = folder.appending(path: "input.txt")
            try input.write(to: inputFile, atomically: true, encoding: .utf8)
            arguments += ["--input-path", inputFile.path]
        }
        DebugLog.log("shortcuts: running “\(name)”")
        let result = await Subprocess.run(Self.command, arguments, timeout: .seconds(30))
        let cannotUndo = ActionPhrases.cannotUndoShortcut(context.language)
        if result.timedOut {
            return ToolOutcome(spoken: ActionPhrases.shortcutTimedOut(name: name, context.language),
                               forModel: ["erreur": "Le raccourci n'a pas répondu en 30 secondes."], cannotUndo: cannotUndo)
        }
        guard result.status == 0 else {
            DebugLog.log("shortcuts: “\(name)” failed (\(result.status)): \(result.errors)")
            return ToolOutcome(spoken: ActionPhrases.shortcutFailed(name: name, context.language),
                               forModel: ["erreur": .string(result.errors.isEmpty ? "échec" : result.errors)],
                               cannotUndo: cannotUndo)
        }
        let output = (try? String(contentsOf: outputFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolOutcome(spoken: ActionPhrases.shortcutDone(name: name, output: output, context.language),
                           forModel: ["raccourci": .string(name), "sortie": .string(String((output ?? "").prefix(500)))],
                           cannotUndo: cannotUndo)
    }
}

/// Runs a command-line tool and collects what it prints, with a time limit.
enum Subprocess {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var errors: String
        var timedOut = false
    }

    /// `environment`: nil to inherit the app's.
    static func run(_ path: String, _ arguments: [String], timeout: Duration,
                    environment: [String: String]? = nil) async -> Result
    {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let once = Once(continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                once.resume(Result(status: -1, output: "", errors: "\(error)"))
                return
            }
            let seconds = Double(timeout.components.seconds)
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard process.isRunning else { return }
                process.terminate()
                once.resume(Result(status: -1, output: "", errors: "", timedOut: true))
            }
            DispatchQueue.global().async {
                // Read before waiting: a full pipe would block the tool forever.
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                once.resume(Result(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
                                   errors: String(decoding: err, as: UTF8.self)
                                       .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// Resumes a continuation once, whoever comes first (the tool, or the time limit).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        init(_ continuation: CheckedContinuation<Result, Never>) { self.continuation = continuation }
        func resume(_ result: Result) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: result)
        }
    }
}
