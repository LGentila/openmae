#if os(macOS)
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import VoiceCore

/// Keeps the Mac from going to sleep on its own while iPhone access is on and the Mac is plugged in: an iPhone
/// cannot wake a sleeping Mac. On battery the Mac sleeps as usual. With the lid closed and no external display it
/// sleeps anyway: a hardware limit.
final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted = false
    private var assertion: IOPMAssertionID?
    private var watcher: Task<Void, Never>?

    /// On while `wanted` and on mains power; the power source is looked at again every 30 s.
    func set(_ wanted: Bool) {
        lock.withLock {
            self.wanted = wanted
            watcher?.cancel()
            watcher = nil
            if wanted {
                watcher = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.update()
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            }
        }
        update()
    }

    var isOn: Bool { lock.withLock { assertion != nil } }

    private func update() {
        let onMains = Self.isOnMainsPower
        lock.withLock {
            let hold = wanted && onMains
            if hold, assertion == nil {
                var id = IOPMAssertionID(0)
                let status = IOPMAssertionCreateWithName(
                    kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "OpenMaé: reachable from your iPhone" as CFString, &id)
                if status == kIOReturnSuccess {
                    assertion = id
                    DebugLog.log("link: keeping the Mac awake (on mains power)")
                }
            } else if !hold, let id = assertion {
                IOPMAssertionRelease(id)
                assertion = nil
                DebugLog.log("link: the Mac may sleep again")
            }
        }
    }

    static var isOnMainsPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return true }  // a desktop Mac has no battery
        return type == kIOPMACPowerKey
    }

    deinit {
        watcher?.cancel()
        if let assertion { IOPMAssertionRelease(assertion) }
    }
}
#endif
