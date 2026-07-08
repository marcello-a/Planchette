import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for attention alerts.
/// (Replaces the deprecated NSUserNotification API.) Authorization is
/// requested once; posting is a no-op until it's granted. In a bare
/// SwiftPM dev build without a bundle this silently does nothing, which is
/// fine — notifications matter in the packaged .app.
enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
