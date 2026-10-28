import Foundation

/// How a connected tool that is a program on this Mac is started (MCPProgramClient.swift runs it): its command line read
/// without a shell, its command found where installers put it, and an environment built from scratch. An app opened
/// from the Finder does not get the terminal's PATH, so `npx`, `uvx` or `node` installed with Homebrew or a version
/// manager are not found by name; the user's shell is never run to find them, and its environment never read (it may
/// hold keys): the same as for Claude Code (ClaudeCode.swift).
public enum MCPProgram {
    /// What starts the program.
    public struct Launch: Sendable, Equatable {
        /// The command's full path.
        public var executable: String
        /// Its arguments, after the command itself.
        public var arguments: [String]
        public var environment: [String: String]
        /// Where it starts: the home folder, as a new terminal does.
        public var directory: String

        public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
        }
    }

    /// The words of a command line as a shell splits them, without a shell: blanks separate words; '…' keeps everything
    /// as typed; "…" keeps blanks (a backslash in it only keeps a ", \, $ or ` that follows); a backslash elsewhere keeps
    /// the next character; a ~ that starts a word, alone or before a /, is the home folder. Nothing else is expanded (no
    /// $VARIABLE, no *, no ; or |: they are part of the words). nil when a quote is not closed, or the line ends with a
    /// backslash.
    public static func words(_ text: String, home: String) -> [String]? {
        let characters = Array(text)
        var words: [String] = []
        var word = ""
        /// A word started (a '' is an empty word).
        var started = false
        /// The word starts with a ~ that was not quoted.
        var tilde = false
        func end() {
            if tilde, word == "~" || word.hasPrefix("~/") { word = home + word.dropFirst() }
            words.append(word)
            word = ""
            started = false
            tilde = false
        }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            switch c {
            case "'":
                guard let close = characters[(i + 1)...].firstIndex(of: "'") else { return nil }
                word += String(characters[(i + 1)..<close])
                i = close
            case "\"":
                i += 1
                while i < characters.count, characters[i] != "\"" {
                    if characters[i] == "\\", i + 1 < characters.count, "\"\\$`".contains(characters[i + 1]) { i += 1 }
                    word.append(characters[i])
                    i += 1
                }
                guard i < characters.count else { return nil }
            case "\\":
                guard i + 1 < characters.count else { return nil }
                i += 1
                word.append(characters[i])
            case _ where c.isWhitespace:
                if started { end() }
                i += 1
                continue
            default:
                if !started, c == "~" { tilde = true }
                word.append(c)
            }
            started = true
            i += 1
        }
        if started { end() }
        return words
    }

    /// The folders where a command is looked for, in this order: the user's own (~/.local/bin, where Claude Code, uv and
    /// pipx install), Homebrew's, /usr/local/bin, then the version managers' (Volta, mise, asdf, nodenv, fnm, the newest
    /// node of nvm's `nvmVersions`, Bun, Deno, Cargo, pyenv), MacPorts', OrbStack's, then the system's. A version manager
    /// comes after Homebrew: its commands only work once it is set up.
    public static func folders(home: String, nvmVersions: [String] = []) -> [String] {
        var folders = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin",
                       "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims", "\(home)/.nodenv/shims",
                       "\(home)/Library/Application Support/fnm/aliases/default/bin",
                       "\(home)/.local/share/fnm/aliases/default/bin"]
        if let newest = newest(nvmVersions) { folders.append("\(home)/.nvm/versions/node/\(newest)/bin") }
        folders += ["\(home)/.bun/bin", "\(home)/.deno/bin", "\(home)/.cargo/bin", "\(home)/.pyenv/shims", "/opt/local/bin",
                    "\(home)/.orbstack/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return folders
    }

    /// The newest of nvm's versions ("v22.11.0"), by their numbers.
    static func newest(_ versions: [String]) -> String? {
        func numbers(_ version: String) -> [Int] {
            version.drop { !$0.isNumber }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        return versions.filter { $0.first == "v" && $0.dropFirst().first?.isNumber == true }
            .max { numbers($0).lexicographicallyPrecedes(numbers($1)) }
    }

    /// The command's full path: as typed when it has a / (relative to the home folder when it does not start with one),
    /// otherwise in the first of `folders` that has it. nil when it is nowhere, or is not a program.
    public static func locate(_ command: String, home: String, folders: [String], isProgram: (String) -> Bool) -> String? {
        guard !command.isEmpty else { return nil }
        if command.contains("/") {
            let path = command.hasPrefix("/") ? command : "\(home)/\(command)"
            return isProgram(path) ? path : nil
        }
        return folders.lazy.map { "\($0)/\(command)" }.first(where: isProgram)
    }

    /// The program's environment, built from scratch rather than inherited from the app: the user's basics (home,
    /// account, shell, temporary folder, language) and `path`. Nothing else, so no key exported somewhere reaches it.
    public static func environment(home: String, user: String, shell: String, temporary: String, locale: String,
                                   path: [String]) -> [String: String]
    {
        var seen = Set<String>()
        return ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "TMPDIR": temporary, "LANG": locale,
                "PATH": path.filter { seen.insert($0).inserted }.joined(separator: ":")]
    }

    #if os(macOS)
    /// How to start the program of these settings on this Mac: its command found, its arguments read (the command's
    /// field can hold the first ones: "npx -y @modelcontextprotocol/server-filesystem"), its environment, with PATH
    /// made of the command's folder and the folders of `folders` this Mac has (`npx` finds the `node` next to it, a
    /// server finds `uvx` or `git`). `.notFound` when the command is not on this Mac, or the line cannot be read.
    public static func launch(_ program: ConnectedToolSettings.Program) -> Result<Launch, MCPError> {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let typed = program.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = words(typed, home: home), let rest = words(program.arguments, home: home),
              let command = first.first
        else { return .failure(.notFound(typed)) }
        let nvm = (try? files.contentsOfDirectory(atPath: "\(home)/.nvm/versions/node")) ?? []
        let folders = folders(home: home, nvmVersions: nvm)
        let isProgram = { (path: String) -> Bool in
            var folder: ObjCBool = false
            return files.fileExists(atPath: path, isDirectory: &folder) && !folder.boolValue
                && files.isExecutableFile(atPath: path)
        }
        guard let executable = locate(command, home: home, folders: folders, isProgram: isProgram) else {
            return .failure(.notFound(command))
        }
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let language = Locale.current.language
        let locale = [language.languageCode?.identifier, language.region?.identifier].compactMap { $0 }
            .joined(separator: "_")
        let path = [(executable as NSString).deletingLastPathComponent]
            + folders.filter { files.fileExists(atPath: $0) }
        let environment = Self.environment(home: home, user: NSUserName(), shell: shell,
                                           temporary: NSTemporaryDirectory(),
                                           locale: (locale.isEmpty ? "en_US" : locale) + ".UTF-8", path: path)
        return .success(Launch(executable: executable, arguments: Array(first.dropFirst()) + rest,
                               environment: environment, directory: home))
    }
    #endif
}
