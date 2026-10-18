import AppKit
import SwiftUI
import VoiceCore

/// Settings › Actions: the switch, then, once on, the access to the calendar and reminders and the shortcuts of the
/// "OpenMaé" folder, each with "Ask first".
struct ActionsPage: View {
    @Bindable var model: AssistantModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Actions"))
            PageIntro("Maé adds events and reminders, reads your calendar, sets timers and runs the shortcuts of the “OpenMaé” folder in the Shortcuts app. She tells you what she saved: say “cancel” to take it back.")
            PageSection("Setting")
            SettingsCard {
                SwitchRow("On", isOn: $model.settings.actionsEnabled)
                    .accessibilityLabel(Text("Actions"))
                if let warning = Self.warning(model.tier) {
                    Caption(warning, tone: .warn)
                }
                if !model.settings.actionsEnabled {
                    Caption("Turn the actions on to choose the permissions and the shortcuts.")
                }
            }
            if model.settings.actionsEnabled, let actions = model.actions {
                PageSection("Permissions")
                SettingsCard { calendarAccess(actions) }
                PageSection("Shortcuts")
                SettingsCard { shortcuts(actions.shortcuts) }
            }
        }
    }

    /// The smaller models are not reliable with actions (measured with `voice-cli actions-bench`): the minimum
    /// tier's, even with its example exchanges, misses about one in fifteen, mostly saying it did what it did not do;
    /// the standard tier's gets some wrong, which the confirmation lets the user hear.
    static func warning(_ tier: HardwareTier?) -> LocalizedStringKey? {
        switch tier {
        case .minimum: "On this Mac, Maé sometimes misses an action: she may say she saved something without doing it."
        case .standard: "On this Mac, Maé sometimes gets an action wrong: listen to what she confirms."
        default: nil
        }
    }

    // MARK: - Calendar and reminders

    @ViewBuilder private func calendarAccess(_ actions: ActionsStatus) -> some View {
        let accesses = [actions.calendar, actions.reminders]
        SettingRow("Calendar and reminders") {
            if accesses.contains(.denied) {
                StatusPill(text: Text("Not allowed"), style: .refused)
            } else if accesses.allSatisfy({ $0 == .granted }) {
                StatusPill(text: Text("Allowed"), style: .success)
            } else {
                StatusPill(text: Text("Asked when needed"), style: .neutral)
            }
        }
        if accesses.contains(.denied) {
            Caption("Maé can’t use them. Allow OpenMaé in System Settings, Privacy & Security.")
            ActionRow {
                Button("Open System Settings") {
                    let pane = actions.calendar == .denied ? "Privacy_Calendars" : "Privacy_Reminders"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        openURL(url)
                    }
                }
                .buttonStyle(WindowButtonStyle(kind: .link))
            }
        } else if accesses.contains(.notAsked) {
            Caption("macOS will ask for access the first time you need it.")
        }
    }

    // MARK: - Shortcuts

    /// Whether Maé asks before running the shortcuts: all, none, or some of them.
    private enum AskFirst: Hashable {
        case all, none, some
    }

    @ViewBuilder private func shortcuts(_ names: [String]) -> some View {
        if names.isEmpty {
            Caption("No shortcut yet. Put some in an “OpenMaé” folder of the Shortcuts app: Maé will be able to run them.")
                .padding(.top, 20)
            ActionRow {
                Button("Open Shortcuts") {
                    if let url = URL(string: "shortcuts://") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(WindowButtonStyle())
            }
        } else {
            let askFirst = askFirst(names)
            SettingRow("Before running a shortcut") {
                PopUpMenu(title: Self.title(askFirst), label: Text("Before running a shortcut")) {
                    Button("Ask first") { model.settings.shortcutsToConfirm = names }
                    Button("Run it at once") { model.settings.shortcutsToConfirm = [] }
                }
            }
            switch askFirst {
            case .all: Caption("“Ask first”: Maé says which shortcut she is about to run and waits for your “yes”.")
            case .none: Caption("Maé runs the shortcut as soon as you ask for it.")
            case .some: Caption("Those switched on below ask first: Maé says which one she is about to run and waits for your “yes”.")
            }
            Hairline()
            CardSubtitle(text: Text("Found in the “OpenMaé” folder · \(names.count)"))
            ForEach(names, id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { model.settings.shortcutsToConfirm.contains(name) },
                    set: { ask in
                        model.settings.shortcutsToConfirm.removeAll { $0 == name }
                        if ask { model.settings.shortcutsToConfirm.append(name) }
                    }))
                {
                    Text(verbatim: name)
                        .textStyle(.setting)
                        .foregroundStyle(Palette.ink)
                }
                .toggleStyle(WindowSwitchStyle())
                .frame(minHeight: 58)
                .accessibilityLabel(Text("Ask first: \(name)"))
            }
        }
    }

    private func askFirst(_ names: [String]) -> AskFirst {
        let asking = names.filter { model.settings.shortcutsToConfirm.contains($0) }.count
        if asking == names.count { return .all }
        return asking == 0 ? .none : .some
    }

    private static func title(_ askFirst: AskFirst) -> Text {
        switch askFirst {
        case .all: Text("Ask first")
        case .none: Text("Run it at once")
        case .some: Text("Depends on the shortcut")
        }
    }

    // MARK: - In the sidebar

    static func badge(_ model: AssistantModel) -> SidebarBadge {
        guard model.settings.actionsEnabled else { return .dot(.off, Text("Off")) }
        if let actions = model.actions, actions.calendar == .denied || actions.reminders == .denied {
            return .dot(.warn, Text("To look at"))
        }
        return .dot(.on, Text("On"))
    }
}
