import OpenMaeLink
import SwiftUI
import VoiceCore

/// "Automatic" or a forced tier.
enum TierChoice: Hashable {
    case automatic
    case forced(HardwareTier)

    var tier: HardwareTier? {
        if case .forced(let tier) = self { return tier }
        return nil
    }
}

/// Settings › Advanced: the tier, the models on this Mac and their deletion, the log of « OK Maé » in that mode, and the
/// port of OpenMaé's internal door while it is the home path. The tier is locked, and the deletions disabled, while the
/// models load or download.
struct AdvancedPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    @State private var wakeLogExists = WakeLog.exists
    @Environment(InboundAccess.self) private var inbound: InboundAccess?

    private var isBusy: Bool { model.isLoading || model.isDownloading }

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Advanced"))
            PageIntro("The models that run Maé on this Mac, and what she notes for you.")
            if model.isDownloading, let download = model.download, download.totalBytes > 0 {
                let fraction = Double(download.doneBytes) / Double(download.totalBytes)
                Note(Text("First download of the models: \(Int(fraction * 100))%. The tier is locked until the end."))
                    .padding(.top, 16)
                ProgressTrack(fraction: fraction)
                    .padding(EdgeInsets(top: 10, leading: 4, bottom: 0, trailing: 4))
            }
            PageSection("Models")
            SettingsCard { models }
            if model.listensForWakeWord {
                PageSection("“OK Maé” log")
                SettingsCard { wakeLog }
            }
            if let inbound, inbound.status.homePath == .door {
                PageSection("Internal door")
                SettingsCard { DoorPortRows(inbound: inbound) }
            }
        }
        .onChange(of: navigation.sheet) { wakeLogExists = WakeLog.exists }
        .onChange(of: model.settings.wakeLog) { wakeLogExists = WakeLog.exists }
    }

    // MARK: - Models

    @ViewBuilder private var models: some View {
        SettingRow("Tier") { tierMenu }
            .padding(.horizontal, 8)
            .modifier(PointedAt(token: navigation.tierPointer))
            .padding(.horizontal, -8)
        Caption("The tier decides the language model. “Automatic” picks the one that suits this Mac's memory.")
        if let tier = model.tier, !tier.isTested {
            Caption("This tier could not be tested: performance is estimated.")
        }
        if let forced = model.settings.tierOverride, let recommended = model.recommendedTier, forced > recommended {
            Caption("This tier needs more memory than this Mac has: the assistant may be very slow.", tone: .error)
        }
        Hairline()
        SettingRow("Models on this Mac") {
            Text(verbatim: Units.bytes(model.storage?.usedBytes))
                .textStyle(.value)
                .foregroundStyle(Palette.ink)
        }
        Hairline()
        ActionRow(top: 12, bottom: 14) {
            if let storage = model.storage, storage.unusedBytes > 0 {
                Button("Delete the other tiers' models (\(Units.bytes(storage.unusedBytes)))") {
                    model.deleteUnusedModels()
                }
                .buttonStyle(WindowButtonStyle())
                .disabled(isBusy)
            }
            Button("Delete the models…") { navigation.sheet = .deleteModels }
                .buttonStyle(WindowButtonStyle(kind: .danger))
                .disabled(isBusy || (model.storage?.usedBytes ?? 0) == 0)
        }
    }

    /// The tier's pop-up menu; locked while models load or download.
    private var tierMenu: some View {
        PopUpMenu(title: model.settings.tierOverride.map { Text(StateText.tier($0)) } ?? automaticLabel,
                  label: Text("Tier"))
        {
            Picker(selection: Binding(
                get: { model.settings.tierOverride.map(TierChoice.forced) ?? .automatic },
                set: { choice in
                    if choice.tier != model.settings.tierOverride { navigation.sheet = .changeTier(choice) }
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
        }
        .disabled(isBusy)
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

    // MARK: - The log of « OK Maé »

    /// What Maé heard in the wake-word mode, for the user's tests.
    @ViewBuilder private var wakeLog: some View {
        SwitchRow("Note what Maé hears", isOn: $model.settings.wakeLog)
        Caption("For your tests of “OK Maé”: the start of each sentence Maé hears, and what she did with it, is written in a file on this Mac.")
        Hairline()
        ActionRow(top: 12, bottom: 14) {
            Button("Show the log") { WakeLog.show() }
                .buttonStyle(WindowButtonStyle())
            Button("Erase the log…") { navigation.sheet = .eraseWakeLog }
                .buttonStyle(WindowButtonStyle())
        }
        .disabled(!wakeLogExists)
    }
}

/// The port OpenMaé's internal door listens on (Settings › Received information): 47321 unless changed here.
private struct DoorPortRows: View {
    let inbound: InboundAccess
    @State private var text = ""
    @State private var isRefused = false

    private var current: UInt16 { inbound.status.doorPort }

    /// What was typed, when it is a port the door may take.
    private var typed: UInt16? {
        UInt16(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 1024 ? $0 : nil }
    }

    var body: some View {
        SettingRow("Port") {
            HStack(spacing: 10) {
                TextField(text: $text, prompt: placeholder(Text(verbatim: String(InboundHost.defaultDoorPort)))) {
                    Text("Port of the internal door")
                }
                .windowField(mono: true, isRefused: isRefused)
                .frame(width: 104)
                .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(WindowButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || typed == current)
            }
        }
        .onAppear { text = String(current) }
        .onChange(of: current) { _, port in text = String(port) }
        if isRefused {
            Caption("A port is a number from 1024 to 65535.", tone: .error)
        } else {
            Caption(Text("\(String(InboundHost.defaultDoorPort)) by default. Changing it changes the addresses of your home sources: paste them again in the other systems."))
        }
    }

    private func save() {
        guard let port = typed else {
            isRefused = true
            return
        }
        isRefused = false
        inbound.setDoorPort(port)
    }
}

/// A coral outline that fades away in 1.8 s, around the row "Choose another tier…" leads to; again each time `token`
/// changes.
private struct PointedAt: ViewModifier {
    let token: Int
    @State private var faded = true

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.coral, lineWidth: 2)
                    .opacity(faded ? 0 : 1)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Palette.coral.opacity(faded ? 0 : 0.45), lineWidth: faded ? 24 : 0)
                    }
                    .allowsHitTesting(false)
            }
            .onAppear { point() }
            .onChange(of: token) { point() }
    }

    private func point() {
        guard token > 0 else { return }
        faded = false
        withAnimation(.easeOut(duration: 1.8)) { faded = true }
    }
}

// MARK: - Sheets

/// "Change tier?": the assistant restarts with the tier's model, downloaded first if needed.
struct ChangeTierSheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    let choice: TierChoice

    var body: some View {
        SheetCard(width: 460, title: Text("Change tier?"), text: Text(message)) {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Change") {
                model.settings.tierOverride = choice.tier
                navigation.sheet = nil
            }
            .buttonStyle(WindowButtonStyle(kind: .main))
            .keyboardShortcut(.defaultAction)
        }
    }

    private var message: String {
        let tier = choice.tier ?? model.recommendedTier ?? .comfort
        guard let pack = ModelCatalog.languageModel(for: tier) else { return "" }
        return String(localized: "The assistant will restart with \(pack.displayName). If it is not on this Mac yet, it will have to be downloaded (\(Units.bytes(pack.totalBytes))).")
    }
}

/// "Delete the models?": Maé stops until they are downloaded again.
struct DeleteModelsSheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Delete the models?"),
                  text: Text("Maé will no longer be able to speak until you download them again (\(Units.bytes(model.storage?.usedBytes)))."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Delete") {
                navigation.sheet = nil
                model.deleteModels()
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}

/// "Erase the log?".
struct EraseWakeLogSheet: View {
    let navigation: SettingsNavigation

    var body: some View {
        SheetCard(width: 460, title: Text("Erase the log?"),
                  text: Text("What Maé noted of the sentences she heard is erased from this Mac."))
        {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Erase") {
                WakeLog.delete()
                navigation.sheet = nil
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }
}

/// "Delete the models?" as an alert, for the problem screen.
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
