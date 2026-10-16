import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import VoiceCore

/// OpenMaé outside its window: the icon in the menu bar, the ⌥ Space shortcut, and the capsule that follows the
/// conversation when the window is not in front. Closing the window leaves all of them running.
@MainActor
final class DesktopPresence {
    /// The app's presence, for the app delegate (a click on the Dock icon brings the window back).
    private(set) static weak var current: DesktopPresence?

    private let model: AssistantModel
    private var icon: MenuBarIcon?
    private var capsule: CapsuleController?
    /// ⌥ Space: talk, then finish.
    private var talkShortcut: GlobalShortcut?
    /// Escape, only while the capsule offers to cancel or interrupt Maé; the rest of the time it belongs to the app
    /// in front.
    private var escapeShortcut: GlobalShortcut?
    /// The conversation window. Kept once closed: SwiftUI may show the same one again.
    private weak var mainWindow: NSWindow?
    /// Opens the conversation window again once it was closed (SwiftUI's `openWindow`).
    var reopenWindow: (() -> Void)?

    /// Quitting would stop a task Claude Code is working on (the app delegate asks first).
    var hasRunningTask: Bool { model.hasRunningTask }

    init(model: AssistantModel) {
        self.model = model
        Self.current = self
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
    }

    private func install() {
        #if DEBUG
        guard Snapshots.folder == nil else { return }
        #endif
        icon = MenuBarIcon { [weak self] in self?.showMainWindow() }
        capsule = CapsuleController(model: model)
        talkShortcut = GlobalShortcut(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.talkPressed() }
        model.hasTalkShortcut = talkShortcut?.register() == true
        escapeShortcut = GlobalShortcut(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.model.stopSpeaking() }

        // Whether the window is in front: the app becomes active or not, is hidden, the window goes to the Dock.
        let changes = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                       NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                       NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        for name in changes {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let closing = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
        // Shown again after it was closed (SwiftUI reuses the window): it becomes the key window.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        }
        follow()
        #if DEBUG
        listenToDebugCommands()
        #endif
    }

    // MARK: - The window

    /// The conversation is in a window: at launch, or opened again in a new window.
    func windowAppeared(_ window: NSWindow) {
        mainWindow = window
        model.isWindowOpen = true
        update()
    }

    private func windowBecameKey(_ window: ObjectIdentifier?) {
        guard let mainWindow, window == ObjectIdentifier(mainWindow), !model.isWindowOpen else { return }
        model.isWindowOpen = true
        update()
    }

    private func windowWillClose(_ window: ObjectIdentifier?) {
        guard let mainWindow, window == ObjectIdentifier(mainWindow) else { return }
        model.isWindowOpen = false
        update()
    }

    /// Brings the conversation window to the front, opening it again if it was closed.
    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
        if model.isWindowOpen, let mainWindow {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow?()
        }
    }

    /// The user is looking at the conversation window: OpenMaé is the active app and its window is open.
    private var windowIsInFront: Bool {
        guard NSApp.isActive, model.isWindowOpen, let mainWindow else { return false }
        return mainWindow.isVisible && !mainWindow.isMiniaturized
    }

    // MARK: - Following the conversation

    /// ⌥ Space: talk, or finish talking. Before Maé is ready, it brings the window, which says why.
    private func talkPressed() {
        guard model.isReady else {
            showMainWindow()
            return
        }
        model.toggleTalk()
    }

    /// Runs `update` again whenever what it reads in the model changes.
    private func follow() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func update() {
        let state = model.talkKeyDown ? .userSpeaking : model.state
        let active = model.isReady && state != .listening
        icon?.show(active ? state : nil)
        guard let capsule else { return }
        // The capsule shows what the window would: from the shortcut to the end of the answer, or once Maé has
        // understood something said hands-free (not for every noise she hears).
        let understood = model.currentExchange.user.map { !$0.pending && !$0.text.isEmpty } ?? false
        let shows = active && !windowIsInFront
            && (model.isShortcutExchange || state == .speaking || (state == .thinking && understood))
        if shows { capsule.show(state) } else { capsule.hide() }
        if shows, state == .thinking || state == .speaking {
            escapeShortcut?.register()
        } else {
            escapeShortcut?.unregister()
        }
        DebugLog.log("presence: \(state), capsule \(shows ? "shown" : "hidden"), escape \(escapeShortcut?.isRegistered == true)")
    }

    // MARK: - Test scripts

    #if DEBUG
    /// Lets a test script press the shortcuts, move the window and take pictures of the capsule and of the menu bar
    /// icon (see DebugTools.swift):
    ///
    ///   "OpenMaeDebugShortcut"  "option-space" or "escape", as if pressed (escape only works when it would)
    ///   "OpenMaeDebugWindow"    "close", "show" or "hide" (⌘H)
    ///   "OpenMaeDebugCapsule"   a file path: picture of the capsule's panel as the screen shows it (PNG)
    ///   "OpenMaeDebugMenuBar"   a file path: picture of the menu bar icon (PNG), on a dark and a light bar, and
    ///                           next to it (…-screen.png) as the screen shows it
    private func listenToDebugCommands() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("OpenMaeDebugShortcut"), object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                switch key {
                case "option-space": self.talkPressed()
                case "escape" where self.escapeShortcut?.isRegistered == true: self.model.stopSpeaking()
                default: break
                }
            }
        }
        center.addObserver(forName: .init("OpenMaeDebugWindow"), object: nil, queue: .main) { [weak self] note in
            let action = note.object as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                switch action {
                case "close": self.mainWindow?.performClose(nil)
                case "show": self.showMainWindow()
                case "hide": NSApp.hide(nil)
                default: break
                }
            }
        }
        center.addObserver(forName: .init("OpenMaeDebugCapsule"), object: nil, queue: .main) { [weak self] note in
            let path = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let path, let panel = self.capsule?.panel else { return }
                Snapshots.writeOnScreen(panel, to: URL(fileURLWithPath: path))
            }
        }
        center.addObserver(forName: .init("OpenMaeDebugMenuBar"), object: nil, queue: .main) { [weak self] note in
            let path = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let path, let button = self.icon?.item.button else { return }
                Snapshots.writeMenuBarButton(button, to: URL(fileURLWithPath: path))
                if let window = button.window {
                    DebugLog.log("menu bar icon: window \(window.frame), visible \(window.isVisible), occlusion "
                        + "\(window.occlusionState.contains(.visible) ? "visible" : "hidden"), screen "
                        + "\(window.screen?.frame ?? .zero), label \(button.accessibilityLabel() ?? "none")")
                    let screen = URL(fileURLWithPath: path).deletingPathExtension().path + "-screen.png"
                    Snapshots.writeOnScreen(window, alone: true, to: URL(fileURLWithPath: screen))
                }
            }
        }
    }
    #endif
}
