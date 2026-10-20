import Foundation
import VoiceCore

/// Keeps the Mac from going to sleep on its own, on battery too, while something the user asked for goes on in the
/// background: a timer (asleep, the Mac would only ring it once woken up, late) or a task handed to an agent (it
/// would pause). The display still goes off as usual; with the lid closed and no external display the Mac sleeps
/// anyway. Unlike OpenMaeLink's `KeepAwake` (iPhone access, the wake-word mode, on mains power only), it holds on
/// battery: it lasts only as long as the work.
final class StayAwake: @unchecked Sendable {
    private let lock = NSLock()
    /// Why, as `pmset -g assertions` shows it.
    private let reason: String
    /// How long it still holds once the work is over, for what follows to take over: a timer that rang is announced,
    /// and the announcement keeps the Mac awake in turn ("in a conversation"), a moment later.
    private let linger: Duration
    private var activity: NSObjectProtocol?
    /// Each `set` gets a number, so that a late release does not undo a newer `set(true)`.
    private var generation = 0

    init(reason: String, linger: Duration = .zero) {
        self.reason = reason
        self.linger = linger
    }

    /// Called in order, from the work's owner: on while it goes on, off (after `linger`) once it is over.
    func set(_ on: Bool) {
        lock.withLock {
            generation += 1
            if on {
                guard activity == nil else { return }
                activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: reason)
                DebugLog.log("keeping the Mac awake: \(reason)")
            } else if activity != nil {
                guard linger > .zero else { return end() }
                let generation = generation
                Task { [weak self, linger] in
                    try? await Task.sleep(for: linger)
                    self?.end(ifStill: generation)
                }
            }
        }
    }

    private func end(ifStill generation: Int) {
        lock.withLock {
            if generation == self.generation { end() }
        }
    }

    /// With the lock held.
    private func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        DebugLog.log("the Mac may sleep again: \(reason)")
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
