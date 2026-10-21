import Foundation

/// The ONE place where the engine knows the app's name. The app bundle shows it through
/// App/Resources/InfoPlist.xcstrings; its file name, without the accent, is set in App/project.yml.
///
/// Every folder name and user-facing string of the engine derives from these constants.
public enum AppIdentity {
    public static let name = "OpenMaé"

    /// Folder used under ~/Library/Application Support and ~/Library/Caches.
    public static let directoryName = name

    /// The app's version ("0.3.0"), from its bundle; "dev" outside the app (voice-cli, the tests).
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// How the app names itself to the servers it asks something: honestly, never as a browser. Plain letters, as
    /// HTTP headers want them.
    public static var userAgent: String {
        "\(name.folding(options: .diacriticInsensitive, locale: nil))/\(version)"
    }

    /// ~/Library/Application Support/<name>/Models — where downloaded models live.
    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// ~/Library/Application Support/<name>/Tasks — the tasks handed to agents.
    public static var tasksDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("Tasks", isDirectory: true)
    }

    /// ~/Library/Application Support/<name>/Memory — what Maé remembers (`memory.md`) and the journal of past exchanges
    /// (`journal.sqlite`). Next to the models, never inside their folder: deleting the models never touches it. Never in
    /// iCloud: Application Support is not synced.
    public static var memoryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
    }

    /// ~/OpenMae — where an agent gets a new folder for each task, unless the user named one of theirs. Plain
    /// letters, like the app's file name: agents run developer tools, and some of them still trip over accents.
    /// `URL.homeDirectory`, the same folder on the Mac: `FileManager.homeDirectoryForCurrentUser` does not exist on
    /// iOS, and VoiceCore is built for the iPhone app too (agents only run on the Mac).
    public static var agentWorkspace: URL {
        URL.homeDirectory.appendingPathComponent("OpenMae", isDirectory: true)
    }
}
