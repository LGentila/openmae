import Foundation

/// Claude Code as OpenMaé runs it: `claude -p --output-format stream-json --verbose …` in the task's folder, with an
/// environment built by hand, its reports read line by line. What needs no process is here — the arguments, the
/// environment, reading the reports — so it is unit-tested; the process itself is VoiceEngineApple's
/// (ClaudeCodeConnector.swift).
///
/// The command is the official one, unmodified, signed in by the user themselves in a terminal (their subscription):
/// OpenMaé never reads its credentials. In print mode Claude Code does not wait for permissions: what its permission
/// mode does not allow is refused at once and listed at the end (`permission_denials`), which is what we report.
public enum ClaudeCode {
    public static let agentID = "claude-code"
    public static let displayName = "Claude Code"

    /// Where its official installer and Homebrew put the command. An app opened from the Finder does not get the
    /// terminal's PATH, and a login shell is never used to look for it.
    public static func candidates(home: String) -> [String] {
        ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// A run's arguments: the task's instruction in a new session, or a follow-up that resumes the task's session.
    public static func arguments(prompt: String, session: String, resume: Bool,
                                 permissionMode: AgentSettings.PermissionMode) -> [String]
    {
        ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", permissionMode.rawValue]
            + (resume ? ["--resume", session] : ["--session-id", session])
            + ["--", prompt]  // after "--", an instruction that starts with "-" is not taken for an option
    }

    /// A run's environment, built from scratch rather than inherited from the app: the user's own basics and a
    /// standard PATH with the command's folder. Never ANTHROPIC_API_KEY: a key exported somewhere would be billed
    /// instead of the user's subscription.
    public static func environment(home: String, user: String, shell: String, temporary: String, locale: String,
                                   commandFolder: String) -> [String: String]
    {
        var seen = Set<String>()
        let path = [commandFolder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .filter { seen.insert($0).inserted }
        return ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "TMPDIR": temporary, "LANG": locale,
                "PATH": path.joined(separator: ":")]
    }

    /// "2.1.206 (Claude Code)" → "2.1.206".
    public static func version(fromOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first.map(String.init).flatMap { $0.first?.isNumber == true ? $0 : nil }
    }

    /// Whether `claude auth status --json` says it is signed in; nil when the output cannot be read.
    public static func signedIn(fromStatus output: String) -> Bool? {
        guard let status = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) else { return nil }
        return status["loggedIn"]?.boolean
    }

    /// Reads a run's reports (`--output-format stream-json`), one JSON object per line.
    public struct Reader: Sendable {
        public init() {}

        /// What a line tells; nothing for the lines that change nothing (hooks, rate limits, the agent's thinking,
        /// its intermediate remarks, the tools' results).
        public mutating func read(_ line: String) -> [AgentUpdate] {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return [] }
            switch (event["type"]?.text, event["subtype"]?.text) {
            case ("system", "init"):
                return event["session_id"]?.text.map { [.session($0)] } ?? []
            case ("assistant", _):
                return (event["message"]?["content"]?.array ?? []).compactMap { block in
                    guard block["type"]?.text == "tool_use", let tool = block["name"]?.text else { return nil }
                    return ClaudeCode.step(tool: tool, input: block["input"]).map(AgentUpdate.step)
                }
            case ("result", let subtype):
                return [.result(ClaudeCode.result(event, subtype: subtype))]
            default:
                return []
            }
        }
    }

    static func result(_ event: JSONValue, subtype: String?) -> AgentResult {
        let text = event["result"]?.text ?? ""
        let failed = event["is_error"]?.boolean == true || (subtype != nil && subtype != "success")
        var failure: AgentTask.Failure?
        if failed {
            let lowered = text.lowercased()
            let signedOut = ["/login", "not logged in", "invalid api key", "oauth token"].contains { lowered.contains($0) }
            failure = signedOut ? .notLoggedIn : .agent(text.isEmpty ? (subtype ?? "error") : text)
        }
        let denials = (event["permission_denials"]?.array ?? []).compactMap { denial -> String? in
            guard let tool = denial["tool_name"]?.text else { return nil }
            return describeDenied(tool: tool, input: denial["tool_input"])
        }
        var unique: [String] = []
        for denial in denials where !unique.contains(denial) { unique.append(denial) }
        return AgentResult(text: text, failure: failure, costUSD: event["total_cost_usd"]?.number,
                           permissionDenials: unique)
    }

    /// What a tool call shows of the agent's work.
    static func step(tool: String, input: JSONValue?) -> AgentStep? {
        let file = (input?["file_path"]?.text ?? input?["notebook_path"]?.text).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Write": return file.map(AgentStep.creates)
        case "Edit", "MultiEdit", "NotebookEdit": return file.map(AgentStep.edits)
        case "Read": return file.map(AgentStep.reads)
        case "Bash": return .runsCommand
        case "Glob", "Grep", "LS": return .searchesFiles
        case "WebFetch", "WebSearch": return .browsesWeb
        case "TodoWrite":
            // Its to-do list: the item in progress, in its own words.
            let current = input?["todos"]?.array?.first { $0["status"]?.text == "in_progress" }
            return (current?["activeForm"]?.text ?? current?["content"]?.text).map(AgentStep.step)
        case "TaskUpdate" where input?["status"]?.text == "in_progress":
            return (input?["activeForm"]?.text ?? input?["subject"]?.text).map(AgentStep.step)
        default:
            return nil
        }
    }

    /// What the agent was not allowed to do, in a few words: the command, the file, the page.
    static func describeDenied(tool: String, input: JSONValue?) -> String {
        switch tool {
        case "Bash":
            return input?["command"]?.text.map { String($0.prefix(80)) } ?? tool
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return (input?["file_path"]?.text ?? input?["notebook_path"]?.text)
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? tool
        case "WebFetch":
            return input?["url"]?.text.flatMap { URL(string: $0)?.host } ?? tool
        case "WebSearch":
            return input?["query"]?.text ?? tool
        default:
            return tool
        }
    }
}

extension JSONValue {
    /// An object's member.
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
