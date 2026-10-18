import SwiftUI
import VoiceCore

// Settings › Connected tools (MCP): servers Maé can ask for actions (turn on a light, add a task, search notes),
// several at once. NOT BUILT YET: OpenMaé has no MCP client. The pages and the sheet below are drawn from the design
// (its screens of connected tools) and read `ConnectedToolsAccess`, which nothing feeds; the sidebar entry and the quick
// panel's line stay greyed while `ConnectedToolsAccess.isAvailable` is false. Whoever builds MCP feeds `tools` from the
// real client, fills the methods marked "Not wired yet", and sets `isAvailable`. To check before building, from the
// design: Home Assistant's action names, its address and the administrator-only note are examples written without
// asking a real server; "Ask first" by default for what acts is a proposal.

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

        var id = UUID()
        var date: Date
        var title: String
        var result: Result
    }

    enum Test: Equatable {
        case works(actions: Int, seconds: Double)
        case noAnswer
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
    /// False until MCP is built: the sidebar entry and the quick panel's line are greyed.
    static let isAvailable = false

    var tools: [ConnectedTool]

    init(tools: [ConnectedTool] = []) {
        self.tools = tools
    }

    func tool(_ id: ConnectedTool.ID) -> ConnectedTool? {
        tools.first { $0.id == id }
    }

    /// A change made in the settings. Not wired yet: the real client must apply it (and report the new state).
    func update(_ tool: ConnectedTool) {
        guard let i = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        tools[i] = tool
    }

    /// "Reconnect" (signing in again), "Try again", "Test". Not wired yet.
    func reconnect(_ id: ConnectedTool.ID) {}
    func test(_ id: ConnectedTool.ID) {}

    func remove(_ id: ConnectedTool.ID) {
        tools.removeAll { $0.id == id }  // Not wired yet: the client must forget it too.
    }

    /// What "Add a tool" asks for.
    struct Draft: Equatable {
        enum Kind: Equatable { case service, program }

        var kind = Kind.service
        var name = ""
        var address = ""
        var access = ConnectedTool.Access.account
        var command = ""
        var arguments = ""
    }

    /// What the test of a new tool found.
    enum Trial: Equatable {
        case connected(actions: Int)
        case failed(String)
    }

    /// Connects to a new tool to see what it offers. Not wired yet.
    func trial(_ draft: Draft) async -> Trial {
        .failed(String(localized: "Connected tools are not available yet."))
    }

    /// Adds the tool the trial connected to; its id. Not wired yet.
    func add(_ draft: Draft) -> ConnectedTool.ID? { nil }
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
                    Button("Reconnect") { tools.reconnect(tool.id) }
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
                Note(Text("\(tool.name) does not answer. Check that this Mac is on the same network as it, then try again."),
                     tone: .error)
                    .padding(.top, 18)
                ActionRow(top: 12, bottom: 0) {
                    Button("Try again") { tools.test(tool.id) }
                        .buttonStyle(WindowButtonStyle())
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
                    Button("Change…") {}
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
                        Button("Reconnect") { tools.reconnect(tool.id) }
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
                case nil:
                    EmptyView()
                }
                Button("Test") { tools.test(tool.id) }
                    .buttonStyle(WindowButtonStyle())
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

/// "Add a tool": a service on the network or on the internet, or a program on this Mac; tested when added.
struct AddToolSheet: View {
    let tools: ConnectedToolsAccess
    let navigation: SettingsNavigation
    @State private var step: Step
    @State private var draft: ConnectedToolsAccess.Draft
    @State private var trial: ConnectedToolsAccess.Trial?
    @State private var isTrying = false

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
        SheetCard(title: draft.kind == .service ? Text("A service on your network or on the internet")
            : Text("A program on this Mac"))
        {
            VStack(alignment: .leading, spacing: 0) {
                LabeledField(label: Text("Name")) {
                    TextField(text: $draft.name, prompt: placeholder(Text(verbatim: ""))) { Text("Name") }
                        .windowField()
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
                                        label: Text("Access"), fills: true)
                    }
                    Note("For Home Assistant: turn on the “MCP Server” integration in Settings › Devices & services. Only administrator accounts can connect to it.",
                         icon: .bulb)
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
            Button("Back") {
                step = .choose
                trial = nil
            }
            .buttonStyle(WindowButtonStyle())
            .keyboardShortcut(.cancelAction)
            Button(action: next) { nextTitle }
                .buttonStyle(WindowButtonStyle(kind: .main))
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete || isTrying)
        }
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
        case .connected: Text("Add")
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
