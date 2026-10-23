import Carbon.HIToolbox
import VoiceCore

/// A keyboard shortcut that works whatever app is in front, through the Carbon hot key API. It needs no permission
/// (watching every key press would need Accessibility or Input Monitoring access), the key press does not reach the
/// app in front, and it keeps working with no App Sandbox. macOS 15.0 and 15.1 refused shortcuts whose only
/// modifier is Option; 15.2 and later accept them again.
@MainActor
final class GlobalShortcut {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: () -> Void
    private let id: UInt32
    private var hotKey: EventHotKeyRef?
    /// Pressed and not released yet: holding the keys down does not repeat the action.
    private var isDown = false

    private nonisolated static let signature: OSType = 0x4F4D_6165  // "OMae"
    private static var registered: [UInt32: GlobalShortcut] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    /// `keyCode`: a `kVK_…` constant; `modifiers`: Carbon's `optionKey`, `cmdKey`… (0 for none).
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.action = action
        id = Self.nextID
        Self.nextID += 1
    }

    /// The shortcut to talk (`TalkShortcut`).
    convenience init(_ shortcut: TalkShortcut, action: @escaping () -> Void) {
        self.init(keyCode: Int(shortcut.keyCode), modifiers: shortcut.carbonModifiers, action: action)
    }

    var isRegistered: Bool { hotKey != nil }

    /// Returns false when macOS refuses the shortcut.
    @discardableResult
    func register() -> Bool {
        register(exclusive: false) == noErr
    }

    /// `exclusive`: refused (`eventHotKeyExistsErr`) when another app already registered the same keys, and only this
    /// app gets them once registered. Returns macOS's answer, `noErr` once registered.
    func register(exclusive: Bool) -> OSStatus {
        guard hotKey == nil else { return noErr }
        Self.installHandler()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), exclusive ? OptionBits(kEventHotKeyExclusive) : 0,
                                         &reference)
        guard status == noErr, let reference else {
            DebugLog.log("shortcut refused by macOS: key \(keyCode), modifiers \(modifiers), status \(status)")
            return status == noErr ? OSStatus(eventHotKeyInvalidErr) : status
        }
        hotKey = reference
        Self.registered[id] = self
        return noErr
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        isDown = false
        Self.registered[id] = nil
    }

    private func handle(pressed: Bool) {
        if pressed {
            guard !isDown else { return }
            isDown = true
            action()
        } else {
            isDown = false
        }
    }

    /// One handler for every shortcut of the app: hot key events come on the main thread.
    private static func installHandler() {
        guard handler == nil else { return }
        let kinds = [kEventHotKeyPressed, kEventHotKeyReleased]
        var types = kinds.map { EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0)) }
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalShortcut.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { GlobalShortcut.registered[hotKey.id]?.handle(pressed: pressed) }
            return noErr
        }, types.count, &types, nil, &handler)
    }
}
