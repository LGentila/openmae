import OpenMaeLink
import SwiftUI
import UserNotifications
import VoiceCore
import VoiceEngineApple

/// The app: one window, the engine running in the same process, and, outside the window, an icon in the menu bar,
/// the shortcut to talk (⌥ Space by default) and the capsule (DesktopPresence.swift).
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
    @State private var relays: RelayAccess
    @State private var navigation = SettingsNavigation()
    @State private var tools = ConnectedToolsAccess()

    init() {
        Fonts.register()
        #if DEBUG
        let engine: any AssistantConnection = Demo.isOn ? DemoConnection()
            : AssistantHost(actionsTestCollection: ActionsTestCollection.name,
                            agentsTestFolder: ActionsTestCollection.agentsFolder)
        #else
        let engine = AssistantHost()
        #endif
        #if DEBUG
        // The still pictures (`-snapshots`) never touch the user's own keys, iPhones, sources or relays.
        let scratch = Snapshots.folder.map { _ in FileManager.default.temporaryDirectory.appending(path: "openmae-snapshots") }
        let identityStore: any IdentityStore = if let scratch {
            FileIdentityStore(url: scratch.appending(path: "keys"))
        } else {
            KeychainIdentityStore(service: "OpenMaé link")
        }
        let linkStore = scratch?.appending(path: "link.json") ?? LinkHost.defaultStoreURL
        #else
        let identityStore = KeychainIdentityStore(service: "OpenMaé link")
        let linkStore = LinkHost.defaultStoreURL
        #endif
        // The demonstration engine has no sound to hand over: an iPhone then only sees and commands it.
        let link = LinkHost(engine: engine, audio: engine as? any RemoteAudioRouting, identityStore: identityStore,
                            storeURL: linkStore, macName: Host.current().localizedName ?? "Mac")
        // Information sent by other systems (Home Assistant, a script…) is said by the engine, or notified. Not through
        // the link: a paired iPhone cannot make Maé announce anything.
        // Its certificate for the internet path comes from Let's Encrypt; `defaults write … ACMEDirectory staging` uses
        // its staging server instead, for trying a relay out.
        #if DEBUG
        let acme = ACMEServer.fromDefaults(allowTestRoot: true)
        let inbound = if InboundTestHook.isOn {
            InboundHost(announcer: engine as? any Announcing, identityStore: InboundTestHook.identityStore,
                        secrets: MemoryInboundSecrets(), storeURL: InboundTestHook.storeURL,
                        keys: MemoryInboundKeys(), acme: InboundTestHook.acme ?? acme)
        } else if let scratch {
            InboundHost(announcer: nil, identityStore: identityStore, secrets: MemoryInboundSecrets(),
                        storeURL: scratch.appending(path: "received-information.json"), keys: MemoryInboundKeys(),
                        acme: acme)
        } else {
            InboundHost(announcer: engine as? any Announcing, identityStore: identityStore,
                        secrets: KeychainInboundSecrets(), storeURL: InboundHost.defaultStoreURL,
                        keys: KeychainInboundKeys(), acme: acme)
        }
        #else
        let inbound = InboundHost(announcer: engine as? any Announcing, identityStore: identityStore,
                                  secrets: KeychainInboundSecrets(), storeURL: InboundHost.defaultStoreURL,
                                  keys: KeychainInboundKeys(), acme: ACMEServer.fromDefaults(allowTestRoot: false))
        #endif
        let model = AssistantModel(connection: link)
        let phone = PhoneAccess(link: link)
        let inboundAccess = InboundAccess(host: inbound)
        // The relays are set once for the whole app: the internet path of received information goes through the
        // internet relay the iPhones use, and follows when it changes (the inbound test gives it a relay of its own).
        #if DEBUG
        let relays = RelayAccess(phone: phone, inbound: inboundAccess,
                                 passesInternetRelay: InboundTestHook.publicRelay == nil)
        #else
        let relays = RelayAccess(phone: phone, inbound: inboundAccess)
        #endif
        _model = State(initialValue: model)
        _presence = State(initialValue: DesktopPresence(model: model, phone: phone))
        _phone = State(initialValue: phone)
        _inbound = State(initialValue: inboundAccess)
        _relays = State(initialValue: relays)
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
            .environment(navigation)
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
                SettingsCommand(navigation: navigation)
            }
            CommandGroup(before: .sidebar) {
                Button(window.showMeasurements ? "Hide Measurements" : "Show Measurements") {
                    window.showMeasurements.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
                Divider()
            }
        }

        // The settings: a window with a sidebar (⌘ , or "All settings…" of the quick panel).
        Window("Settings", id: SettingsNavigation.windowID) {
            SettingsWindowView(model: model, navigation: navigation, tools: tools)
                .frame(minWidth: SettingsWindowView.minimumWidth, minHeight: 560)
                .environment(phone)
                .environment(inbound)
                .environment(relays)
                .environment(navigation)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 960, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

/// "Settings…" (⌘ ,): opens the settings window, or brings it to the front.
private struct SettingsCommand: View {
    let navigation: SettingsNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsNavigation.windowID) }
            .keyboardShortcut(",")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        Snapshots.start()
        #endif
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
