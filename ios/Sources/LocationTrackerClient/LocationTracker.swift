import CoreLocation
import Foundation

/// Wraps CLLocationManager: turns fixes into queued points and drives uploads.
///
/// Staying alive without the user opening the app, as far as iOS allows:
///   * the "location" background mode plus a CLBackgroundActivitySession keep standard
///     updates running while the app is in the background or the phone is locked;
///   * significant-change and visit monitoring make iOS relaunch the app in the background
///     after it was terminated (memory pressure, a reboot once the phone is unlocked). On
///     relaunch the manager's authorization callback fires and tracking resumes, even though
///     no UI is ever shown.
/// Tracking is on by default for a signed-in user; it stays off only if they switch it off.
@MainActor
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isTracking = false
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastError: String?

    private static let wantsTrackingKey = "wantsTracking"
    private static let pausedByUserKey = "trackingPausedByUser"

    private let manager: CLLocationManager
    private let queue: UploadQueue
    private var uploadTimer: Timer?
    private var backgroundSession: CLBackgroundActivitySession?
    private var lastFlushAttempt = Date.distantPast

    /// Survives relaunches so tracking resumes after the system restarts the app.
    private var wantsTracking: Bool {
        get { UserDefaults.standard.bool(forKey: Self.wantsTrackingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.wantsTrackingKey) }
    }

    /// Only an explicit switch-off by the user keeps tracking from starting automatically.
    private var pausedByUser: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedByUserKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pausedByUserKey) }
    }

    init(queue: UploadQueue) {
        let manager = CLLocationManager()
        self.manager = manager
        self.queue = queue
        self.authorization = manager.authorizationStatus
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = AppConfig.distanceFilterMeters
        manager.activityType = .other
        // Automatic pausing stops updates when iOS decides you are stationary, which is
        // exactly when the server needs points to notice a trip has ended.
        manager.pausesLocationUpdatesAutomatically = false
    }

    var needsAlwaysPermission: Bool { authorization == .authorizedWhenInUse }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Starts tracking for a signed-in user unless they switched it off themselves.
    func autoStart() {
        guard !pausedByUser, !isTracking, !isDenied else { return }
        start()
    }

    func start() {
        pausedByUser = false
        wantsTracking = true
        switch authorization {
        case .notDetermined:
            // iOS only offers "Always" after "While Using" has been granted; beginUpdates
            // asks for the upgrade once this answer arrives.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            lastError = "Location access is off. Enable it in Settings."
        default:
            beginUpdates()
        }
    }

    /// The user switched tracking off; it stays off until they switch it back on.
    func pauseByUser() {
        pausedByUser = true
        stop()
    }

    /// `flushRemaining` is false on sign-out: the queue is about to be discarded and the
    /// session token is going away.
    func stop(flushRemaining: Bool = true) {
        wantsTracking = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        uploadTimer?.invalidate()
        uploadTimer = nil
        isTracking = false
        if flushRemaining {
            Task { await queue.flush() }
        }
    }

    /// Called on launch once a session exists.
    func resumeIfNeeded() {
        if wantsTracking && !isTracking && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse) {
            beginUpdates()
        }
    }

    private func beginUpdates() {
        guard !isTracking else { return }
        lastError = nil

        // Keeps the app eligible for location updates in the background (iOS 17). Created
        // again on every relaunch, which is how an interrupted session is resumed.
        backgroundSession = CLBackgroundActivitySession()

        // Requires UIBackgroundModes=location in Info.plist, or this line crashes.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // Both of these relaunch a terminated app in the background when they fire.
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
        isTracking = true

        uploadTimer?.invalidate()
        uploadTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.uploadInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }

        if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    private func handle(_ locations: [CLLocation]) {
        for location in locations {
            guard let point = Self.point(from: location) else { continue }
            lastLocation = location
            queue.enqueue(point)
        }
        // A background relaunch may only last seconds, and timers do not fire while the app
        // is suspended between location events, so fixes also trigger the upload directly.
        if Date().timeIntervalSince(lastFlushAttempt) >= AppConfig.uploadInterval {
            Task { await flush() }
        }
    }

    private func flush() async {
        lastFlushAttempt = Date()
        await queue.flush()
    }

    private static func point(from location: CLLocation) -> LocationPoint? {
        // Negative accuracy means the fix is invalid.
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= AppConfig.maxAcceptedAccuracyMeters else { return nil }

        // Negative speed/course mean "unknown"; the server validates both ranges.
        let speed = location.speed >= 0 && location.speed <= 1000 ? location.speed : nil
        let heading = location.course >= 0 && location.course <= 360 ? location.course : nil

        return LocationPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy,
            speed: speed,
            heading: heading,
            recordedAtUtc: location.timestamp)
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                // Also the path a background relaunch takes: iOS calls this as soon as the
                // manager is created, before any UI exists.
                if self.wantsTracking { self.beginUpdates() }
            case .denied, .restricted:
                if self.isTracking { self.stop(flushRemaining: false) }
                self.wantsTracking = false
                self.lastError = "Location access is off. Enable it in Settings."
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    /// Visits exist here to wake the app; the standard updates they restart carry the data.
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in self.resumeIfNeeded() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient: iOS keeps trying on its own.
        if (error as? CLError)?.code == .locationUnknown { return }
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }
}
