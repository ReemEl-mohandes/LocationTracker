import CoreLocation
import Foundation

/// Wraps CLLocationManager: turns fixes into queued points and drives the upload timer.
///
/// Tracking survives backgrounding through the "location" background mode, and survives the
/// app being terminated through significant-change monitoring, which relaunches the app in
/// the background; `resumeIfNeeded` then picks standard updates back up.
@MainActor
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isTracking = false
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastError: String?

    private static let wantsTrackingKey = "wantsTracking"

    private let manager: CLLocationManager
    private let queue: UploadQueue
    private var uploadTimer: Timer?

    /// Survives relaunches so tracking resumes after the system restarts the app.
    private var wantsTracking: Bool {
        get { UserDefaults.standard.bool(forKey: Self.wantsTrackingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.wantsTrackingKey) }
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

    func start() {
        wantsTracking = true
        switch authorization {
        case .notDetermined:
            // iOS only offers "Always" after "While Using" has been granted; the delegate
            // escalates once this answer arrives.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            lastError = "Location access is off. Enable it in Settings."
        default:
            beginUpdates()
        }
    }

    /// `flushRemaining` is false on sign-out: the queue is about to be discarded and the
    /// session token is going away.
    func stop(flushRemaining: Bool = true) {
        wantsTracking = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
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

        // Requires UIBackgroundModes=location in Info.plist, or this line crashes.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
        isTracking = true

        uploadTimer?.invalidate()
        uploadTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.uploadInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.queue.flush() }
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient: iOS keeps trying on its own.
        if (error as? CLError)?.code == .locationUnknown { return }
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }
}
