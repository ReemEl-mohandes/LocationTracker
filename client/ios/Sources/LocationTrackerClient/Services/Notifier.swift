import Foundation
import UserNotifications

/// Local notifications telling the user what tracking is doing. Permission is requested with
/// the watchdog's (TrackingWatchdog.requestPermission) when tracking first starts.
///
/// Each kind reuses one identifier, so a newer notification replaces the older one instead of
/// piling up: one "tracking" state, one "connectivity" state, one per trip.
enum Notifier {
    private static let trackingId = "tracking-state"
    private static let connectivityId = "connectivity"
    private static let tripPrefix = "trip-"

    private static let lastTrackingOnKey = "lastTrackingOnNotice"
    private static let notifiedTripsKey = "notifiedTripIds"

    /// "Sharing is on" at most this often. iOS may relaunch the app several times in a row
    /// (fence exit, then a significant change), and each would otherwise announce itself.
    private static let trackingOnCooldown: TimeInterval = 10 * 60

    static func trackingOn() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastTrackingOnKey) as? Date,
           Date().timeIntervalSince(last) < trackingOnCooldown { return }
        defaults.set(Date(), forKey: lastTrackingOnKey)

        post(id: trackingId, title: "Location sharing is on", body: "Your trips are being recorded.")
    }

    static func trackingOff(_ reason: String) {
        UserDefaults.standard.removeObject(forKey: lastTrackingOnKey)
        post(id: trackingId, title: "Location sharing is off", body: reason)
    }

    static func offline(pending: Int) {
        let body = pending > 0
            ? "No internet. Your location is being saved (\(pending) points so far) and will upload when you're back online."
            : "No internet. Your location is being saved and will upload when you're back online."
        post(id: connectivityId, title: "Offline", body: body)
    }

    static func backOnline(uploaded: Int) {
        let body = uploaded > 0
            ? "\(uploaded) saved point\(uploaded == 1 ? "" : "s") uploaded."
            : "Location sharing is live again."
        post(id: connectivityId, title: "Back online", body: body)
    }

    /// Posted once per trip, however many times the app sees it end.
    static func tripRecorded(_ trip: Trip) {
        let defaults = UserDefaults.standard
        // An ordered list, oldest first, so trimming to 200 drops the oldest ids. (A Set has no
        // order, so trimming it could drop the trip just announced and announce it again.)
        var notified = defaults.stringArray(forKey: notifiedTripsKey) ?? []
        let key = String(trip.id)
        guard !notified.contains(key) else { return }
        notified.append(key)
        defaults.set(Array(notified.suffix(200)), forKey: notifiedTripsKey)

        let distance = trip.distanceMeters >= 1000
            ? String(format: "%.1f km", trip.distanceMeters / 1000)
            : "\(Int(trip.distanceMeters)) m"
        var body = distance
        if let seconds = trip.durationSeconds {
            body += " in \(formatDuration(seconds))"
        }
        if trip.maxSpeedMps > 0 {
            body += String(format: " · top speed %.0f km/h", trip.maxSpeedMps * 3.6)
        }

        post(id: tripPrefix + key, title: "Trip recorded", body: body)
    }

    /// Whether a notification should also show while the app is open. Trip and connectivity
    /// news are worth a banner; "sharing is on" is obvious from the screen the user is on.
    static func showsInForeground(_ identifier: String) -> Bool {
        identifier.hasPrefix(tripPrefix) || identifier == connectivityId
    }

    private static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Lets chosen notifications appear as banners while the app is in the foreground; iOS hides
/// them by default.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Notifier.showsInForeground(notification.request.identifier) ? [.banner, .list, .sound] : []
    }
}
