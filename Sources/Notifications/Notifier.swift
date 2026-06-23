import Foundation
import UserNotifications

// MARK: - Notifier
//
// Wrapper around UNUserNotificationCenter. We request authorization
// once at app start; if the user denies, the AlertReporter will keep
// running but no banners will appear (the menu bar badge still works).

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { [weak self] granted, error in
            if let error = error {
                NSLog("Notifier: authorization error: \(error.localizedDescription)")
            }
            self?.authorized = granted
        }
    }

    /// Send a notification immediately. The "title" is shown bold; the
    /// "body" is the user-friendly summary. userInfo is forwarded so
    /// the click handler can deep-link into the main window.
    func send(title: String, body: String, userInfo: [String: Any] = [:]) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        content.userInfo = userInfo

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(req) { error in
            if let error = error {
                NSLog("Notifier: add failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate
    //
    // Show banners even when the app is foreground (we're a menu bar
    // app, so "foreground" means the user is actively using the Mac).

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Post a notification the AppDelegate can pick up to focus
        // the main window.
        NotificationCenter.default.post(
            name: .openMainWindowRequested, object: nil)
        completionHandler()
    }
}

extension Notification.Name {
    static let openMainWindowRequested = Notification.Name("DustWatch.openMainWindow")
}
