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
        AppDelegate.engine = engine as? AssistantHost
        #else
        let engine = AssistantHost()
        AppDelegate.engine = engine
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
            .frame(minWidth: ContentView.minimumWidth, minHeight: 700)
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
    /// The engine, wound down before the app ends (`applicationShouldTerminate`); nil for the demonstration.
    @MainActor static var engine: AssistantHost?
    /// How long quitting waits for the engine at most: quitting never hangs. The conversations' beginning, the longest
    /// to stop, takes 1.7 to 1.8 s with Gemma 4 26B, more when the Mac is short of memory (`AssistantHost.windDown`).
    private static let windDownLimit = Duration.seconds(2)
    /// The engine winds down for the app to end (`applicationShouldTerminate`).
    private var quitting = false
    /// The app may end (`endQuitting`).
    private var quitAnswered = false

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

    /// Quitting stops the task Claude Code is working on: asked first. Then the app ends once the engine has wound down
    /// (`AssistantHost.windDown`): AppKit's `exit` destroys the C++ objects MLX keeps for the whole process, and a
    /// computation of the language model still under way crashed under them (the app quit as a keep-warm pass started: 2
    /// crash reports in 11 quits; as the conversations' beginning started at launch: 4 in 5). After `windDownLimit` it
    /// ends all the same, without destroying them (`endNow`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }  // quit again meanwhile: the first quit's answer ends the app
        if DesktopPresence.current?.hasRunningTask == true {
            let alert = NSAlert()
            alert.messageText = String(localized: "A task is still in progress")
            alert.informativeText = String(localized: "Claude Code is working on a task. Quitting OpenMaé stops it.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        guard let engine = Self.engine else { return .terminateNow }
        quitting = true
        DebugLog.log("quit: the engine winds down")
        Task {
            await engine.windDown()
            endQuitting()
        }
        Task {
            try? await Task.sleep(for: Self.windDownLimit)
            guard !quitAnswered else { return }
            DebugLog.log("quit: the engine did not wind down in \(Self.windDownLimit), quitting anyway")
            Self.endNow()
        }
        return .terminateLater
    }

    /// Lets the app end (`applicationShouldTerminate`), once: the engine has wound down, and AppKit ends the app the usual
    /// way (`applicationWillTerminate`, then `exit`).
    private func endQuitting() {
        guard !quitAnswered else { return }
        quitAnswered = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Ends the process at once: the engine did not wind down in `windDownLimit`, and the GPU may still compute (a chunk
    /// of the conversations' beginning already queued, which has to finish before the beginning stops; a model's load and
    /// warm-up, which cannot be interrupted). Letting AppKit end the app would run `exit`, and with it the C++ destructors
    /// of the objects MLX keeps for the whole process, under that computation: the crash the wind-down is there to avoid
    /// (a command encoder released while still open, a mutex destroyed under Metal's completion queue, segmentation faults
    /// in MLX's encoding). `_exit` ends the process without running them, and without AppKit's last steps either: what
    /// `applicationWillTerminate` does is done here first, so that the agents' runs do not outlive the app.
    private static func endNow() -> Never {
        AssistantHost.stopAgentsNow()
        DebugLog.log("quit: the agents' runs stopped, the app ends at once (_exit: MLX's objects are left as they are)")
        _exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AssistantHost.stopAgentsNow()
        DebugLog.log("quit: the agents' runs stopped, the app ends")
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
