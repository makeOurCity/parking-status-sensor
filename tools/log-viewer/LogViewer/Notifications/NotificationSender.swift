import UserNotifications

enum NotificationSender {
    /// Requests alert/sound authorization. Call once (e.g. right after sign-in) —
    /// iOS remembers the user's answer and won't re-prompt.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// Posts a local notification immediately. Safe to call from a background
    /// task's execution context.
    static func send(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Without this, iOS silently drops a local notification's banner/sound if it
/// fires while the app happens to be in the foreground (e.g. during manual
/// testing of a background refresh). Delivery to Notification Center still
/// works either way; this only affects the in-app banner.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
