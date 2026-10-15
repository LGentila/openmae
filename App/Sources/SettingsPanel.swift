import SwiftUI
import VoiceCore

/// The few settings, in a popover from the toolbar.
struct SettingsPanel: View {
    @Bindable var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    /// Tier picked in the menu, waiting for confirmation: changing tier restarts the assistant.
    @State private var pendingTier: TierChoice?
    @State private var confirmDeletion = false

    var body: some View {
        Form {
            Section("Sound") {
                Picker("Output", selection: $model.settings.audioMode) {
                    ForEach(AudioMode.allCases, id: \.self) { mode in
                        Text(StateText.audioMode(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Group {
                    if model.settings.audioMode == .speakers {
                        Text("Echo cancellation keeps the assistant from hearing itself. Other apps are turned down slightly during the conversation.")
                    } else {
                        Text("With headphones there is no echo, so the microphone is used as is. Avoid this mode with speakers: the assistant would interrupt itself.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Toggle("Push to talk", isOn: $model.settings.pushToTalk)
                Text("Hold the space bar (or the button at the bottom of the window) while you speak. Useful in noisy places.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Conversation") {
                Button("New conversation") { model.newConversation() }
                    .disabled(!model.isReady)
            }
            if let info = model.info {
                Section("This Mac") {
                    LabeledContent("Chip and memory") {
                        Text(verbatim: "\(info.chip) · \(Units.memory(info.memoryGiB))")
                    }
                    LabeledContent("Tier") { Text(StateText.tier(info.tier)) }
                    LabeledContent("Language model", value: info.languageModel)
                    if !info.tier.isTested {
                        Text("This tier could not be tested: performance is estimated.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            advanced
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Change tier?", isPresented: Binding(get: { pendingTier != nil }, set: { if !$0 { pendingTier = nil } }),
               presenting: pendingTier)
        { choice in
            Button("Change") {
                model.settings.tierOverride = choice.tier
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text(tierChangeMessage(choice))
        }
        .modifier(DeleteModelsConfirmation(isPresented: $confirmDeletion) {
            model.deleteModels()
            dismiss()
        })
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
        Section("Advanced") {
            Picker("Tier", selection: Binding(
                get: { model.settings.tierOverride.map(TierChoice.forced) ?? .automatic },
                set: { choice in
                    if choice.tier != model.settings.tierOverride { pendingTier = choice }
                }))
            {
                if let recommended = model.recommendedTier {
                    Text("Automatic: \(Text(StateText.tier(recommended)))").tag(TierChoice.automatic)
                } else {
                    Text("Automatic").tag(TierChoice.automatic)
                }
                ForEach(HardwareTier.selectable, id: \.self) { tier in
                    tierLabel(tier).tag(TierChoice.forced(tier))
                }
            }
            .disabled(model.isLoading)
            Text("The tier decides the language model. “Automatic” picks the one that suits this Mac's memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let forced = model.settings.tierOverride, let recommended = model.recommendedTier, forced > recommended {
                Text("This tier needs more memory than this Mac has: the assistant may be very slow.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let storage = model.storage {
                LabeledContent("Models on this Mac", value: Units.bytes(storage.usedBytes))
                if storage.unusedBytes > 0 {
                    Button("Delete the other tiers' models (\(Units.bytes(storage.unusedBytes)))") {
                        model.deleteUnusedModels()
                    }
                }
            }
            Button("Delete the models…", role: .destructive) { confirmDeletion = true }
                .disabled(model.isLoading || (model.storage?.usedBytes ?? 0) == 0)
        }
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
