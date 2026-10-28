import Darwin
import Foundation
import Testing

@testable import VoiceCore

@Suite("Connected tools: a program on this Mac, its command")
struct MCPProgramTests {
    let home = "/Users/someone"

    @Test func readsACommandLineWithoutAShell() {
        #expect(MCPProgram.words("npx -y @modelcontextprotocol/server-filesystem", home: home)
            == ["npx", "-y", "@modelcontextprotocol/server-filesystem"])
        #expect(MCPProgram.words("  ~/Documents/Notes   \"/Volumes/My Disk/Notes\" ", home: home)
            == ["/Users/someone/Documents/Notes", "/Volumes/My Disk/Notes"])
        #expect(MCPProgram.words("~ a\\ b 'it'\"'\"'s' \"say \\\"hi\\\" \\n\" ''", home: home)
            == ["/Users/someone", "a b", "it's", "say \"hi\" \\n", ""])
        // Only a ~ that starts a word, unquoted, alone or before a /; nothing else is expanded.
        #expect(MCPProgram.words("'~/x' ~other/x a~/x $HOME *.txt a;b", home: home)
            == ["~/x", "~other/x", "a~/x", "$HOME", "*.txt", "a;b"])
        #expect(MCPProgram.words("", home: home) == [])
        #expect(MCPProgram.words("npx \"unclosed", home: home) == nil)
        #expect(MCPProgram.words("npx 'unclosed", home: home) == nil)
        #expect(MCPProgram.words("npx \\", home: home) == nil)
    }

    @Test func findsTheCommandWhereInstallersPutIt() {
        let folders = MCPProgram.folders(home: home, nvmVersions: ["v20.3.1", "v22.11.0", "v8.17.0", "system"])
        #expect(folders.first == "/Users/someone/.local/bin")
        #expect(folders.contains("/Users/someone/.nvm/versions/node/v22.11.0/bin"))
        #expect(!folders.contains { $0.contains("v20.3.1") })
        #expect(Array(folders.suffix(4)) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        func locate(_ command: String, among programs: Set<String>) -> String? {
            MCPProgram.locate(command, home: home, folders: folders, isProgram: programs.contains)
        }
        // Homebrew's before a version manager's, whose commands only work once it is set up.
        #expect(locate("npx", among: ["/Users/someone/.volta/bin/npx", "/opt/homebrew/bin/npx"]) == "/opt/homebrew/bin/npx")
        #expect(locate("npx", among: ["/Users/someone/.nvm/versions/node/v22.11.0/bin/npx"])
            == "/Users/someone/.nvm/versions/node/v22.11.0/bin/npx")
        #expect(locate("uvx", among: ["/Users/someone/.local/bin/uvx", "/opt/homebrew/bin/uvx"])
            == "/Users/someone/.local/bin/uvx")
        // A path is taken as typed (relative to the home folder), and only if it is a program.
        #expect(locate("/opt/tools/server", among: ["/opt/tools/server"]) == "/opt/tools/server")
        #expect(locate("bin/server", among: ["/Users/someone/bin/server"]) == "/Users/someone/bin/server")
        #expect(locate("/opt/tools/server", among: []) == nil)
        #expect(locate("npx", among: []) == nil)
    }

    @Test func itsEnvironmentIsBuiltFromScratch() {
        let environment = MCPProgram.environment(home: home, user: "someone", shell: "/bin/zsh", temporary: "/tmp/x",
                                                 locale: "fr_FR.UTF-8",
                                                 path: ["/opt/homebrew/bin", "/usr/bin", "/opt/homebrew/bin", "/bin"])
        #expect(environment == ["HOME": home, "USER": "someone", "LOGNAME": "someone", "SHELL": "/bin/zsh",
                                "TMPDIR": "/tmp/x", "LANG": "fr_FR.UTF-8", "PATH": "/opt/homebrew/bin:/usr/bin:/bin"])
    }

    #if os(macOS)
    @Test func startsOnThisMacWithNothingOfTheAppsEnvironment() throws {
        setenv("OPENMAE_TEST_SECRET", "a key the program must not see", 1)
        defer { unsetenv("OPENMAE_TEST_SECRET") }
        let launch = try MCPProgram.launch(.init(command: "sh -c", arguments: "'echo hi'")).get()
        #expect(launch.executable == "/bin/sh")
        #expect(launch.arguments == ["-c", "echo hi"])
        #expect(launch.directory == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(Set(launch.environment.keys) == ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH"])
        #expect(launch.environment["PATH"]?.hasPrefix("/bin:") == true)  // the command's folder first
        #expect(MCPProgram.launch(.init(command: "openmae-no-such-command")) == .failure(.notFound("openmae-no-such-command")))
        #expect(MCPProgram.launch(.init(command: "npx \"unclosed")) == .failure(.notFound("npx \"unclosed")))
    }
    #endif

    @Test func settingsOfAnEarlierVersionHaveNoProgram() throws {
        let earlier = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Home Assistant","#
            + #""address":"http://homeassistant.local:8123/api/mcp","access":"token","enabled":true,"#
            + #""whenActing":"askFirst","actions":[]}"#
        let tool = try JSONDecoder().decode(ConnectedToolSettings.self, from: Data(earlier.utf8))
        #expect(tool.program == nil)
        #expect(tool.address == "http://homeassistant.local:8123/api/mcp")
        let program = ConnectedToolSettings(name: "Notes", address: "", access: .none,
                                            program: .init(command: "npx -y @modelcontextprotocol/server-filesystem",
                                                           arguments: "~/Documents/Notes"))
        #expect(try JSONDecoder().decode(ConnectedToolSettings.self, from: JSONEncoder().encode(program)) == program)
    }
}

#if os(macOS)
/// A pretend MCP server in sh (nothing else to install): before answering `initialize` it sends a `ping` of its own and
/// wants its answer; it lists `echo` (it only reads) and `crash`; it says its list changed before answering a call; it
/// prints a banner and a log line that are not JSON-RPC on its output, and writes on its error output. `crash` ends it
/// with an error.
private let server = #"""
    echo "fake server: started" >&2
    echo "Fake MCP server 1.0, listening on standard input"
    while IFS= read -r line; do
      id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":"server-ping","method":"ping"}\n'
          IFS= read -r pong
          case "$pong" in
            *'"server-ping"'*) ;;
            *) echo "no answer to my ping: $pong" >&2; exit 2 ;;
          esac
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
        *'"method":"tools'*'list"'*)
          printf '{"level":"info","msg":"listing"}\n'
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Says it back","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"crash","description":"Ends the server"}]}}\n' "$id" ;;
        *'"name":"crash"'*)
          echo "Error: asked to crash" >&2
          exit 3 ;;
        *'"method":"tools'*'call"'*)
          text=$(printf '%s\n' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
          printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"echo: %s"}]}}\n' "$id" "$text" ;;
        *'"method":"notifications'*) ;;
        *) [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
      esac
    done
    echo "fake server: its input ended" >&2
    """#

/// Answers `initialize`, then reads nothing more and ignores SIGTERM: only SIGKILL ends it.
private let stubborn = #"""
    trap '' TERM
    IFS= read -r line
    id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}\n' "$id"
    while :; do sleep 0.2; done
    """#

/// A sh script as a program (run by /bin/sh, so that nothing needs to be made executable).
private func program(_ script: String, timeout: Duration = .seconds(5), startTimeout: Duration = .seconds(5),
                     grace: Duration = .milliseconds(300)) throws -> MCPProgramClient
{
    let folder = FileManager.default.temporaryDirectory.appending(path: "openmae-mcp-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "server.sh")
    try script.write(to: file, atomically: true, encoding: .utf8)
    let launch = MCPProgram.Launch(executable: "/bin/sh", arguments: [file.path],
                                   environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], directory: folder.path)
    return MCPProgramClient(launch: .success(launch), name: "test", timeout: timeout, startTimeout: startTimeout,
                            grace: grace, firstDelay: .milliseconds(200))
}

/// Whether anything of the process group runs.
private func runs(_ group: pid_t) -> Bool {
    kill(-group, 0) == 0
}

/// Waits until `condition` holds, at most `seconds`.
private func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private actor Statuses {
    var all: [MCPProgramClient.Status] = []
    func add(_ status: MCPProgramClient.Status) { all.append(status) }
    var running: Int { all.filter { $0 == .running }.count }
}

@Suite("Connected tools: a program on this Mac, spoken to over its standard input and output", .serialized)
struct MCPProgramClientTests {
    @Test func startsConnectsListsCallsAndStops() async throws {
        let client = try program(server)
        #expect(await client.processID == nil)  // not started before it is needed
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo", "crash"])
        #expect(tools.first?.readOnlyHint == true)
        let group = try #require(await client.processID)
        #expect(runs(group))
        #expect(await !client.toolsChanged)
        let result = try await client.call("echo", arguments: ["text": "bonjour"])
        #expect(result == MCPCallResult(text: "echo: bonjour", isError: false))
        #expect(await client.toolsChanged)  // said before its answer
        await client.stop()
        #expect(await client.processID == nil)
        #expect(await eventually(1) { !runs(group) })
        // Stopped for good: nothing starts it again.
        await #expect(throws: MCPError.ended("")) { try await client.listTools() }
        #expect(await client.processID == nil)
    }

    @Test func aProgramThatEndsSaysWhy() async throws {
        let failing = try program("""
            echo "node:internal/modules/cjs/loader:1228" >&2
            echo "Error: Cannot find module '/nowhere/index.js'" >&2
            echo "Node.js v26.12.1" >&2
            exit 1
            """)
        await #expect(throws: MCPError.ended("Error: Cannot find module '/nowhere/index.js'")) {
            try await failing.listTools()
        }
        let usage = try program("echo 'Usage: server <allowed-directory>'; exit 1")
        await #expect(throws: MCPError.ended("Usage: server <allowed-directory>")) { try await usage.listTools() }
        let silent = try program("exit 0")
        await #expect(throws: MCPError.ended("")) { try await silent.listTools() }
    }

    @Test func aCommandThatIsNotThere() async throws {
        let launch = MCPProgram.Launch(executable: "/nowhere/openmae-server", arguments: [], environment: [:],
                                       directory: "/")
        let client = MCPProgramClient(launch: .success(launch), name: "test")
        await #expect(throws: MCPError.notFound("openmae-server")) { try await client.listTools() }
        let notFound = MCPProgramClient(launch: .failure(.notFound("npx")), name: "test")
        await #expect(throws: MCPError.notFound("npx")) { try await notFound.call("echo", arguments: [:]) }
    }

    @Test func aProgramThatOnlyWritesSomethingElseIsNotAnMCPServer() async throws {
        let client = try program("echo 'Welcome to my tool!'; echo 'Type a command:'; sleep 30",
                                 startTimeout: .milliseconds(700))
        let start = ContinuousClock.now
        await #expect(throws: MCPError.notMCP("Welcome to my tool!")) { try await client.listTools() }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await client.processID == nil)  // ended, its `sleep` too
    }

    @Test func linesThatAreNotJSONRPCAreLeftAside() async throws {
        // The server's banner and its log line on its output (see `server`) did not stop it.
        let client = try program(server)
        defer { Task { await client.stop() } }
        #expect(try await client.listTools().count == 2)
        #expect(try await client.call("echo", arguments: ["text": "encore"]).text == "echo: encore")
    }

    @Test func aRequestItNeverAnswersTimesOut() async throws {
        let client = try program(stubborn, timeout: .milliseconds(500))
        let start = ContinuousClock.now
        await #expect(throws: MCPError.noAnswer) { try await client.listTools() }
        #expect(ContinuousClock.now - start < .seconds(3))
        await client.stop()
    }

    @Test func stopEndsAProgramThatIgnoresItsInputAndSIGTERM() async throws {
        let client = try program(stubborn, timeout: .milliseconds(300))
        await #expect(throws: MCPError.noAnswer) { try await client.listTools() }
        let group = try #require(await client.processID)
        let start = ContinuousClock.now
        await client.stop()
        // Its input closed, then SIGTERM, then SIGKILL, `grace` (0.3 s) apart.
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await eventually(1) { !runs(group) })
    }

    @Test func stopEndsWhatTheProgramStartedToo() async throws {
        // As `npx` starts the server's `node`: here a `sleep` of its own, which outlives it unless its group ends.
        let client = try program("sleep 300 &\n" + server)
        _ = try await client.listTools()
        let group = try #require(await client.processID)
        await client.stop()
        #expect(await eventually(1) { !runs(group) })
    }

    @Test func aCrashFailsTheRequestAndKeepRunningStartsItAgain() async throws {
        let client = try program(server)
        let statuses = Statuses()
        await client.keepRunning { status in Task { await statuses.add(status) } }
        #expect(await eventually { await statuses.running == 1 })
        let first = try #require(await client.processID)
        await #expect(throws: MCPError.ended("Error: asked to crash")) { try await client.call("crash", arguments: [:]) }
        // Started again after the first delay (0.2 s), without a word of failure.
        #expect(await eventually { await statuses.running == 2 })
        let second = try #require(await client.processID)
        #expect(second != first)
        #expect(await eventually(1) { !runs(first) })
        #expect(try await client.call("echo", arguments: ["text": "revenu"]).text == "echo: revenu")
        #expect(await statuses.all == [.running, .running])
        await client.stop()
        #expect(await eventually(1) { !runs(second) })
    }

    @Test func keepRunningSaysWhyItDoesNotStartAndTriesAgainLater() async throws {
        let client = try program("echo 'Error: no folder given' >&2; exit 1")
        let statuses = Statuses()
        await client.keepRunning { status in Task { await statuses.add(status) } }
        // 0.2 s, then 0.4 s, then 0.8 s between the tries: three tries within 1.5 s, not many more.
        #expect(await eventually { await statuses.all.count >= 3 })
        let tries = await statuses.all
        #expect(tries.allSatisfy { $0 == .failed(.ended("Error: no folder given")) })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await statuses.all.count <= 4)
        await client.stop()
        let stopped = await statuses.all.count
        try? await Task.sleep(for: .milliseconds(1000))
        #expect(await statuses.all.count == stopped)  // stopped: no more tries
    }
}
#endif
