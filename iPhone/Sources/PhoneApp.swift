import SwiftUI
import VoiceCore

/// OpenMaé on the iPhone and the iPad: the microphone, the speaker and the screen of OpenMaé on the Mac, which does
/// the work. Paired once with a QR code; then directly on the home Wi-Fi, through the relay elsewhere, encrypted end to
/// end. An iPad can also be a home station (`PhoneModel.stationMode`).
@main
struct PhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Fonts.register()
    }

    var body: some Scene {
        WindowGroup {
            content
                // The design has no dark theme yet.
                .preferredColorScheme(.light)
                .followsWindowVisibility()
                // The pairing link, when the iPhone's Camera opened the app with it (a universal link): SwiftUI hands
                // it over here, at launch as when the app was running.
                .onOpenURL { model.opened($0) }
                #if DEBUG
                // `-pair <link>`: as if the link had opened the app (the simulator has no camera).
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    if let i = arguments.firstIndex(of: "-pair"), i + 1 < arguments.count,
                       let url = URL(string: arguments[i + 1])
                    {
                        model.opened(url)
                    }
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

    @ViewBuilder private var content: some View {
        #if DEBUG
        if let screen = PhoneScreenshots.requested {
            // Still pictures: the settings drawn on their own (a full-screen cover would not turn with the frame).
            ScreenshotFrame {
                if screen == "settings" { SettingsScreen(model: model) } else { RootView(model: model) }
            }
        } else {
            RootView(model: model)
        }
        #else
        RootView(model: model)
        #endif
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
            } else if model.isStation, !model.isConversationOpen {
                StationScreen(model: model)
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
        // Another Mac's code opened the app.
        .alert(replacementTitle, isPresented: replacementAsked, presenting: model.replacement) { replacement in
            Button("Link") { model.replace(with: replacement.link) }
            Button("Cancel", role: .cancel) { model.replace(with: nil) }
        } message: { replacement in
            Text("It will forget “\(replacement.current)”: it talks to one Mac at a time.")
        }
    }

    /// A pairing, and its outcome: also over a paired Mac's screens, since the Mac's code can open the app at any time
    /// (the iPhone's Camera). The "Done" screen stays until "Talk to Maé".
    private var isPairing: Bool { model.pairing != .scanning }

    private var replacementAsked: Binding<Bool> {
        Binding(get: { model.replacement != nil }, set: { if !$0 { model.replace(with: nil) } })
    }

    private var replacementTitle: Text {
        let name = model.replacement?.link.macName ?? ""
        return model.isPad ? Text("Link this iPad to “\(name)”?") : Text("Link this iPhone to “\(name)”?")
    }

    private var screenKey: String {
        "\(model.mac == nil)-\(isPairing)-\(model.microphoneDenied)-\(String(describing: model.link))-\(model.phase)"
            + "-\(model.isStation && !model.isConversationOpen)"
    }
}
