import AppKit
import SwiftUI
import VoiceCore

/// The single window: model download (first launch), loading, problem, or conversation; settings in a
/// popover, measurements in a side panel.
struct ContentView: View {
    @Bindable var model: AssistantModel
    @State private var showSettings = false
    @State private var showMeasurements = false

    var body: some View {
        Group {
            switch model.phase {
            case .loading(let step): LoadingView(step: step)
            case .setup(let setup): SetupView(model: model, setup: setup) { showSettings = true }
            case .problem(let problem):
                ProblemView(problem: problem, retry: model.start, deleteModels: model.deleteModels)
            case .ready: ConversationView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .inspector(isPresented: $showMeasurements) {
            DebugPanel(model: model)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showSettings.toggle() } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPanel(model: model) }
                Button { showMeasurements.toggle() } label: {
                    Label("Measurements", systemImage: "gauge.with.dots.needle.33percent")
                }
                .help("Measurements (latency of each stage)")
            }
        }
        .modifier(KeyboardControls(model: model))
        .task { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings after allowing the microphone: try again.
            if model.phase == .problem(.microphoneDenied) { model.start() }
        }
    }
}

struct ConversationView: View {
    @Bindable var model: AssistantModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                StateIndicator(state: model.state, inputLevel: model.inputLevel, outputLevel: model.outputLevel,
                               talkKeyDown: model.talkKeyDown)
                    .onTapGesture {
                        if model.state == .thinking || model.state == .speaking { model.stopSpeaking() }
                    }
                    .padding(.bottom, 6)
                Text(StateText.title(model.state, pushToTalk: model.settings.pushToTalk))
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                Text(StateText.hint(model.state, pushToTalk: model.settings.pushToTalk))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.2), value: model.state)

            Divider()
            TranscriptView(entries: model.transcript)

            if model.settings.pushToTalk {
                Divider()
                TalkButton(model: model)
                    .padding()
            }
        }
    }
}

/// Push-to-talk button: talk while it is held down.
struct TalkButton: View {
    let model: AssistantModel

    var body: some View {
        Text(model.talkKeyDown ? "Release to send" : "Hold to talk")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(model.talkKeyDown ? Color.green : Color.accentColor))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.setTalkKey(true) }
                .onEnded { _ in model.setTalkKey(false) })
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Hold the space bar to talk"))
    }
}

struct LoadingView: View {
    let step: LoadingStep?

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(StateText.loading(step))
                .font(.title3.weight(.medium))
            Text("The first launch can take a minute or two.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Space bar = push-to-talk (when enabled), Escape = silence the assistant.
struct KeyboardControls: ViewModifier {
    let model: AssistantModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    MainActor.assumeIsolated { handle(event) } ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Returns true when the key was used (so the system does not beep).
    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        guard model.isReady,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
        else { return false }
        switch event.keyCode {
        case 49 where model.settings.pushToTalk:  // space
            if event.type == .keyDown, !event.isARepeat { model.setTalkKey(true) }
            if event.type == .keyUp { model.setTalkKey(false) }
            return true
        case 53 where event.type == .keyDown:  // escape
            guard model.state == .thinking || model.state == .speaking else { return false }
            model.stopSpeaking()
            return true
        default:
            return false
        }
    }
}
