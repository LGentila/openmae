import SwiftUI
import VoiceCore

/// The few settings, in a popover from the toolbar.
struct SettingsPanel: View {
    @Bindable var model: AssistantModel

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
                    LabeledContent("Tier") { Text(StateText.tier(info.tier)) }
                    LabeledContent("Language model", value: info.languageModel)
                    if !info.tier.isTested {
                        Text("This tier could not be tested: performance is estimated.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
