import AppKit
import Carbon.HIToolbox
import SwiftUI
import VoiceCore

/// Settings › Voice and sound: the output (speakers or headphones), how to talk to Maé, and the shortcut to talk from
/// another app (⌥ Space, or one the user records).
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
                Hairline()
                SettingRow("From another app") { TalkShortcutControl(model: model) }
                shortcutCaption
            }
        }
    }

    /// What the shortcut does; while another one is recorded, how; why it does not work, or why the keys just pressed
    /// cannot replace it.
    @ViewBuilder private var shortcutCaption: some View {
        if let refusal = model.talkShortcutRefusal {
            Caption(model.isRecordingTalkShortcut ? refusal.text + Text(verbatim: " ") + Text("Escape cancels.")
                : refusal.text, tone: .error)
        } else if model.isRecordingTalkShortcut {
            Caption("Press the new shortcut: ⌘, ⌥ or ⌃ with a key. Escape cancels.")
        } else if model.listensForWakeWord {
            Caption("Press once to talk, and again to finish. When the window is closed, Maé still waits for “OK Maé”.")
        } else {
            Caption("Press once to talk, and again to finish. When the window is closed, Maé only listens after this shortcut.")
        }
    }
}

/// The shortcut to talk from another app, drawn as a key. A click records another one: the next keys pressed, with ⌘,
/// ⌥ or ⌃ (Escape or a click cancels); "Back to ⌥ Space" undoes it. `DesktopPresence` registers and saves it.
struct TalkShortcutControl: View {
    @Bindable var model: AssistantModel
    /// The modifiers held while recording, shown before the key comes.
    @State private var held: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) { key }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityLabel(Text("Shortcut to talk"))
                .accessibilityValue(model.isRecordingTalkShortcut ? Text("New shortcut") : model.talkShortcut.title)
                .accessibilityHint(Text("Click, then press the new shortcut."))
            if !model.talkShortcut.isStandard, !model.isRecordingTalkShortcut {
                Button { DesktopPresence.current?.setTalkShortcut(.standard) } label: {
                    Text("Back to \(TalkShortcut.standard.title)")
                }
                .buttonStyle(WindowButtonStyle())
            }
        }
        .onChange(of: model.isRecordingTalkShortcut) { _, recording in
            if recording { startMonitor() } else { stopMonitor() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            DesktopPresence.current?.endRecordingTalkShortcut()
        }
        .onDisappear {
            DesktopPresence.current?.endRecordingTalkShortcut()
            stopMonitor()
        }
    }

    /// The key's 30-point cap; while recording, a 2-point outline and the modifiers held, or what to do.
    private var key: some View {
        let recording = model.isRecordingTalkShortcut
        let shape = RoundedRectangle(cornerRadius: Radius.key, style: .continuous)
        return Group {
            if !recording {
                model.talkShortcut.title.foregroundStyle(Palette.ink)
            } else if held.isEmpty {
                Text("New shortcut").foregroundStyle(Palette.inkMuted)
            } else {
                Text(verbatim: TalkShortcut.symbols(held)).foregroundStyle(Palette.ink)
            }
        }
        .textStyle(.key)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 11)
        .frame(minWidth: 72, minHeight: 30)
        .background(isHovered && !recording ? Palette.glassHover : Palette.white, in: shape)
        .overlay(shape.strokeBorder(recording ? Palette.ink : Palette.ink.opacity(0.14), lineWidth: recording ? 2 : 1))
        .contentShape(shape)
        .animation(.easeOut(duration: Timing.ui), value: recording)
        .animation(.easeOut(duration: Timing.ui), value: isHovered)
    }

    private func toggle() {
        guard let presence = DesktopPresence.current else { return }
        if model.isRecordingTalkShortcut {
            presence.endRecordingTalkShortcut()
        } else {
            presence.beginRecordingTalkShortcut()
        }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        held = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = []
    }

    /// Returns true when the event was the recording's: it goes no further (⌘W does not close the window, a click
    /// elsewhere only cancels).
    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        guard model.isRecordingTalkShortcut, let presence = DesktopPresence.current else { return false }
        switch event.type {
        case .leftMouseDown:
            presence.endRecordingTalkShortcut()
        case .flagsChanged:
            held = event.modifierFlags.intersection(TalkShortcut.modifierKeys)
        case .keyDown:
            guard !event.isARepeat else { return true }
            if Int(event.keyCode) == kVK_Escape, event.modifierFlags.isDisjoint(with: TalkShortcut.modifierKeys) {
                presence.endRecordingTalkShortcut()
            } else {
                presence.setTalkShortcut(TalkShortcut(event: event))
            }
        default:
            return false
        }
        return true
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
