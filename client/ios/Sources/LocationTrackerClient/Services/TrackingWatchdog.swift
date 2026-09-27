import Foundation
import UserNotifications

/// A dead man's switch for tracking. While the app runs, it keeps one local notification
/// scheduled `watchdogDelay` in the future and pushes it back on every re-arm. If the app
/// stops running (swiped away in the app switcher, or killed by iOS and not relaunched),
/// nothing pushes it back, and it fires: "Location sharing stopped, tap to resume". Tapping
/// it opens the app, which resumes tracking.
///
/// This works without relying on a termination callback: iOS does not deliver one when a
/// suspended app is swiped away.
enum TrackingWatchdog {
    private static let identifier = "tracking-stopped"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func arm() {
        let content = UNMutableNotificationContent()
        content.title = "Location sharing stopped"
        content.body = "Tap to resume sending your location."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: AppConfig.watchdogDelay, repeats: false)
        // Reusing the identifier replaces the pending request, which is what pushes it back.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        let center = UNUserNotificationCenter.current()
        center.add(request)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func disarm() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
