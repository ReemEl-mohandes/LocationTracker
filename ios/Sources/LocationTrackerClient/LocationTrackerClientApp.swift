import SwiftUI

@main
struct LocationTrackerClientApp: App {
    @StateObject private var session: SessionStore
    @StateObject private var queue: UploadQueue
    @StateObject private var tracker: LocationTracker

    init() {
        let session = SessionStore()
        let queue = UploadQueue()
        let tracker = LocationTracker(queue: queue)

        // Ending the session, for whatever reason, stops tracking and discards the backlog.
        session.onSignedOut = { [weak tracker, weak queue] in
            tracker?.stop(flushRemaining: false)
            queue?.clear()
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
