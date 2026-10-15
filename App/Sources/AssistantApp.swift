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
    @State private var model: AssistantModel
    @State private var window = WindowState()

    init() {
        Fonts.register()
        #if DEBUG
        _model = State(initialValue: AssistantModel(connection: Demo.isOn ? DemoConnection() : AssistantHost()))
        #else
        _model = State(initialValue: AssistantModel(connection: AssistantHost()))
        #endif
    }

    var body: some Scene {
        Window(AppIdentity.name, id: "assistant") {
            Group {
                #if DEBUG
                if let folder = Snapshots.folder {
                    SnapshotRunner(folder: folder)
                } else {
                    ContentView(model: model, window: window)
                }
                #else
                ContentView(model: model, window: window)
                #endif
            }
            .frame(minWidth: 820, minHeight: 700)
            // The design has no dark theme yet: the window, its menus and alerts stay light.
            .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 960, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New conversation") { model.newConversation() }
                    .keyboardShortcut("n")
                    .disabled(!model.isReady)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { window.toggle(.settings) }
                    .keyboardShortcut(",")
            }
            CommandGroup(before: .sidebar) {
                Button(window.showMeasurements ? "Hide Measurements" : "Show Measurements") {
                    window.showMeasurements.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
