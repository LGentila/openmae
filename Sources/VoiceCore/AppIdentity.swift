import Foundation

/// The ONE place where the engine knows the app's name. The app bundle shows it through
/// App/Resources/InfoPlist.xcstrings; its file name, without the accent, is set in App/project.yml.
///
/// Every folder name and user-facing string of the engine derives from these constants.
public enum AppIdentity {
    public static let name = "OpenMaé"

    /// Folder used under ~/Library/Application Support and ~/Library/Caches.
    public static let directoryName = name

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

    /// ~/OpenMae — where an agent gets a new folder for each task, unless the user named one of theirs. Plain
    /// letters, like the app's file name: agents run developer tools, and some of them still trip over accents.
    public static var agentWorkspace: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OpenMae", isDirectory: true)
    }
}
