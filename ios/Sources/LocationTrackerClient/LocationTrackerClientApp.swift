import SwiftUI
import UserNotifications

@main
struct LocationTrackerClientApp: App {
    @StateObject private var session: SessionStore
    @StateObject private var queue: UploadQueue
    @StateObject private var tracker: LocationTracker

    init() {
        let session = SessionStore()
        let queue = UploadQueue()
        let tracker = LocationTracker(queue: queue)

        // A sign-out the user chose discards the backlog. A session the server ended (for
        // example a refresh token that expired while the phone was offline for a week) keeps
        // it: the points are still that user's, and go up once they sign in again.
        session.onSignedOut = { [weak tracker, weak queue] explicit in
            let wasTracking = tracker?.isTracking ?? false
            tracker?.stop(flushRemaining: false)
            if explicit {
                queue?.clear()
            } else if wasTracking {
                Notifier.trackingOff("You were signed out. Open Location Tracker and sign in to resume. Saved points will upload then.")
            }
        }
        session.onSignedIn = { [weak queue] profile in
            queue?.claim(for: profile.id)
        }

        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared

        // After a restart iOS can relaunch the app for a location event before the phone has
        // been unlocked, while its saved state is unreadable. This fires on unlock; both
        // reloads do nothing once their state is loaded.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak tracker, weak queue] _ in
            MainActor.assumeIsolated {
                tracker?.reloadAfterUnlock()
                Task { await queue?.reloadAfterUnlock() }
            }
        }

        _session = StateObject(wrappedValue: session)
        _queue = StateObject(wrappedValue: queue)
        _tracker = StateObject(wrappedValue: tracker)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(queue)
                .environmentObject(tracker)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var tracker: LocationTracker

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                ProgressView("Connecting…")
            case .signedOut:
                LoginView()
            case .signedIn(let profile):
                TrackingView(profile: profile)
            }
        }
        .task { await session.restore() }
        .onChange(of: session.state) { _, state in
            if case .signedIn = state { tracker.resumeIfNeeded() }
        }
    }
}
