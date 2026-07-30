import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for attention alerts.
/// (Replaces the deprecated NSUserNotification API.) Authorization is
/// requested once; posting is a no-op until it's granted. In a bare
/// SwiftPM dev build without a bundle this silently does nothing, which is
/// fine — notifications matter in the packaged .app.
enum NotificationService {
    /// userInfo key carrying the terminal a notification belongs to, so a click
    /// can jump straight to it.
    static let sessionKey = "planchetteSession"

    /// UNUserNotificationCenter requires a real app bundle; touching it from a
    /// bare SwiftPM executable (dev runs) throws. Gate every call on this so
    /// the dev build doesn't crash — notifications only matter in the .app.
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Route notification clicks to `handler`. Must be called before the app
    /// finishes launching, otherwise a click that launched the app is lost.
    static func handleClicks(_ handler: @escaping (UUID) -> Void) {
        guard isAvailable else { return }
        delegate.onSessionClick = handler
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Retained for the lifetime of the app — UNUserNotificationCenter holds
    /// its delegate weakly.
    private static let delegate = NotificationDelegate()

    static func post(title: String, body: String, sessionID: UUID? = nil) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sessionID {
            content.userInfo = [sessionKey: sessionID.uuidString]
            // Group a terminal's alerts together in Notification Center.
            content.threadIdentifier = sessionID.uuidString
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Delivers banner clicks back to the app. Also shows banners while Planchette
/// itself is frontmost — the point of an alert here is that *another* terminal
/// needs you, which matters most while you're working in this app.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onSessionClick: ((UUID) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        // Only a click on the banner itself jumps; dismissing must not steal focus.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo[NotificationService.sessionKey] as? String,
              let id = UUID(uuidString: raw)
        else { return }
        DispatchQueue.main.async { [weak self] in self?.onSessionClick?(id) }
    }
}
