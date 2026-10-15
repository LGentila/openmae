import SwiftUI
import VoiceCore
import VoiceEngineApple

/// The app: one window, and the engine running in the same process.
///
/// This is the ONLY file of the interface that knows the engine's implementation (`AssistantHost`).
/// Everything else talks to an `AssistantConnection` through commands and events, so the engine can be
/// replaced (another platform, a separate process) without touching the screens.
@main
struct AssistantApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AssistantModel(connection: AssistantHost())

    var body: some Scene {
        Window(AppIdentity.name, id: "main") {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 560)
        }
        .defaultSize(width: 520, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New conversation") { model.newConversation() }
                    .keyboardShortcut("n")
                    .disabled(!model.isReady)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
