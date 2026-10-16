import SwiftUI
import VoiceCore

/// The conversation: the orb in the middle, the live transcript under it, the main button at the bottom.
/// While the models load, the same screen shows the orb at rest and what is loading.
struct ConversationView: View {
    let model: AssistantModel
    /// The models are loading: the orb waits at rest and the transcript says what is loading.
    var isLoading = false
    var loadingStep: LoadingStep?

    var body: some View {
        let state = isLoading ? PipelineState.listening : model.state
        let exchange = model.currentExchange
        VStack(spacing: 0) {
            OrbStage(model: model, state: state)
            LiveTranscript(state: state, user: exchange.user, answer: exchange.answer, invitation: invitation)
                .frame(height: 150)
            ConversationControls(model: model, isLoading: isLoading)
                .frame(maxHeight: .infinity)
        }
    }

    private var invitation: LiveTranscript.Invitation {
        if isLoading { return .loading(loadingStep) }
        let shortcut = model.hasTalkShortcut
        return model.settings.pushToTalk ? .holdSpace(orShortcut: shortcut) : .speak(orShortcut: shortcut)
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

    private enum Action: Equatable {
        case talk(held: Bool)
        case cancel
        case interrupt
    }

    var body: some View {
        ZStack {
            if let action {
                let glow = StatePalette(model.state).glow
                switch action {
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
        switch model.state {
        case .thinking: return .cancel
        case .speaking: return .interrupt
        case .listening, .userSpeaking:
            guard model.settings.pushToTalk || model.talkKeyDown else { return nil }
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
