import Foundation
import UserNotifications

/// macOS notifications (a timer that rang). Only inside the app: a command-line tool has no bundle to
/// show them under.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asked the first time a notification may be needed, not at launch.
    static func requestPermission() async {
        guard available else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
