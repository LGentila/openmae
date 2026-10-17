import OpenMaeLink
import SwiftUI
import UserNotifications
import VoiceCore
import VoiceEngineApple

/// The app: one window, the engine running in the same process, and, outside the window, an icon in the menu bar,
/// the ⌥ Space shortcut and the capsule (DesktopPresence.swift).
///
/// This is the ONLY file of the interface that knows the engine's implementation (`AssistantHost`).
/// Everything else talks to an `AssistantConnection` through commands and events, so the engine can be
/// replaced (another platform, a separate process) without touching the screens. That connection is the link
/// with the iPhone (`LinkHost`), which passes everything on to the engine.
@main
struct AssistantApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AssistantModel
    @State private var window = WindowState()
    @State private var presence: DesktopPresence
    @State private var phone: PhoneAccess
    @State private var inbound: InboundAccess

    init() {
        Fonts.register()
        #if DEBUG
        let engine: any AssistantConnection = Demo.isOn ? DemoConnection()
            : AssistantHost(actionsTestCollection: ActionsTestCollection.name,
                            agentsTestFolder: ActionsTestCollection.agentsFolder)
        #else
        let engine = AssistantHost()
        #endif
        // The demonstration engine has no sound to hand over: an iPhone then only sees and commands it.
        let identityStore = KeychainIdentityStore(service: "OpenMaé link")
        let link = LinkHost(engine: engine, audio: engine as? any RemoteAudioRouting, identityStore: identityStore,
                            storeURL: LinkHost.defaultStoreURL, macName: Host.current().localizedName ?? "Mac")
        // Information sent by other systems (Home Assistant, a script…) is said by the engine, or notified. Not through
        // the link: a paired iPhone cannot make Maé announce anything.
        #if DEBUG
        let inbound = InboundTestHook.isOn
            ? InboundHost(announcer: engine as? any Announcing, identityStore: InboundTestHook.identityStore,
                          secrets: MemoryInboundSecrets(), storeURL: InboundTestHook.storeURL)
            : InboundHost(announcer: engine as? any Announcing, identityStore: identityStore,
                          secrets: KeychainInboundSecrets(), storeURL: InboundHost.defaultStoreURL)
        #else
        let inbound = InboundHost(announcer: engine as? any Announcing, identityStore: identityStore,
                                  secrets: KeychainInboundSecrets(), storeURL: InboundHost.defaultStoreURL)
        #endif
        let model = AssistantModel(connection: link)
        let phone = PhoneAccess(link: link)
        _model = State(initialValue: model)
        _presence = State(initialValue: DesktopPresence(model: model, phone: phone))
        _phone = State(initialValue: phone)
        _inbound = State(initialValue: InboundAccess(host: inbound))
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
            .environment(phone)
            .environment(inbound)
            // The design has no dark theme yet: the window, its menus and alerts stay light.
            .preferredColorScheme(.light)
            .followsWindowVisibility()
            .background(MainWindowLink(presence: presence))
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Closing the window leaves OpenMaé in the menu bar, whose icon has Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A click on the Dock icon, or opening the app again, brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        DesktopPresence.current?.showMainWindow()
        return false
    }

    /// Quitting stops the task Claude Code is working on: asked first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard DesktopPresence.current?.hasRunningTask == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "A task is still in progress")
        alert.informativeText = String(localized: "Claude Code is working on a task. Quitting OpenMaé stops it.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AssistantHost.stopAgentsNow()
    }

    /// A task's notification shows even when OpenMaé is in front (the user may be reading something else in it); a
    /// timer's only goes to the Notification Center then, since Maé says it out loud.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions
    {
        notification.request.content.userInfo[AssistantHost.notificationFolderKey] == nil ? [.list] : [.banner, .list]
    }

    /// A click on a task's notification opens its folder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse)
        async
    {
        guard let folder = response.notification.request.content.userInfo[AssistantHost.notificationFolderKey] as? String
        else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) }
    }
}

/// Tells the presence which window is the conversation's, and how to open it again once closed.
private struct MainWindowLink: View {
    let presence: DesktopPresence
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WindowReader { presence.windowAppeared($0) }
            .onAppear {
                let openWindow = openWindow
                presence.reopenWindow = { openWindow(id: "assistant") }
            }
    }
}

/// Reports the window a view is in, once it is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(found: found) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let found: (NSWindow) -> Void

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
