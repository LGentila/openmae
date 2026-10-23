import Foundation

/// Where the app saves what the user chose (the settings, the shortcut to talk): the app's own defaults, except while
/// a debug build draws its still pictures (`-snapshots`). Their scenes change the settings all the time, and a debug
/// build has the same bundle identifier as the normal app: they go to a domain of their own then
/// (`Snapshots.defaults`), so that the user's own are never written, however the render ends.
enum AppDefaults {
    /// UserDefaults is thread-safe, though not marked Sendable.
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if let defaults = Snapshots.defaults { return defaults }
        #endif
        return .standard
    }()
}
