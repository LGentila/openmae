import AppKit
import SwiftUI
import VoiceCore

/// What the window shows on top of its screen: a panel (settings or conversation) and the measurements.
/// Shared with the menu commands.
@MainActor
@Observable
final class WindowState {
    enum Panel: Hashable { case settings, history }

    var panel: Panel?
    /// The settings were opened from "Choose another tier…": the tier row is pointed at.
    var pointsAtTier = false
    var showMeasurements = false

    func toggle(_ panel: Panel, pointingAtTier: Bool = false) {
        if self.panel == panel {
            self.panel = nil
        } else {
            self.panel = panel
            pointsAtTier = pointingAtTier
        }
    }
}

/// The single window: model download (first launch), loading, problem, or conversation, under a top bar
/// with the logo; settings and conversation in panels, measurements in a side panel.
struct ContentView: View {
    @Bindable var model: AssistantModel
    @Bindable var window: WindowState

    var body: some View {
        VStack(spacing: 0) {
            topBar
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .backgroundPreferenceValue(OrbPlacement.self) { placement in
            GeometryReader { proxy in
                ZStack {
                    surface.color
                        .animation(Easing.animation(Easing.ease, Timing.surface), value: surface)
                    if let placement {
                        OrbHalos(inner: placement.halo.inner, outer: placement.halo.outer)
                            .position(x: proxy[placement.anchor].midX, y: proxy[placement.anchor].midY)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .overlayPreferenceValue(PanelButtons.self) { buttons in
            PanelLayer(model: model, window: window, buttons: buttons)
        }
        .inspector(isPresented: $window.showMeasurements) {
            DebugPanel(model: model)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .modifier(KeyboardControls(model: model, window: window))
        .task { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings after allowing the microphone: try again.
            if model.phase == .problem(.microphoneDenied) { model.start() }
        }
        .onChange(of: model.phase) { window.panel = nil }
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .loading(let step):
            ConversationView(model: model, isLoading: true, loadingStep: step)
        case .setup(let setup):
            SetupView(model: model, setup: setup) { window.toggle(.settings, pointingAtTier: true) }
        case .problem(let problem):
            ProblemView(problem: problem, retry: model.start, deleteModels: model.deleteModels)
        case .ready:
            ConversationView(model: model)
        }
    }

    private var isSetup: Bool {
        if case .setup = model.phase { return true }
        return false
    }

    /// The window's background follows the conversation; every other screen is at rest.
    private var surface: RGBA {
        StatePalette(model.isReady ? model.state : .listening).surface
    }

    /// First launch: settings and measurements. Conversation: its history and the settings.
    private var topBar: some View {
        TopBar(height: isSetup ? 56 : 60) {
            if isSetup {
                settingsButton(diameter: 38)
                Button { window.showMeasurements.toggle() } label: { IconView(icon: .performance, size: 20) }
                    .buttonStyle(GlassButtonStyle(diameter: 38, isOn: window.showMeasurements))
                    .accessibilityLabel(Text("Performance"))
                    .help(Text("Measurements (latency of each stage)"))
            } else {
                Button { window.toggle(.history) } label: { IconView(icon: .history, size: 20) }
                    .buttonStyle(GlassButtonStyle(diameter: 40, isOn: window.panel == .history))
                    .accessibilityLabel(Text("Conversation history"))
                    .help(Text("Conversation history"))
                    .anchorPreference(key: PanelButtons.self, value: .bounds) { [.history: $0] }
                settingsButton(diameter: 40)
            }
        }
    }

    private func settingsButton(diameter: CGFloat) -> some View {
        Button { window.toggle(.settings) } label: { IconView(icon: .settings, size: 20) }
            .buttonStyle(GlassButtonStyle(diameter: diameter, isOn: window.panel == .settings))
            .accessibilityLabel(Text("Settings"))
            .help(Text("Settings"))
            .anchorPreference(key: PanelButtons.self, value: .bounds) { [.settings: $0] }
    }
}

/// The bar at the top of the window: the logo in the middle, round buttons on the right. The window can
/// be moved by it (the window has no title bar of its own; its buttons stay on the left).
struct TopBar<Buttons: View>: View {
    var height: CGFloat = 60
    @ViewBuilder let buttons: Buttons

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Logo()
            HStack(spacing: 10) {
                Spacer()
                buttons
            }
            .padding(.trailing, 18)
        }
        .frame(height: height)
    }
}

// MARK: - Panels

/// Where the round buttons that open a panel are, for the panel's point.
struct PanelButtons: PreferenceKey {
    static var defaultValue: [WindowState.Panel: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [WindowState.Panel: Anchor<CGRect>],
                       nextValue: () -> [WindowState.Panel: Anchor<CGRect>])
    {
        value.merge(nextValue()) { $1 }
    }
}

/// Where the orb is, so that its halos are drawn behind everything else (the top bar included).
struct OrbPlacement: PreferenceKey {
    struct Orb {
        var anchor: Anchor<CGRect>
        var halo: (inner: CGFloat, outer: CGFloat)
    }

    static var defaultValue: Orb? { nil }

    static func reduce(value: inout Orb?, nextValue: () -> Orb?) {
        value = value ?? nextValue()
    }
}

/// The open panel, below its button; a click anywhere else closes it.
private struct PanelLayer: View {
    @Bindable var model: AssistantModel
    let window: WindowState
    let buttons: [WindowState.Panel: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if let panel = window.panel, let anchor = buttons[panel] {
                    let button = proxy[anchor]
                    let top = button.maxY + 15
                    let leading = proxy.size.width - 14 - PanelChrome<EmptyView>.width
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { window.panel = nil }
                        .accessibilityHidden(true)
                    PanelChrome(pointerX: button.midX - leading, maxHeight: proxy.size.height - top - 14,
                                startsAtBottom: panel == .history)
                    {
                        switch panel {
                        case .settings:
                            SettingsPanel(model: model, pointsAtTier: window.pointsAtTier) { window.panel = nil }
                        case .history:
                            HistoryPanel(entries: model.transcript)
                        }
                    }
                    .padding(.top, top)
                    .padding(.trailing, 14)
                    .transition(.asymmetric(
                        insertion: .modifier(active: PanelOpening(progress: 0, pointerX: button.midX - leading),
                                             identity: PanelOpening(progress: 1, pointerX: button.midX - leading)),
                        removal: .opacity.animation(.easeOut(duration: 0.15))))
                    .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .animation(Easing.animation(CubicBezier(0.2, 1.2, 0.4, 1), 0.35), value: window.panel)
        }
    }
}

/// A panel appears from its point: it grows from 94 %, comes down 6 points and fades in.
private struct PanelOpening: ViewModifier {
    let progress: Double
    let pointerX: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.94 + 0.06 * progress,
                         anchor: UnitPoint(x: pointerX / PanelChrome<EmptyView>.width, y: 0))
            .offset(y: -6 * (1 - progress))
            .opacity(progress)
    }
}

// MARK: - Keyboard

/// Space bar = push-to-talk (when enabled), Escape = close a panel, or silence the assistant.
struct KeyboardControls: ViewModifier {
    let model: AssistantModel
    let window: WindowState
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
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
        else { return false }
        if event.keyCode == 53, event.type == .keyDown, window.panel != nil {  // escape
            window.panel = nil
            return true
        }
        guard model.isReady else { return false }
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
