import Foundation
import UserNotifications

/// macOS notifications (a timer that rang, a task an agent finished). Only inside the app: a command-line tool has no
/// bundle to show them under.
enum Notifier {
    /// The `userInfo` key of the folder a click on the notification opens (the app's notification delegate does).
    static let folderKey = "folder"

    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asked the first time a notification may be needed, not at launch.
    static func requestPermission() async {
        guard available else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    /// `folder`: opened by a click on the notification.
    static func post(title: String, body: String, folder: String? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let folder { content.userInfo = [folderKey: folder] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
