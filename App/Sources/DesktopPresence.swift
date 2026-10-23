import AppKit
import Carbon.HIToolbox
import Observation
import OpenMaeLink
import SwiftUI
import VoiceCore

/// OpenMaé outside its window: the icon in the menu bar, the shortcut to talk (⌥ Space, or the user's own), and the
/// capsule that follows the conversation when the window is not in front. Closing the window leaves all of them running.
/// In the wake-word mode it also keeps the Mac awake, so that Maé hears « OK Maé ».
@MainActor
final class DesktopPresence {
    /// The app's presence, for the app delegate (a click on the Dock icon brings the window back) and for Settings ›
    /// Voice and sound, which records another shortcut.
    private(set) static weak var current: DesktopPresence?

    private let model: AssistantModel
    private let phone: PhoneAccess
    private var icon: MenuBarIcon?
    private var capsule: CapsuleController?
    /// `model.talkShortcut`: talk, then finish. Set aside while the settings record another one.
    private var talkShortcut: GlobalShortcut?
    /// Escape, only while the capsule offers to cancel or interrupt Maé; the rest of the time it belongs to the app
    /// in front.
    private var escapeShortcut: GlobalShortcut?
    /// The conversation window. Kept once closed: SwiftUI may show the same one again.
    private weak var mainWindow: NSWindow?
    /// On mains power, the Mac does not go to sleep while Maé waits for « OK Maé ».
    private let keepAwake = KeepAwake(reason: "OpenMaé: listening for “OK Maé”")
    private var keepsAwake = false
    /// Opens the conversation window again once it was closed (SwiftUI's `openWindow`).
    var reopenWindow: (() -> Void)?

    /// Quitting would stop a task Claude Code is working on (the app delegate asks first).
    var hasRunningTask: Bool { model.hasRunningTask }

    init(model: AssistantModel, phone: PhoneAccess) {
        self.model = model
        self.phone = phone
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
        let shortcut = GlobalShortcut(model.talkShortcut) { [weak self] in self?.talkPressed() }
        talkShortcut = shortcut
        registered(shortcut, model.talkShortcut)
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

    /// The shortcut to talk: talk, or finish talking. Before Maé is ready, it brings the window, which says why.
    private func talkPressed() {
        guard model.isReady else {
            showMainWindow()
            return
        }
        model.toggleTalk()
    }

    // MARK: - The shortcut to talk

    /// Registers `shortcut`'s keys, and tells the model whether macOS took them. ⌥ Space is registered as before
    /// shortcuts could be recorded; one the user recorded only if no other app holds it, and then for OpenMaé alone.
    @discardableResult
    private func registered(_ hotKey: GlobalShortcut, _ shortcut: TalkShortcut) -> Bool {
        let status = hotKey.register(exclusive: !shortcut.isStandard)
        model.hasTalkShortcut = status == noErr
        model.talkShortcutRefusal = status == noErr ? nil
            : status == OSStatus(eventHotKeyExistsErr) ? .usedByAnotherApp : .refusedByMacOS
        return status == noErr
    }

    /// Settings › Voice and sound starts recording a new shortcut: the current one no longer talks meanwhile, so that
    /// pressing it is recorded too.
    func beginRecordingTalkShortcut() {
        talkShortcut?.unregister()
        model.talkShortcutRefusal = nil
        model.isRecordingTalkShortcut = true
    }

    /// The recording is over (Escape, a click, the page left): the current shortcut talks again. What was refused
    /// meanwhile is no longer said; why the current one does not work, if it does not, is.
    func endRecordingTalkShortcut() {
        guard model.isRecordingTalkShortcut else { return }
        model.isRecordingTalkShortcut = false
        if let talkShortcut { registered(talkShortcut, model.talkShortcut) }
    }

    /// Another shortcut recorded, or ⌥ Space again: it replaces the current one at once, is saved, and ends the
    /// recording. When it cannot (see `TalkShortcut.Refusal`), the current one stays, the model says why, and the
    /// recording goes on. Returns whether it was taken.
    @discardableResult
    func setTalkShortcut(_ shortcut: TalkShortcut) -> Bool {
        if shortcut == model.talkShortcut {
            // The current one pressed while recording: nothing changes. Otherwise it is tried again.
            if model.isRecordingTalkShortcut {
                endRecordingTalkShortcut()
            } else if let talkShortcut, !talkShortcut.isRegistered {
                registered(talkShortcut, shortcut)
            }
            return model.hasTalkShortcut
        }
        if let refusal = shortcut.refusal {
            DebugLog.log("talk shortcut refused: \(refusal)")
            model.talkShortcutRefusal = refusal
            return false
        }
        let candidate = GlobalShortcut(shortcut) { [weak self] in self?.talkPressed() }
        let status = candidate.register(exclusive: !shortcut.isStandard)
        guard status == noErr else {
            model.talkShortcutRefusal = status == OSStatus(eventHotKeyExistsErr) ? .usedByAnotherApp : .refusedByMacOS
            return false
        }
        talkShortcut?.unregister()
        talkShortcut = candidate
        shortcut.save()
        DebugLog.log("talk shortcut: key \(shortcut.keyCode), modifiers \(shortcut.carbonModifiers)")
        model.talkShortcut = shortcut
        model.hasTalkShortcut = true
        model.talkShortcutRefusal = nil
        model.isRecordingTalkShortcut = false
        return true
    }

    /// Runs `update` again whenever what it reads in the model changes.
    private func follow() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func update() {
        let wakeWord = model.isReady && model.listensForWakeWord
        if wakeWord != keepsAwake {
            keepsAwake = wakeWord
            keepAwake.set(wakeWord)
        }
        let state = model.talkKeyDown ? .userSpeaking : model.shownState
        let active = model.isReady && state != .listening
        icon?.show(active ? state : nil)
        guard let capsule else { return }
        // The capsule shows what the window would: from the shortcut to the end of the answer, or once Maé has
        // understood something said hands-free (not for every noise she hears); in the wake-word mode, from « OK Maé »
        // to the end of the seconds of attention after the answer. Not while an iPhone has the conversation: the
        // Mac's microphone and speakers are off, the words are not for whoever is at the Mac, and Escape stays with the
        // app in front.
        let understood = model.currentExchange.user.map { !$0.pending && !$0.text.isEmpty } ?? false
        let shows = active && !windowIsInFront && phone.hand == nil
            && (model.isShortcutExchange || model.listensForWakeWord || state == .speaking
                || (state == .thinking && understood))
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
    ///   "OpenMaeDebugShortcut"  "option-space" (the shortcut to talk, whichever it is) or "escape", as if pressed (escape
    ///                           only works when it would)
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
