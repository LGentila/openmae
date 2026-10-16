import SwiftUI
import VoiceCore

/// The settings, in a panel under the top bar's button: sound, conversation, advanced.
struct SettingsPanel: View {
    @Bindable var model: AssistantModel
    /// Opened from "Choose another tier…": the tier row is outlined for a moment.
    var pointsAtTier = false
    let close: () -> Void
    /// Opens Settings › iPhone.
    var openPhone: (() -> Void)?
    /// Tier picked in the menu, waiting for confirmation: changing tier restarts the assistant.
    @State private var pendingTier: TierChoice?
    @State private var confirmDeletion = false
    @State private var choosingFolder = false
    @Environment(\.openURL) private var openURL
    @Environment(PhoneAccess.self) private var phone: PhoneAccess?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Sound", isFirst: true)
            PanelBlock { sound }
            SectionTitle("Conversation")
            PanelBlock { conversation }
            SectionTitle("Advanced")
            PanelBlock(padding: EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)) { advanced }
        }
        .alert("Change tier?", isPresented: Binding(get: { pendingTier != nil }, set: { if !$0 { pendingTier = nil } }),
               presenting: pendingTier)
        { choice in
            Button("Change") {
                model.settings.tierOverride = choice.tier
                close()
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(tierChangeMessage(choice))
        }
        .modifier(DeleteModelsConfirmation(isPresented: $confirmDeletion) {
            model.deleteModels()
            close()
        })
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result, !model.settings.claudeCode.folders.contains(folder.path) else { return }
            model.settings.claudeCode.folders.append(folder.path)
        }
    }

    // MARK: - Sound

    @ViewBuilder private var sound: some View {
        HStack(spacing: 12) {
            Text("Output")
                .textStyle(.setting)
            Spacer(minLength: 0)
            Segmented(selection: $model.settings.audioMode,
                      options: AudioMode.allCases.map { (value: $0, title: StateText.audioMode($0)) })
        }
        .frame(minHeight: 48)
        Group {
            if model.settings.audioMode == .speakers {
                HelpText("Echo cancellation keeps the assistant from hearing itself. Other apps are turned down slightly during the conversation.")
            } else {
                HelpText("With headphones there is no echo, so the microphone is used as is. Avoid this mode with speakers: the assistant would interrupt itself.")
            }
        }
        .padding(.bottom, 6)
        Hairline()
        Toggle(isOn: $model.settings.pushToTalk) {
            Text("Push to talk")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 48)
        HelpText("Hold the space bar (or the button at the bottom of the window) while you speak. Useful in noisy places.")
        if model.hasTalkShortcut {
            Hairline()
                .padding(.top, 6)
            HStack(spacing: 12) {
                Text("Talk from another app")
                    .textStyle(.setting)
                Spacer(minLength: 0)
                KeyCap(title: Text("⌥ Space"))
            }
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)
            HelpText("Press once to talk, and again to finish. When the window is closed, Maé only listens after this shortcut.")
        }
    }

    // MARK: - Conversation

    @ViewBuilder private var conversation: some View {
        Toggle(isOn: $model.settings.actionsEnabled) {
            Text("Actions")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 48)
        HelpText("Maé adds events and reminders, reads your calendar, sets timers and runs the shortcuts of the “OpenMaé” folder in the Shortcuts app. She tells you what she saved: say “cancel” to take it back.")
            .padding(.bottom, 6)
        if let warning = actionsWarning {
            HelpText(warning)
                .padding(.bottom, 6)
        }
        if model.settings.actionsEnabled, let actions = model.actions {
            Hairline()
            calendarAccess(actions)
            Hairline()
            shortcuts(actions.shortcuts)
            Hairline()
            claudeCode(actions.claudeCode)
        }
        Hairline()
        Button("New conversation") {
            model.newConversation()
            close()
        }
        .buttonStyle(PillButtonStyle())
        .disabled(!model.isReady)
        .padding(.top, 9)
        .padding(.bottom, 1)
        if let openPhone, let phone {
            Hairline()
                .padding(.top, 8)
            PhoneRow(phone: phone, open: openPhone)
        }
    }

    /// The smaller models are not reliable with actions (measured with `voice-cli actions-bench`): the minimum
    /// tier's, even with its example exchanges, misses about one in fifteen, mostly saying it did what it did not do;
    /// the standard tier's gets some wrong, which the confirmation lets the user hear.
    private var actionsWarning: LocalizedStringKey? {
        switch model.tier {
        case .minimum: "On this Mac, Maé sometimes misses an action: she may say she saved something without doing it."
        case .standard: "On this Mac, Maé sometimes gets an action wrong: listen to what she confirms."
        default: nil
        }
    }

    @ViewBuilder private func calendarAccess(_ actions: ActionsStatus) -> some View {
        let accesses = [actions.calendar, actions.reminders]
        HStack(spacing: 12) {
            Text("Calendar and reminders")
                .textStyle(.setting)
            Spacer(minLength: 0)
            Group {
                if accesses.contains(.denied) {
                    Text("Not allowed")
                } else if accesses.allSatisfy({ $0 == .granted }) {
                    Text("Allowed")
                } else {
                    Text("Asked when needed")
                }
            }
            .textStyle(.value)
            .foregroundStyle(accesses.contains(.denied) ? Palette.danger : Palette.inkMuted)
        }
        .frame(minHeight: 46)
        if accesses.contains(.denied) {
            HelpText("Maé can’t use them. Allow OpenMaé in System Settings, Privacy & Security.")
            Button("Open System Settings") {
                let pane = actions.calendar == .denied ? "Privacy_Calendars" : "Privacy_Reminders"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { openURL(url) }
            }
            .buttonStyle(PillButtonStyle(kind: .link))
            .padding(.vertical, 8)
        } else if accesses.contains(.notAsked) {
            HelpText("macOS will ask for access the first time you need it.")
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder private func shortcuts(_ names: [String]) -> some View {
        HStack(spacing: 12) {
            Text("Shortcuts")
                .textStyle(.setting)
            Spacer(minLength: 0)
            if !names.isEmpty {
                Text("Ask first")
                    .textStyle(.value)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .frame(minHeight: 46)
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
            }
            .toggleStyle(SwitchStyle())
            .frame(minHeight: 40)
        }
        Group {
            if names.isEmpty {
                HelpText("Put shortcuts in a folder named “OpenMaé” in the Shortcuts app: Maé will be able to run them.")
            } else {
                HelpText("“Ask first”: Maé says which shortcut she is about to run and waits for your “yes”.")
            }
        }
        .padding(.bottom, 6)
    }

    /// Handing long tasks to Claude Code: on or off, read-back, what it may do, the folders it may work in.
    @ViewBuilder private func claudeCode(_ availability: AgentAvailability?) -> some View {
        Toggle(isOn: $model.settings.claudeCode.enabled) {
            Text(verbatim: "Claude Code")
                .textStyle(.setting)
        }
        .toggleStyle(SwitchStyle())
        .frame(minHeight: 46)
        .disabled(availability == .notInstalled && !model.settings.claudeCode.enabled)
        Group {
            switch availability {
            case .notInstalled:
                HelpText("Not installed on this Mac. Once it is, Maé can hand it long tasks: a website, code, research.")
            case .notLoggedIn:
                HelpText("Claude Code isn’t signed in. Open it once in Terminal to sign in.", color: Palette.danger)
            default:
                HelpText("Maé can hand it long tasks: a website, code, research. What you hand it leaves this Mac: Claude Code works with Anthropic’s online models. You get a notification when it is done.")
            }
        }
        .padding(.bottom, 6)
        if model.settings.claudeCode.enabled {
            Toggle(isOn: $model.settings.claudeCode.review) {
                Text("Read the task back first")
                    .textStyle(.setting)
            }
            .toggleStyle(SwitchStyle())
            .frame(minHeight: 40)
            Group {
                if model.settings.claudeCode.review {
                    HelpText("Maé tells you what she is about to send and waits for your “yes”. The whole instruction is in the history.")
                } else {
                    HelpText("Maé sends the task at once. Say “cancel” right after to stop it.")
                }
            }
            .padding(.bottom, 6)
            HStack(spacing: 12) {
                Text("What it may do")
                    .textStyle(.setting)
                Spacer(minLength: 0)
                Segmented(selection: $model.settings.claudeCode.permissionMode,
                          options: [(value: .acceptEdits, title: "Its folder"), (value: .auto, title: "Decide alone")],
                          width: 214)
            }
            .frame(minHeight: 48)
            Group {
                if model.settings.claudeCode.permissionMode == .acceptEdits {
                    HelpText("It changes the files of its folder. Anything else, like installing or running a program, is refused, and Maé tells you.")
                } else {
                    HelpText("It decides alone what is safe to do on this Mac, without asking you. Choose this only if you trust it with your files.")
                }
            }
            .padding(.bottom, 6)
            HStack(spacing: 12) {
                Text("Folders")
                    .textStyle(.setting)
                Spacer(minLength: 0)
                Button("Add…") { choosingFolder = true }
                    .buttonStyle(PillButtonStyle(kind: .link))
            }
            .frame(minHeight: 46)
            ForEach(model.settings.claudeCode.folders, id: \.self) { path in
                HStack(spacing: 12) {
                    Text(verbatim: URL(fileURLWithPath: path).lastPathComponent)
                        .textStyle(.label)
                        .foregroundStyle(Palette.ink)
                        .help(Text(verbatim: path))
                    Spacer(minLength: 0)
                    Button {
                        model.settings.claudeCode.folders.removeAll { $0 == path }
                    } label: {
                        IconView(icon: .cancel, size: 14)
                            .foregroundStyle(Palette.inkMuted)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove \(URL(fileURLWithPath: path).lastPathComponent)"))
                }
                .frame(minHeight: 32)
            }
            HelpText("Each new task gets its own folder in “OpenMae”, in your home folder. Name one of these folders and Claude Code works there instead.")
                .padding(.bottom, 6)
        }
    }

    // MARK: - Advanced

    /// "Automatic" or a forced tier.
    enum TierChoice: Hashable {
        case automatic
        case forced(HardwareTier)

        var tier: HardwareTier? {
            if case .forced(let tier) = self { return tier }
            return nil
        }
    }

    @ViewBuilder private var advanced: some View {
        HStack(spacing: 12) {
            Text("Tier")
                .textStyle(.setting)
            Spacer(minLength: 0)
            tierMenu
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 8)
        .modifier(PointedAt(isOn: pointsAtTier))
        .padding(.horizontal, -8)
        HelpText("The tier decides the language model. “Automatic” picks the one that suits this Mac's memory.")
            .padding(.top, 2)
            .padding(.bottom, 6)
        if let tier = model.tier, !tier.isTested {
            HelpText("This tier could not be tested: performance is estimated.")
                .padding(.bottom, 6)
        }
        if let forced = model.settings.tierOverride, let recommended = model.recommendedTier, forced > recommended {
            HelpText("This tier needs more memory than this Mac has: the assistant may be very slow.",
                     color: Palette.danger)
                .padding(.bottom, 6)
        }
        Hairline()
        HStack(spacing: 12) {
            Text("Models on this Mac")
                .textStyle(.setting)
            Spacer(minLength: 0)
            Text(verbatim: Units.bytes(model.storage?.usedBytes))
                .textStyle(.value)
                .foregroundStyle(Palette.inkMuted)
        }
        .frame(minHeight: 46)
        Hairline()
        VStack(alignment: .leading, spacing: 8) {
            if let storage = model.storage, storage.unusedBytes > 0 {
                Button("Delete the other tiers' models (\(Units.bytes(storage.unusedBytes)))") {
                    model.deleteUnusedModels()
                }
                .buttonStyle(PillButtonStyle())
            }
            Button("Delete the models…") { confirmDeletion = true }
                .buttonStyle(PillButtonStyle(kind: .destructive))
                .disabled(model.isLoading || model.isDownloading || (model.storage?.usedBytes ?? 0) == 0)
        }
        .padding(.vertical, 9)
    }

    /// The tier's pop-up menu; locked while models load or download.
    private var tierMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { model.settings.tierOverride.map(TierChoice.forced) ?? .automatic },
                set: { choice in
                    if choice.tier != model.settings.tierOverride { pendingTier = choice }
                }))
            {
                automaticLabel.tag(TierChoice.automatic)
                ForEach(HardwareTier.selectable, id: \.self) { tier in
                    tierLabel(tier).tag(TierChoice.forced(tier))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MenuFieldLabel(title: model.settings.tierOverride.map { Text(StateText.tier($0)) } ?? automaticLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isLoading || model.isDownloading)
    }

    private var automaticLabel: Text {
        if let recommended = model.recommendedTier {
            return Text("Automatic: \(Text(StateText.tier(recommended)))")
        }
        return Text("Automatic")
    }

    private func tierLabel(_ tier: HardwareTier) -> Text {
        let name = ModelCatalog.languageModel(for: tier)?.displayName ?? ""
        return Text(StateText.tier(tier)) + Text(verbatim: " · \(name)")
            + (tier.isTested ? Text(verbatim: "") : Text(" · untested"))
    }

    private func tierChangeMessage(_ choice: TierChoice) -> String {
        let tier = choice.tier ?? model.recommendedTier ?? .comfort
        guard let pack = ModelCatalog.languageModel(for: tier) else { return "" }
        return String(localized: "The assistant will restart with \(pack.displayName). If it is not on this Mac yet, it will have to be downloaded (\(Units.bytes(pack.totalBytes))).")
    }
}

/// A coral outline that fades away, around the row "Choose another tier…" leads to.
private struct PointedAt: ViewModifier {
    let isOn: Bool
    @State private var faded = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.coral, lineWidth: 2)
                        .opacity(faded ? 0 : 1)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Palette.coral.opacity(faded ? 0 : 0.45), lineWidth: faded ? 24 : 0)
                        }
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard isOn else { return }
                withAnimation(.easeOut(duration: 1.8)) { faded = true }
            }
    }
}

/// "Delete the models?", shared by the settings and the problem screen.
struct DeleteModelsConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let delete: () -> Void

    func body(content: Content) -> some View {
        content.alert("Delete the models?", isPresented: $isPresented) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The assistant stops and its models are erased from this Mac. To use it again, they will have to be downloaded.")
        }
    }
}
