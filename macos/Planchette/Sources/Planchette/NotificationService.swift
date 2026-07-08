import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for attention alerts.
/// (Replaces the deprecated NSUserNotification API.) Authorization is
/// requested once; posting is a no-op until it's granted. In a bare
/// SwiftPM dev build without a bundle this silently does nothing, which is
/// fine — notifications matter in the packaged .app.
enum NotificationService {
    /// UNUserNotificationCenter requires a real app bundle; touching it from a
    /// bare SwiftPM executable (dev runs) throws. Gate every call on this so
    /// the dev build doesn't crash — notifications only matter in the .app.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
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
