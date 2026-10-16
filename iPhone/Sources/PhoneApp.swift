import SwiftUI
import VoiceCore

/// OpenMaé on the iPhone: the microphone, the speaker and the screen of OpenMaé on the Mac, which does the work.
/// Paired once with a QR code; then directly on the home Wi-Fi, through the relay elsewhere, encrypted end to end.
@main
struct PhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Fonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                // The design has no dark theme yet.
                .preferredColorScheme(.light)
                .followsWindowVisibility()
                // The pairing link, when the camera opened the app with it.
                .onOpenURL { model.scanned($0.absoluteString) }
                #if DEBUG
                // `-pair <link>`: pairs without the camera (the simulator has none).
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    if let i = arguments.firstIndex(of: "-pair"), i + 1 < arguments.count { model.scanned(arguments[i + 1]) }
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.wentToBackground()
            default: break
            }
        }
    }
}

/// Pairing until there is a Mac; then the conversation, or why it cannot happen; the settings over them.
struct RootView: View {
    @Bindable var model: PhoneModel

    var body: some View {
        Group {
            if model.mac == nil || isPairing {
                PairingScreen(model: model)
            } else if model.microphoneDenied {
                AlertScreen(model: model, kind: .microphone)
            } else if model.link == .unreachable {
                AlertScreen(model: model, kind: .unreachable)
            } else if model.phase == .setup {
                AlertScreen(model: model, kind: .setup)
            } else if model.phase == .problem {
                AlertScreen(model: model, kind: .problem)
            } else {
                ConversationScreen(model: model)
            }
        }
        .animation(.easeOut(duration: 0.3), value: screenKey)
        .fullScreenCover(isPresented: $model.showsSettings) {
            SettingsScreen(model: model)
                .preferredColorScheme(.light)
                .followsWindowVisibility()
        }
    }

    /// The "Done" screen stays until "Talk to Maé".
    private var isPairing: Bool {
        if case .done = model.pairing { return true }
        return false
    }

    private var screenKey: String {
        "\(model.mac == nil)-\(isPairing)-\(model.microphoneDenied)-\(String(describing: model.link))-\(model.phase)"
    }
}
