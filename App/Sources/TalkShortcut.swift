import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcut to talk from another app: ⌥ Space, unless the user recorded another one in Settings › Voice and
/// sound. It is saved in the app's own defaults, not in the engine's settings: only the Mac's interface knows it.
/// Holding the space bar in the window to talk does not depend on it.
struct TalkShortcut: Codable, Equatable, Sendable {
    /// The key, as a `kVK_…` virtual key code.
    var keyCode: UInt16
    /// ⌘ ⌥ ⌃ ⇧ and nothing else, as AppKit's flags (`NSEvent.ModifierFlags.rawValue`).
    var modifiers: UInt
    /// What the key typed, without the modifiers, when it was recorded ("M", "É", "&"): what its cap says on the user's
    /// keyboard. Nil for the keys named here (Space, the arrows, F1…).
    var character: String?

    static let standard = TalkShortcut(keyCode: UInt16(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue)

    /// The modifiers a shortcut can have.
    static var modifierKeys: NSEvent.ModifierFlags { [.command, .option, .control, .shift] }

    init(keyCode: UInt16, modifiers: UInt, character: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.modifierKeys).rawValue
        self.character = Self.namesItself(keyCode) ? nil : character.flatMap(Self.printable)
    }

    /// A key pressed while recording.
    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue,
                  character: event.charactersIgnoringModifiers)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var isStandard: Bool { self == .standard }

    // MARK: - Saved

    static let defaultsKey = "talkShortcut"

    /// The one the user recorded, or ⌥ Space.
    static var saved: TalkShortcut {
        guard let data = AppDefaults.store.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(TalkShortcut.self, from: data)
        else { return .standard }
        return shortcut
    }

    /// ⌥ Space is not written: an app that never recorded one keeps ⌥ Space, as before.
    func save() {
        if isStandard {
            AppDefaults.store.removeObject(forKey: Self.defaultsKey)
        } else {
            AppDefaults.store.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
        }
    }

    // MARK: - As the screens show it

    /// "⌥ Space", "⌃⌥ M": the modifiers in macOS's order (⌃ ⌥ ⇧ ⌘), a no-break space, the key.
    var title: Text {
        Text(verbatim: Self.symbols(flags) + "\u{00A0}") + keyName
    }

    /// ⌃ ⌥ ⇧ ⌘, as macOS's menus write them.
    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        let order: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { flags.contains($0.0) }.map(\.1).joined()
    }

    /// Space, the symbol macOS's menus draw for the keys that have one, F1 to F20, or the character it typed.
    private var keyName: Text {
        if Int(keyCode) == kVK_Space { return Text("Space") }
        if let symbol = Self.keySymbols[Int(keyCode)] { return Text(verbatim: symbol) }
        if let number = Self.functionKeys.firstIndex(of: Int(keyCode)) { return Text(verbatim: "F\(number + 1)") }
        return Text(verbatim: character ?? "#\(keyCode)")
    }

    private static let keySymbols: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Home: "↖", kVK_End: "↘",
    ]

    /// F1 to F20, in order.
    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
                                       kVK_F20]

    private static func namesItself(_ keyCode: UInt16) -> Bool {
        Int(keyCode) == kVK_Space || keySymbols[Int(keyCode)] != nil || functionKeys.contains(Int(keyCode))
    }

    /// The character as a key cap shows it: upper case, nothing invisible.
    private static func printable(_ character: String) -> String? {
        let shown = character.uppercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return shown.isEmpty ? nil : shown
    }

    // MARK: - For macOS

    /// Carbon's modifiers, for `RegisterEventHotKey`.
    var carbonModifiers: Int {
        let carbon: [(NSEvent.ModifierFlags, Int)] = [(.command, cmdKey), (.option, optionKey), (.control, controlKey),
                                                       (.shift, shiftKey)]
        return carbon.filter { flags.contains($0.0) }.reduce(0) { $0 | $1.1 }
    }

    // MARK: - What cannot be the shortcut

    /// Why a shortcut cannot be the one to talk, said in one line.
    enum Refusal: Equatable {
        /// Neither ⌘, ⌥ nor ⌃: the key would no longer type in any app.
        case needsModifier
        /// ⌘ alone, or with ⇧: apps' own shortcuts (copy, save, quit…).
        case usedByApps
        /// One of macOS's shortcuts that are on in System Settings › Keyboard (Spotlight, screenshots…).
        case usedByMacOS
        /// One of OpenMaé's menus.
        case usedByOpenMae
        /// Another app holds it.
        case usedByAnotherApp
        /// macOS does not register it (⌥ alone on macOS 15.0 and 15.1).
        case refusedByMacOS

        var text: Text {
            switch self {
            case .needsModifier: Text("Add ⌘, ⌥ or ⌃: without them, this key would no longer type in your apps.")
            case .usedByApps: Text("Apps already use ⌘ with this key. Add ⌥ or ⌃.")
            case .usedByMacOS: Text("macOS already uses this shortcut.")
            case .usedByOpenMae: Text("OpenMaé already uses this shortcut in its menus.")
            case .usedByAnotherApp: Text("Another app already uses this shortcut.")
            case .refusedByMacOS: Text("macOS refuses this shortcut. Choose another one.")
            }
        }
    }

    /// What can be told before macOS is asked to register it: the modifiers, macOS's own shortcuts, OpenMaé's menus.
    /// ⌥ Space is always tried, as before shortcuts could be recorded.
    @MainActor
    var refusal: Refusal? {
        guard !isStandard else { return nil }
        if flags.isDisjoint(with: [.command, .option, .control]) { return .needsModifier }
        if Self.macOSShortcuts().contains(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) {
            return .usedByMacOS
        }
        if let menu = NSApp?.mainMenu, Self.uses(menu, self) { return .usedByOpenMae }
        if flags.subtracting(.shift) == .command { return .usedByApps }
        return nil
    }

    /// macOS's shortcuts that are on (System Settings › Keyboard › Keyboard Shortcuts).
    static func macOSShortcuts() -> [TalkShortcut] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let entries = array?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, code >= 0, code < 0xFFFF,
                  let carbon = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { return nil }
            let carbonFlags: [(Int, NSEvent.ModifierFlags)] = [(cmdKey, .command), (optionKey, .option),
                                                                (controlKey, .control), (shiftKey, .shift)]
            let flags = carbonFlags.filter { carbon & $0.0 != 0 }.reduce(into: NSEvent.ModifierFlags()) {
                $0.insert($1.1)
            }
            return TalkShortcut(keyCode: UInt16(code), modifiers: flags.rawValue)
        }
    }

    /// One of `menu`'s items, or of its submenus, has these keys as its key equivalent.
    @MainActor
    private static func uses(_ menu: NSMenu, _ shortcut: TalkShortcut) -> Bool {
        menu.items.contains { item in
            if let submenu = item.submenu, uses(submenu, shortcut) { return true }
            guard !item.keyEquivalent.isEmpty, let character = shortcut.character else { return false }
            var flags = item.keyEquivalentModifierMask.intersection(modifierKeys)
            // An upper-case key equivalent means ⇧.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { flags.insert(.shift) }
            return item.keyEquivalent.uppercased() == character && flags.rawValue == shortcut.modifiers
        }
    }
}
