import OpenMaeLink
import SwiftUI
import VoiceCore

/// The conversation: the orb in the middle, the live transcript under it, the main button at the bottom.
/// While the models load, the same screen shows the orb at rest and what is loading.
struct ConversationView: View {
    let model: AssistantModel
    /// The models are loading: the orb waits at rest and the transcript says what is loading.
    var isLoading = false
    var loadingStep: LoadingStep?
    /// An iPhone may have the conversation (nil in the screens' still pictures).
    @Environment(PhoneAccess.self) private var phone: PhoneAccess?

    var body: some View {
        let state = isLoading ? PipelineState.listening : model.state
        let exchange = model.currentExchange
        VStack(spacing: 0) {
            OrbStage(model: model, state: isLoading ? .listening : model.shownState)
            LiveTranscript(state: state, user: exchange.user, answer: exchange.answer, invitation: invitation)
                .frame(height: 150)
            ConversationControls(model: model, isLoading: isLoading, phone: isLoading ? nil : phone)
                .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            if let hand = phone?.hand, !isLoading {
                OnPhoneBanner(path: hand.path)
                    .offset(y: 4)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: phone?.hand)
    }

    private var invitation: LiveTranscript.Invitation {
        if isLoading { return .loading(loadingStep) }
        if phone?.hand != nil { return .onPhone }
        let shortcut = model.hasTalkShortcut
        switch model.settings.listening {
        case .handsFree: return .speak(orShortcut: shortcut)
        case .wakeWord: return model.isAwake ? .awake : .sayWakeWord(orShortcut: shortcut)
        case .pushToTalk: return .holdSpace(orShortcut: shortcut)
        }
    }

}

/// The 380-point stage of the orb. A click on it silences Maé.
private struct OrbStage: View {
    let model: AssistantModel
    let state: PipelineState
    @Environment(\.windowIsVisible) private var windowIsVisible

    var body: some View {
        Orb(look: OrbLook(state), level: level)
            .contentShape(Circle().inset(by: 60))
            .onTapGesture {
                if state == .thinking || state == .speaking { model.stopSpeaking() }
            }
            .anchorPreference(key: OrbPlacement.self, value: .bounds) {
                OrbPlacement.Orb(anchor: $0, halo: (560, 800))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StateText.accessibilityName(state))
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// The level of whoever is speaking. Not read while the window cannot be seen: it changes twenty times a
    /// second, and each change would redraw the window for nothing.
    private var level: Float {
        guard windowIsVisible else { return 0 }
        switch state {
        case .userSpeaking: return model.inputLevel
        case .speaking: return model.outputLevel
        case .listening, .thinking: return 0
        }
    }
}

/// The main button. Its label says what it does in each state: talk (push-to-talk), finish, cancel the
/// answer being prepared, interrupt Maé. Without push-to-talk there is nothing to press while the assistant
/// listens (except to finish a turn started with the global shortcut): the button only appears once Maé thinks
/// or speaks.
private struct ConversationControls: View {
    let model: AssistantModel
    let isLoading: Bool
    let phone: PhoneAccess?

    private enum Action: Equatable {
        case talk(held: Bool)
        case cancel
        case interrupt
        /// An iPhone has the conversation: the Mac can take it back.
        case takeBack
    }

    var body: some View {
        ZStack {
            if let action {
                let glow = StatePalette(model.state).glow
                switch action {
                case .takeBack:
                    VStack(spacing: 12) {
                        Button { phone?.takeBack() } label: { Text("Take over here") }
                            .buttonStyle(PrimaryButtonStyle(icon: .laptop, disc: glow))
                        Text("The conversation goes on on your iPhone until you take over.")
                            .textStyle(.note)
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                case .talk(let held):
                    HoldToTalk(held: held, glow: glow) { model.setTalkKey($0) }
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                case .cancel, .interrupt:
                    Button { model.stopSpeaking() } label: {
                        Text(action == .cancel ? "Cancel" : "Interrupt")
                    }
                    .buttonStyle(PrimaryButtonStyle(icon: action == .cancel ? .cancel : .pause, disc: glow))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: action)
    }

    private var action: Action? {
        guard !isLoading, model.isReady else { return nil }
        if phone?.hand != nil { return .takeBack }
        switch model.state {
        case .thinking: return .cancel
        case .speaking: return .interrupt
        case .listening, .userSpeaking:
            guard model.settings.listening == .pushToTalk || model.talkKeyDown else { return nil }
            return .talk(held: model.talkKeyDown || model.state == .userSpeaking)
        }
    }
}

/// Push-to-talk: talk while the button is held down (like the space bar).
private struct HoldToTalk: View {
    let held: Bool
    let glow: RGBA
    let press: (Bool) -> Void
    @State private var isPressed = false

    var body: some View {
        PrimaryPill(icon: held ? .stop : .microphone, iconStroke: held ? nil : 2, disc: glow, isPressed: isPressed) {
            Text(held ? "Finish" : "Talk")
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                press(true)
            }
            .onEnded { _ in
                isPressed = false
                press(false)
            })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Hold the space bar to talk"))
    }
}

/// "Maé is on your iPhone · At home": shown while an iPhone has the conversation.
private struct OnPhoneBanner: View {
    let path: LinkPath

    var body: some View {
        HStack(spacing: 10) {
            IconView(icon: .phone, size: 20)
            Text("Maé is on your iPhone")
                .textStyle(.onPhoneBanner)
            Rectangle()
                .fill(Palette.lineStrong)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)
            Group {
                switch path {
                case .direct: Text("At home")
                case .relay: Text("Away")
                }
            }
            .textStyle(.chip)
            .foregroundStyle(Palette.inkMuted)
        }
        .foregroundStyle(Palette.ink)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 40)
        .background(Palette.white, in: Capsule())
        .hairline(Capsule())
        .shadow(color: Palette.ink.opacity(0.08).color, radius: 8, y: 6)
        .accessibilityElement(children: .combine)
    }
}

extension TextStyle {
    static let onPhoneBanner = TextStyle(.display, 17, weight: 600, lineHeight: 22, letterSpacing: -0.01)
}
