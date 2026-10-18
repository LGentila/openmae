import SwiftUI
import VoiceCore

/// Settings › Voice and sound: the output (speakers or headphones), how to talk to Maé, and the shortcut to talk from
/// another app.
struct VoicePage: View {
    @Bindable var model: AssistantModel

    var body: some View {
        SettingsPageScroll {
            PageHead(Text("Voice and sound"))
            PageIntro("How you talk to Maé, and how she answers you.")
            PageSection("Audio")
            SettingsCard {
                SettingRow("Output") { OutputChoice(model: model) }
                Group {
                    if model.settings.audioMode == .speakers {
                        Caption("Echo cancellation keeps Maé from hearing herself. Other apps are turned down slightly during the conversation.")
                    } else {
                        Caption("With headphones there is no echo, so the microphone is used as is. Avoid this mode with speakers: Maé would interrupt herself.")
                    }
                }
            }
            PageSection("Talk")
            SettingsCard {
                SettingRow("How to talk") { ListeningMenu(model: model) }
                Group {
                    switch model.settings.listening {
                    case .handsFree:
                        Caption("Maé answers as soon as she hears someone speak.")
                    case .wakeWord:
                        Caption("Maé answers sentences that start with “OK Maé”, then listens a few seconds more. The TV on hinders her; plugged in, this Mac no longer sleeps.")
                    case .pushToTalk:
                        Caption("Hold the space bar (or the button at the bottom of the window) while you speak. Useful in noisy places.")
                    }
                }
                if model.hasTalkShortcut {
                    Hairline()
                    SettingRow("From another app") { ShortcutKey(title: Text("⌥ Space")) }
                        .accessibilityElement(children: .combine)
                    if model.listensForWakeWord {
                        Caption("Press once to talk, and again to finish. When the window is closed, Maé still waits for “OK Maé”.")
                    } else {
                        Caption("Press once to talk, and again to finish. When the window is closed, Maé only listens after this shortcut.")
                    }
                }
            }
        }
    }
}

/// Speakers or headphones, shared by the page and the quick panel.
struct OutputChoice: View {
    @Bindable var model: AssistantModel

    var body: some View {
        WindowSegmented(selection: $model.settings.audioMode,
                        options: AudioMode.allCases.map { (value: $0, title: StateText.audioMode($0)) },
                        label: Text("Audio output"))
    }
}

/// Hands-free, after « OK Maé », or push to talk; shared by the page and the quick panel.
struct ListeningMenu: View {
    @Bindable var model: AssistantModel

    var body: some View {
        PopUpMenu(title: Text(StateText.listening(model.settings.listening)), label: Text("How to talk")) {
            Picker(selection: $model.settings.listening) {
                ForEach(ListeningMode.allCases, id: \.self) { mode in
                    Text(StateText.listening(mode)).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
