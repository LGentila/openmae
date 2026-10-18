import SwiftUI
import VoiceCore

/// Settings › Agents: the programs Maé hands long tasks to. Claude Code is the only one: no "Add an agent", no default
/// agent, nothing that announces agents that do not exist (the design's "planned" screens are not built).
struct AgentsPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    @Environment(\.openURL) private var openURL

    /// Where Claude Code is explained and installed.
    static let installPage = URL(string: "https://www.claude.com/product/claude-code")!

    var body: some View {
        let state = ClaudeCodeState(model)
        SettingsPageScroll {
            PageHead(Text("Agents"))
            PageIntro("Maé hands long tasks to an agent: a website, code, research. It works on its own, and a notification tells you when it is done.")
            PageSection(Text("My agents · \(1)"))
            SettingsCard {
                OpeningListItem(disc: ClaudeCodeState.disc, name: { Text(verbatim: "Claude Code") },
                                sub: ClaudeCodeState.where, openLabel: Text("Open Claude Code"),
                                open: { navigation.showsAgent = true })
                {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            StatusDot(tone: state.tone)
                            state.word
                                .textStyle(.itemState)
                                .foregroundStyle(Palette.ink)
                                .fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                        if state == .notInstalled, !model.settings.claudeCode.enabled {
                            Button("How to install it") { openURL(Self.installPage) }
                                .buttonStyle(WindowButtonStyle(kind: .link))
                        } else {
                            BareSwitch(label: Text("Turn on Claude Code"), isOn: $model.settings.claudeCode.enabled)
                            Button { navigation.showsAgent = true } label: { IconView(icon: .forward, size: 18) }
                                .buttonStyle(SmallRoundButtonStyle())
                                .accessibilityLabel(Text("Claude Code settings"))
                        }
                    }
                }
            }
            if let note = state.note {
                note.padding(.top, 14)
                if state == .actionsOff {
                    ActionRow(top: 10, bottom: 0) {
                        Button { navigation.show(.actions) } label: { IconLabel("Open Actions", icon: .arrowRight) }
                            .buttonStyle(WindowButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - In the sidebar and the quick panel

    static func badge(_ model: AssistantModel) -> SidebarBadge {
        let state = ClaudeCodeState(model)
        return .dot(state.tone, state.word)
    }

    /// "1 ready", or what stands in the way.
    static func summary(_ model: AssistantModel) -> Text {
        let state = ClaudeCodeState(model)
        return state == .ready ? Text("\(1) ready") : state.word
    }
}

/// Where Claude Code stands, in a word and a colour.
enum ClaudeCodeState: Equatable {
    case ready, off, notInstalled, notSignedIn, actionsOff, checking

    /// Whether it is installed and signed in is only known while the actions are on (the engine checks it with them).
    @MainActor
    init(_ model: AssistantModel) {
        let availability = model.actions?.claudeCode
        if availability == .notInstalled {
            self = .notInstalled
        } else if !model.settings.claudeCode.enabled {
            self = .off
        } else if !model.settings.actionsEnabled {
            self = .actionsOff
        } else if availability == .notLoggedIn {
            self = .notSignedIn
        } else if availability == nil {
            self = .checking
        } else {
            self = .ready
        }
    }

    var word: Text {
        switch self {
        case .ready: Text("Ready")
        case .off: Text("Off")
        case .notInstalled: Text("Not installed")
        case .notSignedIn: Text("Sign-in needed")
        case .actionsOff: Text("Actions off")
        case .checking: Text("Checking…")
        }
    }

    var tone: StatusTone {
        switch self {
        case .ready: .on
        case .off: .off
        case .notInstalled, .notSignedIn, .actionsOff: .warn
        case .checking: .info
        }
    }

    /// What stands in the way, and what to do about it.
    @MainActor
    var note: Note? {
        switch self {
        case .notInstalled:
            Note("Claude Code isn’t installed on this Mac. Once it is, Maé can hand it long tasks.")
        case .notSignedIn:
            Note("Claude Code isn’t signed in. Open it once in Terminal to sign in.", tone: .warn)
        case .actionsOff:
            Note("Maé hands tasks to an agent only while the actions are on.", tone: .warn)
        case .ready, .off, .checking:
            nil
        }
    }

    @MainActor static let disc = FamilyDisc(icon: .terminal, color: Palette.coralSoft)
    static let `where` = Text("On this Mac · Anthropic’s online models")
}

/// Agents › Claude Code: on or off, read-back, what it may do, the folders it may work in.
struct ClaudeCodePage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    @State private var choosingFolder = false
    @Environment(\.openURL) private var openURL

    private var settings: AgentSettings { model.settings.claudeCode }

    var body: some View {
        let state = ClaudeCodeState(model)
        SettingsPageScroll {
            PageHead(Text(verbatim: "Claude Code"), back: { navigation.showsAgent = false }, backLabel: Text("Agents")) {
                StatusPill(text: state.word, style: .dot(state.tone))
            }
            PageSubtitle(icon: .laptop, text: ClaudeCodeState.where)
            Note("What you hand it leaves this Mac: Claude Code works with Anthropic’s online models.", icon: .globe)
                .padding(.top, 16)
            if let note = state.note {
                note.padding(.top, 10)
                if state == .notInstalled {
                    ActionRow(top: 10, bottom: 0) {
                        Button("How to install it") { openURL(AgentsPage.installPage) }
                            .buttonStyle(WindowButtonStyle(kind: .link))
                    }
                } else if state == .actionsOff {
                    ActionRow(top: 10, bottom: 0) {
                        Button { navigation.show(.actions) } label: { IconLabel("Open Actions", icon: .arrowRight) }
                            .buttonStyle(WindowButtonStyle())
                    }
                }
            }
            PageSection("Setting")
            SettingsCard {
                SwitchRow("On", isOn: $model.settings.claudeCode.enabled)
                    .accessibilityLabel(Text(verbatim: "Claude Code"))
                    .disabled(state == .notInstalled && !settings.enabled)
            }
            if settings.enabled {
                PageSection("Control")
                SettingsCard {
                    SwitchRow("Read back before sending", isOn: $model.settings.claudeCode.review)
                    if settings.review {
                        Caption("Maé tells you what she is about to send and waits for your “yes”. The whole instruction is in the history.")
                    } else {
                        Caption("Maé sends the task at once. Say “cancel” right after to stop it.")
                    }
                    Hairline()
                    SettingRow("What it may do") {
                        WindowSegmented(selection: $model.settings.claudeCode.permissionMode,
                                        options: [(value: .acceptEdits, title: "Its folder"),
                                                  (value: .auto, title: "Decide alone")],
                                        label: Text("What Claude Code may do"))
                    }
                    if settings.permissionMode == .acceptEdits {
                        Caption("It changes the files of its folder. Anything else, like installing or running a program, is refused, and Maé tells you.")
                    } else {
                        Caption("It decides alone what is safe to do on this Mac, without asking you. Choose this only if you trust it with your files.",
                                tone: .warn)
                    }
                }
                PageSection("Folders")
                SettingsCard { folders }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result, !settings.folders.contains(folder.path) else { return }
            model.settings.claudeCode.folders.append(folder.path)
        }
    }

    @ViewBuilder private var folders: some View {
        ForEach(settings.folders, id: \.self) { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            HStack(spacing: 14) {
                FamilyDisc(icon: .folder, color: Palette.field, size: 28)
                Text(verbatim: name)
                    .textStyle(.setting)
                    .foregroundStyle(Palette.ink)
                    .help(Text(verbatim: path))
                Spacer(minLength: 0)
                Button {
                    model.settings.claudeCode.folders.removeAll { $0 == path }
                } label: {
                    IconView(icon: .cancel, size: 16)
                }
                .buttonStyle(SmallRoundButtonStyle())
                .accessibilityLabel(Text("Remove the folder \(name)"))
            }
            .frame(minHeight: 58)
            Hairline()
        }
        ActionRow(top: 12, bottom: 12) {
            Button { choosingFolder = true } label: { IconLabel("Add a folder…", icon: .plus) }
                .buttonStyle(WindowButtonStyle())
        }
        Caption("Each new task gets its own folder in “OpenMae”, in your home folder. Name one of these folders and Claude Code works there instead.")
    }
}
