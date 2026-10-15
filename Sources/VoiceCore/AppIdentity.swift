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
}
