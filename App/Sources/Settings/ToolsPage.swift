import SwiftUI
import VoiceCore
import VoiceEngineApple

// Settings › Connected tools (MCP): services Maé can ask for actions (turn on a light, add a task, search notes),
// several at once, reached at their address or started on this Mac. `ConnectedToolsAccess` turns the settings' connected
// tools and what the engine reports (states, tests, logs) into what the pages show, and carries out what they change.
// Signing in with an account (OAuth) is not built yet: shown greyed, "Soon".

/// A connected tool, as the settings show it.
struct ConnectedTool: Identifiable, Equatable {
    /// Where it runs, as its list says it.
    enum Place: Equatable { case home, thisMac, internet }

    /// How it is reached.
    enum Connection: Equatable {
        /// A service on the network or on the internet, at an address.
        case service(address: String, access: Access)
        /// A program this Mac starts.
        case program(command: String, arguments: String)
    }

    enum Access: Hashable, CaseIterable { case account, token, none }

    enum State: Equatable {
        case connected
        case needsReconnect
        case paused
        case unreachable
    }

    /// What Maé does before an action that changes something.
    enum WhenActing: Hashable { case askFirst, doDirectly }

    struct Action: Identifiable, Equatable {
        /// The server's name for it: `HassTurnOn`.
        var id: String
        var title: String
        /// Reads something (true) or changes something (false).
        var reads: Bool
        var enabled = true
    }

    struct LogEntry: Identifiable, Equatable {
        enum Result: Equatable {
            case done
            case refusedByUser
            case failed(String)
        }

        var id = UUID().uuidString
        var date: Date
        var title: String
        var result: Result
    }

    enum Test: Equatable {
        case works(actions: Int, seconds: Double)
        case noAnswer
        case failed(String)
    }

    var id = UUID()
    var name: String
    var icon: Icon
    var color: RGBA
    var place: Place
    var connection: Connection
    var state = State.connected
    var enabled = true
    var whenActing = WhenActing.askFirst
    var actions: [Action] = []
    var log: [LogEntry] = []
    var lastTest: Test?
    /// A word about its access, when it has one: "Only Home Assistant administrator accounts can connect."
    var accessNote: String?
}

/// The connected tools, as the settings show them; see the top of this file.
@MainActor
@Observable
final class ConnectedToolsAccess {
    /// The sidebar entry and the quick panel's line are greyed while false.
    static let isAvailable = true

    /// nil for the still pictures of the screens, which show `shown`.
    @ObservationIgnored private let model: AssistantModel?
    private let shown: [ConnectedTool]
    /// The tools whose test is under way.
    private(set) var testing: Set<ConnectedTool.ID> = []
    /// What the last trial of a draft found, by the draft's trial id.
    @ObservationIgnored private var trialTools: [UUID: [MCPTool]] = [:]

    init(model: AssistantModel) {
        self.model = model
        shown = []
    }

    /// The still pictures: these tools, nothing wired.
    init(tools: [ConnectedTool] = []) {
        model = nil
        shown = tools
    }

    var tools: [ConnectedTool] {
        guard let model else { return shown }
        return model.settings.connectedTools.enumerated().map { Self.shown($1, index: $0, model: model) }
    }

    func tool(_ id: ConnectedTool.ID) -> ConnectedTool? {
        tools.first { $0.id == id }
    }

    /// A change made in the settings: its switch, "When she acts", an action's switch. The engine starts a new
    /// conversation with the new tools.
    func update(_ tool: ConnectedTool) {
        guard let model, let i = model.settings.connectedTools.firstIndex(where: { $0.id == tool.id }) else { return }
        var settings = model.settings.connectedTools[i]
        settings.enabled = tool.enabled
        settings.whenActing = tool.whenActing == .askFirst ? .askFirst : .doDirectly
        for action in tool.actions {
            if let a = settings.actions.firstIndex(where: { $0.name == action.id }) { settings.actions[a].enabled = action.enabled }
        }
        if settings != model.settings.connectedTools[i] { model.settings.connectedTools[i] = settings }
    }

    /// "Test", "Try again": connects again and lists its actions (kept in the settings).
    func test(_ id: ConnectedTool.ID) {
        guard let model, let settings = model.settings.connectedTools.first(where: { $0.id == id }), !testing.contains(id)
        else { return }
        testing.insert(id)
        Task {
            _ = await model.testConnectedTool(settings)
            testing.remove(id)
        }
    }

    /// Removes the tool, its token and its log.
    func remove(_ id: ConnectedTool.ID) {
        guard let model else { return }
        model.settings.connectedTools.removeAll { $0.id == id }
        ConnectedToolsKeychain.setToken(nil, for: id)
        model.forgetConnectedTool(id)
    }

    /// What "Add a tool" asks for, or "Change…" of a tool's connection.
    struct Draft: Equatable {
        enum Kind: Equatable { case service, program }

        /// The tool's id once added; the tool changed, for "Change…".
        var id = UUID()
        /// Where the token of a trial is kept until the tool is added or saved (the tool's own id for a new tool).
        var trialID: UUID
        var kind = Kind.service
        var name = ""
        var address = ""
        var access = ConnectedTool.Access.token
        /// Typed in the sheet; empty for "Change…" keeps the saved one. Goes to the keychain, never to the settings.
        var token = ""
        var command = ""
        var arguments = ""
        /// "Change…": the tool's connection, not a new tool.
        var changes = false

        init() {
            trialID = id
        }

        /// "Change…" of this tool.
        init(changing tool: ConnectedToolSettings) {
            id = tool.id
            trialID = UUID()
            name = tool.name
            address = tool.address
            access = ConnectedToolsAccess.shown(tool.access)
            if let program = tool.program {
                kind = .program
                command = program.command
                arguments = program.arguments
            }
            changes = true
        }

        /// The program it starts, as typed.
        var program: ConnectedToolSettings.Program {
            .init(command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                  arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// What the test of a new tool found.
    enum Trial: Equatable {
        case connected(actions: Int)
        case failed(String)
    }

    func draft(changing id: ConnectedTool.ID) -> Draft? {
        model?.settings.connectedTools.first { $0.id == id }.map(Draft.init(changing:))
    }

    /// Connects to the tool of a draft, to see what it offers: a program on this Mac is started, then stopped.
    func trial(_ draft: Draft) async -> Trial {
        guard let model else { return .failed(String(localized: "Connected tools are not available yet.")) }
        if draft.kind == .program {
            let program = draft.program
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard MCPProgram.words(program.command, home: home) != nil, MCPProgram.words(program.arguments, home: home) != nil
            else { return .failed(String(localized: "A quote is not closed.")) }
            let tested = ConnectedToolSettings(id: draft.trialID, name: draft.name, address: "", access: .none,
                                               program: program)
            return found(await model.testConnectedTool(tested), for: draft, program: true)
        }
        guard MCPClient.address(draft.address) != nil else { return .failed(String(localized: "This address can’t be one.")) }
        let access = Self.settings(draft.access)
        var token = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if access == .token, token.isEmpty, draft.changes { token = ConnectedToolsKeychain.token(for: draft.id) ?? "" }
        if access == .token, token.isEmpty { return .failed(String(localized: "Paste the tool’s token first.")) }
        ConnectedToolsKeychain.setToken(access == .token ? token : nil, for: draft.trialID, name: draft.name)
        let tested = ConnectedToolSettings(id: draft.trialID, name: draft.name, address: draft.address, access: access)
        return found(await model.testConnectedTool(tested), for: draft, program: false)
    }

    private func found(_ test: ConnectedToolTest, for draft: Draft, program: Bool) -> Trial {
        switch test {
        case .works(let tools, _):
            trialTools[draft.trialID] = tools
            return .connected(actions: tools.count)
        case .failed(let error):
            trialTools[draft.trialID] = nil
            return .failed(Self.reason(error, program: program))
        }
    }

    /// Adds the tool the trial connected to, or saves the changed connection; its id.
    func add(_ draft: Draft) -> ConnectedTool.ID? {
        guard let model, let found = trialTools.removeValue(forKey: draft.trialID) else { return nil }
        let access = draft.kind == .program ? .none : Self.settings(draft.access)
        if draft.trialID != draft.id {
            ConnectedToolsKeychain.setToken(access == .token ? ConnectedToolsKeychain.token(for: draft.trialID) : nil,
                                            for: draft.id, name: draft.name)
            ConnectedToolsKeychain.setToken(nil, for: draft.trialID)
        }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let address = draft.kind == .program ? "" : draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let program = draft.kind == .program ? draft.program : nil
        if let i = model.settings.connectedTools.firstIndex(where: { $0.id == draft.id }) {
            var tool = model.settings.connectedTools[i]
            tool.address = address
            tool.access = access
            tool.program = program
            if !name.isEmpty { tool.name = name }
            tool.actions = tool.merging(found)
            model.settings.connectedTools[i] = tool
            model.reconnected(draft.id)
        } else {
            var tool = ConnectedToolSettings(id: draft.id, name: name, address: address, access: access, program: program)
            tool.actions = tool.merging(found)
            model.settings.connectedTools.append(tool)
        }
        return draft.id
    }

    /// The sheet closed without adding or saving: the token of its trial goes.
    func discard(_ draft: Draft) {
        trialTools[draft.trialID] = nil
        guard draft.trialID != draft.id || model?.settings.connectedTools.contains(where: { $0.id == draft.id }) == false
        else { return }
        ConnectedToolsKeychain.setToken(nil, for: draft.trialID)
    }

    // MARK: - From the settings

    private static func shown(_ tool: ConnectedToolSettings, index: Int, model: AssistantModel) -> ConnectedTool {
        let host = MCPClient.address(tool.address)?.host() ?? ""
        let home = tool.name.lowercased().contains("home assistant") || host.lowercased().contains("homeassistant")
        let place: ConnectedTool.Place = tool.program != nil ? .thisMac : MCPClient.isHomeNetwork(host) ? .home : .internet
        let colors = [Palette.azureSoft, Palette.sunSoft, Palette.coralSoft]
        let state: ConnectedTool.State = switch model.connectedToolStates[tool.id] {
        case _ where !tool.enabled: .paused
        case .needsReconnect?: .needsReconnect
        case .unreachable?: .unreachable
        default: .connected
        }
        let lastTest: ConnectedTool.Test? = switch model.connectedToolTests[tool.id] {
        case .works(let tools, let seconds)?: .works(actions: tools.count, seconds: seconds)
        case .failed(let error)? where error == .noAnswer || error == .unreachable: .noAnswer
        case .failed(let error)?: .failed(reason(error, program: tool.program != nil))
        case nil: nil
        }
        let log = (model.connectedToolLogs[tool.id] ?? []).enumerated().map { i, entry in
            ConnectedTool.LogEntry(id: "\(i)-\(entry.date.timeIntervalSince1970)", date: entry.date, title: entry.title,
                                   result: result(entry.result))
        }
        return ConnectedTool(
            id: tool.id, name: tool.name, icon: home ? .home : place == .home ? .plug : place == .thisMac ? .laptop : .globe,
            color: home ? Palette.turquoiseSoft : colors[index % colors.count], place: place,
            connection: tool.program.map { .program(command: $0.command, arguments: $0.arguments) }
                ?? .service(address: tool.address, access: shown(tool.access)),
            state: state, enabled: tool.enabled,
            whenActing: tool.whenActing == .askFirst ? .askFirst : .doDirectly,
            actions: tool.actions.map { ConnectedTool.Action(id: $0.name, title: title($0.tool), reads: $0.reads,
                                                              enabled: $0.enabled) },
            log: log, lastTest: lastTest,
            accessNote: home ? String(localized: "By default, only Home Assistant administrator accounts can connect.")
                : nil)
    }

    nonisolated static func shown(_ access: ConnectedToolSettings.Access) -> ConnectedTool.Access {
        switch access {
        case .token: .token
        case .none: .none
        case .account: .account
        }
    }

    private static func settings(_ access: ConnectedTool.Access) -> ConnectedToolSettings.Access {
        switch access {
        case .token: .token
        case .none: .none
        case .account: .account
        }
    }

    /// Home Assistant's common actions get a title of their own; any other one the service's title, or its name.
    private static func title(_ tool: MCPTool) -> String {
        switch ConnectedTools.homeAssistantName(tool.name) {
        case "GetLiveContext": String(localized: "Read the state of the home")
        case "GetDateTime": String(localized: "Read the date and time")
        case "HassTurnOn": String(localized: "Turn on")
        case "HassTurnOff": String(localized: "Turn off")
        case "HassToggle": String(localized: "Switch over")
        case "HassLightSet": String(localized: "Set a light")
        case "HassClimateSetTemperature": String(localized: "Set the heating")
        case "HassSetPosition": String(localized: "Open or close")
        case "HassMediaPause": String(localized: "Pause the music")
        case "HassMediaUnpause": String(localized: "Resume the music")
        case "HassMediaNext": String(localized: "Next track")
        case "HassMediaPrevious": String(localized: "Previous track")
        case "HassSetVolume": String(localized: "Set the volume")
        case "HassListAddItem": String(localized: "Add to a list")
        case "HassListCompleteItem": String(localized: "Check off an item of a list")
        case "HassListRemoveItem": String(localized: "Remove an item from a list")
        case "todo_get_items": String(localized: "Read a list")
        case "calendar_get_events": String(localized: "Read the calendar")
        default: tool.title ?? tool.name
        }
    }

    private static func result(_ result: ConnectedToolLogEntry.Result) -> ConnectedTool.LogEntry.Result {
        switch result {
        case .done: .done
        case .refusedByUser: .refusedByUser
        case .failed(.noAnswer): .failed(String(localized: "no answer"))
        case .failed(.unreachable): .failed(String(localized: "unreachable"))
        case .failed(.unauthorized): .failed(String(localized: "access refused"))
        case .failed(.said(let why)): .failed(why)
        }
    }

    /// Why a trial or a test failed, for the sheet and the tool's page; `program`: a program on this Mac.
    static func reason(_ error: MCPError, program: Bool = false) -> String {
        switch error {
        case .unreachable: String(localized: "Nothing answers at this address. Check it, and that this Mac is on the same network.")
        case .noAnswer where program: String(localized: "The program did not answer in time.")
        case .noAnswer: String(localized: "The tool did not answer in time.")
        case .unauthorized: String(localized: "The tool refuses the access: check the token.")
        case .notMCP(let what) where program: String(localized: "The program started, but it does not speak MCP (\(what)).")
        case .notMCP(let what): String(localized: "Something answers at this address, but not a connected tool (\(what)).")
        case .refused(let why): String(localized: "The tool refused: \(why)")
        case .notFound(let command): String(localized: "“\(command)” is not on this Mac. Install it, or type the command’s full path.")
        case .ended(let said) where said.isEmpty: String(localized: "The program stopped as soon as it started.")
        case .ended(let said): String(localized: "The program stopped: \(said)")
        }
    }
}

// MARK: - The list

/// Settings › Connected tools: the tools, each with its state and switch, or an empty page with examples.
struct ToolsPage: View {
    let tools: ConnectedToolsAccess
    let navigation: SettingsNavigation

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Connected tools")) {
                Button { navigation.sheet = .addTool } label: { IconLabel("Add a tool", icon: .plus) }
                    .buttonStyle(WindowButtonStyle(kind: .link, big: true))
            }
            PageIntro("Connect Maé to other systems with MCP: she will be able to turn on a light, add a task or search your notes. You can connect several at once.")
            if tools.tools.isEmpty {
                EmptyPageHero(disc: FamilyDisc(icon: .plug, color: Palette.sunSoft, size: 64),
                              title: Text("No tool connected"),
                              text: Text("Connect Home Assistant, your notes or another service: Maé can act for you, without you touching the Mac."))
                {
                    HStack(spacing: 8) {
                        ExampleChip(icon: .home, title: Text(verbatim: "Home Assistant"))
                        ExampleChip(icon: .document, title: Text("Notes"))
                        ExampleChip(icon: .folder, title: Text("Files"))
                        ExampleChip(icon: .branch, title: Text(verbatim: "GitHub"))
                    }
                } action: {
                    Button { navigation.sheet = .addTool } label: { IconLabel("Add a tool", icon: .plus) }
                        .buttonStyle(WindowButtonStyle(kind: .main))
                }
                .padding(.top, 22)
            } else {
                PageSection(Text("Connected · \(tools.tools.count)"))
                SettingsCard {
                    ForEach(tools.tools) { tool in
                        if tool.id != tools.tools.first?.id { Hairline() }
                        row(tool)
                    }
                }
            }
            PromiseList(items: [
                (icon: .smallCheck, text: Text("Maé uses a tool only if what you ask needs it.")),
                (icon: .lock, text: Text("An action that changes something (turn on, create, delete) asks for your “yes”, unless you choose otherwise for that tool.")),
                (icon: .history, text: Text("Everything she does with a tool is noted in its log.")),
            ])
        }
    }

    private func row(_ tool: ConnectedTool) -> some View {
        OpeningListItem(disc: FamilyDisc(icon: tool.icon, color: tool.color), name: { Text(verbatim: tool.name) },
                        sub: ToolWords.line(tool), openLabel: Text("Open \(tool.name)"),
                        open: { navigation.tool = tool.id })
        {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    StatusDot(tone: ToolWords.tone(tool.state))
                    ToolWords.word(tool.state)
                        .textStyle(.itemState)
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
                if tool.state == .needsReconnect {
                    Button("Reconnect") { navigation.sheet = .changeTool(tool.id) }
                        .buttonStyle(WindowButtonStyle(kind: .link))
                } else {
                    BareSwitch(label: Text("Turn on \(tool.name)"), isOn: Binding(
                        get: { tool.enabled },
                        set: { on in
                            var changed = tool
                            changed.enabled = on
                            changed.state = on ? .connected : .paused
                            tools.update(changed)
                        }))
                }
                Button { navigation.tool = tool.id } label: { IconView(icon: .forward, size: 18) }
                    .buttonStyle(SmallRoundButtonStyle())
                    .accessibilityLabel(Text("\(tool.name) settings"))
            }
        }
    }

    /// The quick panel's line: "None", "1 on", "2 on".
    static func summary(_ model: AssistantModel) -> Text {
        let on = model.settings.connectedTools.filter(\.enabled).count
        return on == 0 ? Text("None") : Text("\(on) on")
    }

    static func badge(_ tools: ConnectedToolsAccess) -> SidebarBadge? {
        if tools.tools.contains(where: { $0.state == .unreachable || $0.state == .needsReconnect }) {
            return .dot(.warn, Text("To look at"))
        }
        let count = tools.tools.count
        return count == 0 ? nil : .count(count, count == 1 ? Text("1 tool") : Text("\(count) tools"))
    }
}

/// An example of the empty page: an icon and a name, on a neutral pill.
private struct ExampleChip: View {
    let icon: Icon
    let title: Text

    var body: some View {
        HStack(spacing: 7) {
            IconView(icon: icon, size: 15)
            title.textStyle(.pill)
        }
        .foregroundStyle(Palette.inkMuted)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Palette.fieldDisabled, in: Capsule())
    }
}

// MARK: - A tool

/// Connected tools › a tool: its connection, what Maé may do with it, its last actions, its removal.
struct ToolPage: View {
    let tools: ConnectedToolsAccess
    let tool: ConnectedTool
    let navigation: SettingsNavigation
    @State private var showsAllActions = false

    /// How many actions are shown before "See the other actions".
    private static let shownActions = 6

    var body: some View {
        SettingsPageScroll {
            PageHead(Text(verbatim: tool.name), back: { navigation.tool = nil }, backLabel: Text("Connected tools")) {
                StatusPill(text: ToolWords.word(tool.state), style: .dot(ToolWords.tone(tool.state)))
            }
            PageSubtitle(icon: ToolWords.placeIcon(tool.place), text: ToolWords.line(tool))
            if tool.state == .unreachable {
                Note(unreachable, tone: .error)
                    .padding(.top, 18)
                ActionRow(top: 12, bottom: 0) {
                    Button("Try again") { tools.test(tool.id) }
                        .buttonStyle(WindowButtonStyle())
                        .disabled(tools.testing.contains(tool.id))
                }
            }
            PageSection("Connection")
            SettingsCard { connection }
            PageSection("What Maé can do")
            SettingsCard { actions }
            PageSection("Last actions")
            SettingsCard {
                if tool.log.isEmpty {
                    Caption("Nothing done yet.")
                        .padding(.top, 20)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(tool.log) { entry in
                            LogLine(event: Text(verbatim: "\(InboundWords.time(entry.date)) · \(entry.title)"),
                                    result: ToolWords.result(entry.result), resultColor: ToolWords.color(entry.result))
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            Button("Remove this tool…") { navigation.sheet = .removeTool(tool.id) }
                .buttonStyle(WindowButtonStyle(kind: .danger))
                .padding(.top, 22)
        }
    }

    /// Why it is unreachable: a service does not answer; a program does not start, and its last test says why.
    private var unreachable: Text {
        guard case .program = tool.connection else {
            return Text("\(tool.name) does not answer. Check that this Mac is on the same network as it, then try again.")
        }
        return switch tool.lastTest {
        case .failed(let reason)?: Text("\(tool.name) does not start. \(reason)")
        case .noAnswer?: Text("\(tool.name) does not start: it did not answer in time. Check its command, then try again.")
        default: Text("\(tool.name) does not start. Check its command, then try again.")
        }
    }

    @ViewBuilder private var connection: some View {
        SwitchRow("On", isOn: Binding(get: { tool.enabled }, set: { on in
            change {
                $0.enabled = on
                if $0.state == .connected || $0.state == .paused { $0.state = on ? .connected : .paused }
            }
        }))
        .accessibilityLabel(Text("Turn on \(tool.name)"))
        Caption("Off, Maé no longer uses this tool. The connection is kept.")
        Hairline()
        switch tool.connection {
        case .service(let address, let access):
            SettingRow("Address") {
                HStack(spacing: 10) {
                    Text(verbatim: address)
                        .textStyle(.address)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…") { navigation.sheet = .changeTool(tool.id) }
                        .buttonStyle(WindowButtonStyle())
                }
            }
            Hairline()
            SettingRow("Access") {
                HStack(spacing: 10) {
                    ToolWords.access(access, of: tool)
                        .textStyle(.setting)
                        .foregroundStyle(Palette.ink)
                    if access != .none {
                        Button("Reconnect") { navigation.sheet = .changeTool(tool.id) }
                            .buttonStyle(WindowButtonStyle())
                    }
                }
            }
            if let note = tool.accessNote { Caption(Text(verbatim: note)) }
        case .program(let command, let arguments):
            SettingRow("Command") {
                Text(verbatim: arguments.isEmpty ? command : "\(command) \(arguments)")
                    .textStyle(.address)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        Hairline()
        SettingRow("Test the connection") {
            HStack(spacing: 10) {
                switch tool.lastTest {
                case .works(let count, let seconds):
                    StatusPill(text: Text("It works: \(count) actions in \(Units.seconds(fromMilliseconds: seconds * 1000))"),
                               style: .success)
                case .noAnswer:
                    StatusPill(text: Text("No answer"), style: .refused)
                case .failed(let reason):
                    // Cut when long (a program's reason): the button keeps its room, and the note above says it all.
                    StatusPill(text: Text("Failed: \(reason)"), style: .refused, shrinks: true)
                        .layoutPriority(-1)
                case nil:
                    EmptyView()
                }
                if tools.testing.contains(tool.id) {
                    ProgressView().controlSize(.small)
                }
                Button("Test") { tools.test(tool.id) }
                    .buttonStyle(WindowButtonStyle())
                    .disabled(tools.testing.contains(tool.id))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        SettingRow("When she acts") {
            WindowSegmented(selection: Binding(get: { tool.whenActing }, set: { value in change { $0.whenActing = value } }),
                            options: [(value: .askFirst, title: "Ask first"), (value: .doDirectly, title: "Do it directly")],
                            label: Text("When Maé acts"))
        }
        if tool.whenActing == .askFirst {
            Caption("“Ask first”: Maé says what she is about to do, for example “I turn on the living room”, and waits for your “yes”.")
        } else {
            Caption("Maé acts as soon as you ask, without waiting for your “yes”.", tone: .warn)
        }
        let shown = showsAllActions ? tool.actions : Array(tool.actions.prefix(Self.shownActions))
        let reading = shown.filter(\.reads)
        let acting = shown.filter { !$0.reads }
        if !reading.isEmpty {
            Hairline()
            CardSubtitle(text: Text("Read · \(tool.actions.filter(\.reads).count)"))
            ForEach(reading) { action in actionRow(action) }
        }
        if !acting.isEmpty {
            Hairline()
            CardSubtitle(text: Text("Act · \(tool.actions.filter { !$0.reads }.count)"))
            ForEach(acting) { action in actionRow(action) }
        }
        if tool.actions.count > Self.shownActions, !showsAllActions {
            Hairline()
            ActionRow(top: 12, bottom: 12) {
                Button("See the \(tool.actions.count - Self.shownActions) other actions") { showsAllActions = true }
                    .buttonStyle(WindowButtonStyle())
            }
        }
    }

    private func actionRow(_ action: ConnectedTool.Action) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: action.title)
                    .textStyle(.setting)
                    .foregroundStyle(Palette.ink)
                Text(verbatim: action.id)
                    .textStyle(.toolID)
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            BareSwitch(label: Text(verbatim: action.title), isOn: Binding(get: { action.enabled }, set: { on in
                change { tool in
                    if let i = tool.actions.firstIndex(where: { $0.id == action.id }) { tool.actions[i].enabled = on }
                }
            }))
        }
        .frame(minHeight: 58)
    }

    private func change(_ edit: (inout ConnectedTool) -> Void) {
        guard var latest = tools.tool(tool.id) else { return }
        edit(&latest)
        tools.update(latest)
    }
}

// MARK: - Sheets

/// "Add a tool": a service on the network or on the internet ("Test", then "Add"), or a program on this Mac ("Test and
/// add": added as soon as it answered). Also "Change…" and "Reconnect" of a tool's connection: its address, its access,
/// a new token.
struct AddToolSheet: View {
    let tools: ConnectedToolsAccess
    let navigation: SettingsNavigation
    @State private var step: Step
    @State private var draft: ConnectedToolsAccess.Draft
    @State private var trial: ConnectedToolsAccess.Trial?
    @State private var isTrying = false
    /// The trial of exactly this draft connected (a change of its address or token needs a new one).
    @State private var tried: ConnectedToolsAccess.Draft?

    enum Step: Equatable { case choose, form }

    /// `step`, `draft` and `trial`: where it starts (still pictures of the screens start further on).
    init(tools: ConnectedToolsAccess, navigation: SettingsNavigation, step: Step = .choose,
         draft: ConnectedToolsAccess.Draft = .init(), trial: ConnectedToolsAccess.Trial? = nil)
    {
        self.tools = tools
        self.navigation = navigation
        _step = State(initialValue: step)
        _draft = State(initialValue: draft)
        _trial = State(initialValue: trial)
    }

    var body: some View {
        switch step {
        case .choose: choose
        case .form: form
        }
    }

    private var choose: some View {
        SheetCard(title: Text("Add a tool"),
                  text: Text("MCP is an open standard: a tool that speaks it gives Maé new actions. Choose how this one connects."))
        {
            VStack(spacing: 10) {
                SheetChoice(disc: FamilyDisc(icon: .globe, color: Palette.azureSoft, size: 48),
                            title: Text("A service on your network or on the internet"),
                            detail: Text("Home Assistant, GitHub, Todoist… You give its address."))
                {
                    draft.kind = .service
                    step = .form
                }
                SheetChoice(disc: FamilyDisc(icon: .laptop, color: Palette.sunSoft, size: 48),
                            title: Text("A program on this Mac"),
                            detail: Text("Notes, files, browser… Maé starts it herself."))
                {
                    draft.kind = .program
                    step = .form
                }
            }
            .padding(.top, 18)
        } footer: {
            Text("You can remove it whenever you want.")
                .textStyle(.rowSub)
                .foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 0)
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private var form: some View {
        SheetCard(title: draft.changes ? Text("The connection of \(draft.name)")
            : draft.kind == .service ? Text("A service on your network or on the internet") : Text("A program on this Mac"))
        {
            VStack(alignment: .leading, spacing: 0) {
                if !draft.changes {
                    LabeledField(label: Text("Name")) {
                        TextField(text: $draft.name, prompt: placeholder(Text(verbatim: ""))) { Text("Name") }
                            .windowField()
                    }
                }
                if draft.kind == .service {
                    LabeledField(label: Text("Address")) {
                        TextField(text: $draft.address, prompt: placeholder(Text(verbatim: "http://homeassistant.local:8123/api/mcp"))) {
                            Text("Address")
                        }
                        .windowField(mono: true, isRefused: isRefused)
                    }
                    LabeledField(label: Text("Access")) {
                        WindowSegmented(selection: $draft.access,
                                        options: [(value: .account, title: "With my account"),
                                                  (value: .token, title: "With a token"), (value: .none, title: "None")],
                                        label: Text("Access"), fills: true, soon: [.account])
                    }
                    if draft.access == .token {
                        LabeledField(label: Text("Token")) {
                            SecureField(text: $draft.token, prompt: placeholder(draft.changes ? Text(verbatim: "••••••••")
                                : Text("Paste the token here"))) { Text("Token") }
                                .windowField(mono: true, isRefused: isRefused)
                        }
                        Caption(draft.changes ? "Leave it empty to keep the saved token. It is kept in your Mac’s keychain."
                            : "It is kept in your Mac’s keychain.")
                    }
                    if !draft.changes {
                        Note("For Home Assistant: add the “Model Context Protocol Server” integration in Settings › Devices & services, then create a long-lived access token in your profile, under Security. By default, only administrator accounts can connect.",
                             icon: .bulb)
                    }
                } else {
                    LabeledField(label: Text("Command")) {
                        TextField(text: $draft.command, prompt: placeholder(Text(verbatim: "npx -y @modelcontextprotocol/server-filesystem"))) {
                            Text("Command")
                        }
                        .windowField(mono: true, isRefused: isRefused)
                    }
                    LabeledField(label: Text("Arguments")) {
                        TextField(text: $draft.arguments, prompt: placeholder(Text(verbatim: "~/Documents"))) { Text("Arguments") }
                            .windowField(mono: true)
                    }
                    Note("This program runs on your Mac with your rights. Only add programs you know.", tone: .warn)
                }
                switch trial {
                case .connected(let count):
                    Note(Text("Connected: \(count) actions found. You will choose which ones Maé may use."), tone: .success)
                        .padding(.top, 12)
                case .failed(let reason):
                    Note(Text(verbatim: reason), tone: .error)
                        .padding(.top, 12)
                case nil:
                    EmptyView()
                }
            }
            .padding(.top, 18)
        } footer: {
            if draft.changes {
                Button("Cancel") { navigation.sheet = nil }
                    .buttonStyle(WindowButtonStyle())
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Back") {
                    step = .choose
                    trial = nil
                }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
            if isTrying { ProgressView().controlSize(.small) }
            Button(action: next) { nextTitle }
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete || isTrying)
        }
        .onChange(of: draft) {
            // Another address, access or token: the trial no longer tells anything.
            if tried != nil, tried != draft {
                tried = nil
                trial = nil
            }
        }
        .onDisappear { tools.discard(draft) }
    }

    private var isRefused: Bool {
        if case .failed = trial { return true }
        return false
    }

    private var isComplete: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        switch draft.kind {
        case .service: return !name.isEmpty && !draft.address.trimmingCharacters(in: .whitespaces).isEmpty
        case .program: return !name.isEmpty && !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var nextTitle: Text {
        switch trial {
        case .connected: draft.changes ? Text("Save") : Text("Add")
        case .failed: Text("Try again")
        case nil: draft.kind == .program ? Text("Test and add") : Text("Test")
        }
    }

    private func next() {
        if case .connected = trial {
            let id = tools.add(draft)
            navigation.sheet = nil
            navigation.tool = id
            return
        }
        isTrying = true
        let draft = draft
        Task {
            trial = await tools.trial(draft)
            isTrying = false
            guard case .connected = trial else { return }
            tried = draft
            // "Test and add": a program that answered is added at once (unless it was changed since); its page lists
            // its actions.
            if draft.kind == .program, !draft.changes, self.draft == draft { next() }
        }
    }
}

/// "Remove Home Assistant?".
struct RemoveToolSheet: View {
    let tools: ConnectedToolsAccess
    let tool: ConnectedTool
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Remove \(tool.name)?"),
                  text: Text("Maé will no longer be able to use it, and its log is erased. You can add it again later."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Remove") {
                navigation.sheet = nil
                navigation.tool = nil
                tools.remove(tool.id)
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}

// MARK: - Words

enum ToolWords {
    static func word(_ state: ConnectedTool.State) -> Text {
        switch state {
        case .connected: Text("Connected")
        case .needsReconnect: Text("To reconnect")
        case .paused: Text("Paused")
        case .unreachable: Text("Unreachable")
        }
    }

    static func tone(_ state: ConnectedTool.State) -> StatusTone {
        switch state {
        case .connected: .on
        case .needsReconnect: .warn
        case .paused: .off
        case .unreachable: .error
        }
    }

    /// "At home · 14 actions".
    static func line(_ tool: ConnectedTool) -> Text {
        let place: Text = switch tool.place {
        case .home: Text("At home")
        case .thisMac: Text("On this Mac")
        case .internet: Text("Internet")
        }
        return place + Text(verbatim: " · ") + Text("\(tool.actions.count) actions")
    }

    static func placeIcon(_ place: ConnectedTool.Place) -> Icon {
        switch place {
        case .home: .home
        case .thisMac: .laptop
        case .internet: .globe
        }
    }

    static func access(_ access: ConnectedTool.Access, of tool: ConnectedTool) -> Text {
        switch access {
        case .account: Text("Your \(tool.name) account")
        case .token: Text("A token")
        case .none: Text("None")
        }
    }

    static func result(_ result: ConnectedTool.LogEntry.Result) -> Text {
        switch result {
        case .done: Text("Completed")
        case .refusedByUser: Text("Refused by you")
        case .failed(let reason): Text("Failed: \(reason)")
        }
    }

    static func color(_ result: ConnectedTool.LogEntry.Result) -> RGBA {
        switch result {
        case .done: Palette.success
        case .refusedByUser: Palette.inkMuted
        case .failed: Palette.danger
        }
    }
}
