import SwiftUI
import VoiceCore

/// Settings › Advanced: the tier, the models on this Mac and their deletion, and the log of « OK Maé » in that mode.
/// The tier is locked, and the deletions disabled, while the models load or download.
struct AdvancedPage: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    @State private var wakeLogExists = WakeLog.exists

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
        }
        .onChange(of: navigation.sheet) { wakeLogExists = WakeLog.exists }
        .onChange(of: model.settings.wakeLog) { wakeLogExists = WakeLog.exists }
    }

    // MARK: - Models

    @ViewBuilder private var models: some View {
        SettingRow("Tier") {
            // Locked while models load or download; another tier is confirmed first ("Change tier?").
            TierMenu(override: model.settings.tierOverride, recommended: model.recommendedTier,
                     onThisMac: model.storage?.tiersOnThisMac ?? [])
            {
                navigation.sheet = .changeTier($0)
            }
            .disabled(isBusy)
        }
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
        // One by one: those the tier uses are in use; another tier's can be deleted on its own.
        ForEach(model.storage?.models ?? []) { entry in
            Hairline()
            ModelItem(entry: entry, isBusy: isBusy, isDownloading: model.isDownloading) {
                navigation.sheet = .deleteModel(entry.id)
            }
        }
        Hairline()
        ActionRow(top: 12, bottom: 14) {
            Button("Delete the models…") { navigation.sheet = .deleteModels }
                .buttonStyle(WindowButtonStyle(kind: .danger))
                .disabled(isBusy || (model.storage?.usedBytes ?? 0) == 0)
        }
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

/// A model on this Mac: what it is for and how much space it takes; "In use" (or, the tier's own not all there yet,
/// "Downloading" or "To download"), or its Delete button.
private struct ModelItem: View {
    let entry: ModelStorage.Model
    /// Models load or download: nothing can be deleted.
    let isBusy: Bool
    let isDownloading: Bool
    let delete: () -> Void

    var body: some View {
        ListItem(disc: Self.disc(entry.role), name: { Text(verbatim: entry.displayName) }, sub: sub, trailing: {
            if entry.inUse {
                HStack(spacing: 8) {
                    StatusDot(tone: entry.missingBytes == 0 ? .on : .info)
                    Group {
                        if entry.missingBytes == 0 {
                            Text("In use")
                        } else if isDownloading {
                            Text("Downloading")
                        } else {
                            Text("To download")
                        }
                    }
                    .textStyle(.itemState)
                    .foregroundStyle(Palette.ink)
                    .fixedSize()
                }
                .accessibilityElement(children: .combine)
            } else {
                Button("Delete…", action: delete)
                    .buttonStyle(WindowButtonStyle(kind: .danger))
                    .disabled(isBusy)
                    .accessibilityLabel(Text("Delete \(entry.displayName)…"))
            }
        })
        .accessibilityElement(children: .contain)
    }

    /// "Language model of the Standard tier · 5.18 GB", "Voice · 1.67 GB"; "· incomplete" for another tier's model whose
    /// download did not end (the tier's own says it on the right).
    private var sub: Text {
        var parts = [Self.purpose(entry), Text(verbatim: Units.bytes(entry.bytes))]
        if entry.missingBytes > 0, !entry.inUse { parts.append(Text("incomplete")) }
        // No-break spaces around the dot: a line never starts with it.
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(verbatim: "\u{00A0}·\u{00A0}") + $1 }
    }

    static func purpose(_ entry: ModelStorage.Model) -> Text {
        if entry.role == .languageModel, let tier = tier(of: entry) {
            return Text("Language model of the \(Text(tierName(tier))) tier")
        }
        return Text(StateText.role(entry.role))
    }

    /// The tier whose language model it is.
    static func tier(of entry: ModelStorage.Model) -> HardwareTier? {
        HardwareTier.selectable.first { ModelCatalog.languageModel(for: $0)?.id == entry.id }
    }

    /// The tier's name, without the memory it suits (which would read like the model's size).
    static func tierName(_ tier: HardwareTier) -> LocalizedStringKey {
        switch tier {
        case .unsupported: "Not supported"
        case .minimum: "Minimum"
        case .standard: "Standard"
        case .comfort: "Comfort"
        case .max: "Maximum"
        }
    }

    /// The colour and icon of the first-launch screen's rows: blue for speech recognition, coral for the voice, sun for
    /// the language model.
    private static func disc(_ role: ModelRole) -> FamilyDisc {
        switch role {
        case .speechRecognition: FamilyDisc(icon: .microphone, color: Palette.azureSoft)
        case .voice: FamilyDisc(icon: .speaker, color: Palette.coralSoft)
        case .languageModel: FamilyDisc(icon: .sparkles, color: Palette.sunSoft)
        }
    }
}

extension ModelStorage {
    /// The tiers whose models are all on this Mac: choosing one downloads nothing.
    var tiersOnThisMac: Set<HardwareTier> {
        Set(HardwareTier.selectable.filter { hasComplete(ModelCatalog.packs(for: $0)) })
    }

    /// What choosing `tier` would download, partial downloads counted for what they hold.
    func bytesToDownload(for tier: HardwareTier) -> Int64 {
        ModelCatalog.packs(for: tier).reduce(0) { total, pack in
            total + (models.first { $0.id == pack.id }?.missingBytes ?? pack.totalBytes)
        }
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
        guard let storage = model.storage else {
            return String(localized: "The assistant will restart with \(pack.displayName). If it is not on this Mac yet, it will have to be downloaded (\(Units.bytes(pack.totalBytes))).")
        }
        if storage.tiersOnThisMac.contains(tier) {
            return String(localized: "The assistant will restart with \(pack.displayName), already on this Mac.")
        }
        return String(localized: "The assistant will restart with \(pack.displayName). It has to be downloaded first (\(Units.bytes(storage.bytesToDownload(for: tier)))).")
    }
}

/// "Delete Gemma 4 E4B?": one model of another tier, which that tier downloads again when it is chosen.
struct DeleteModelSheet: View {
    @Bindable var model: AssistantModel
    let navigation: SettingsNavigation
    let entry: ModelStorage.Model

    var body: some View {
        SheetCard(width: 460, title: Text("Delete \(entry.displayName)?"), text: text) {
            EmptyView()
        } footer: {
            Button("Cancel") { navigation.sheet = nil }
                .buttonStyle(WindowButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Delete") {
                navigation.sheet = nil
                model.deleteModel(entry.id)
            }
            .buttonStyle(WindowButtonStyle(kind: .solidDanger))
        }
    }

    private var text: Text {
        let size = Units.bytes(entry.bytes)
        guard let tier = ModelItem.tier(of: entry) else { return Text("This frees \(size) on this Mac.") }
        return Text("This frees \(size) on this Mac. If you choose the \(Text(ModelItem.tierName(tier))) tier later, it will be downloaded again.")
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
