import CoreLocation
import CoreMotion
import Foundation

/// What the motion coprocessor says the user is doing. It runs on a dedicated low-power chip,
/// so asking costs next to nothing, and it knows within seconds, long before GPS positions
/// could prove it.
enum MotionState: Equatable {
    case unknown, stationary, onFoot, cycling, automotive

    var isMoving: Bool { self == .onFoot || self == .cycling || self == .automotive }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .stationary: return "Still"
        case .onFoot: return "On foot"
        case .cycling: return "Cycling"
        case .automotive: return "Driving"
        }
    }
}

/// Wraps CLLocationManager: turns fixes into queued points and drives uploads.
///
/// Staying alive without the user opening the app, as far as iOS allows:
///   * the "location" background mode plus a CLBackgroundActivitySession keep standard
///     updates running while the app is in the background or the phone is locked;
///   * significant-change and visit monitoring make iOS relaunch the app in the background
///     after it was terminated (memory pressure, a reboot once the phone is unlocked). On
///     relaunch the manager's authorization callback fires and tracking resumes, even though
///     no UI is ever shown;
///   * a 150 m geofence around the last known position (region monitoring) relaunches the app as soon
///     as the user leaves it — also after the app was swiped away or the phone restarted,
///     because iOS keeps monitoring the fence while the app is not running;
///   * TrackingWatchdog notifies the user if the app stops running anyway.
///
/// Battery: GPS-level accuracy is used only while moving. After `stationaryAfter` without
/// movement the manager drops to ~100 m accuracy with a 50 m distance filter (Wi-Fi and cell
/// positioning, GPS mostly off), and a single heartbeat fix is taken every
/// `heartbeatInterval`. The first report of real movement switches back to full accuracy.
///
/// Accuracy: the motion coprocessor decides moving vs still. Positions alone cannot: coarse
/// Wi-Fi fixes wobble by tens of metres, which both hides real movement and fakes it. While
/// driving the manager asks for navigation-grade GPS and the automotive activity type, which
/// lets iOS snap fixes to roads; on foot or cycling it uses the fitness type.
///
/// Tracking is on by default for a signed-in user; it stays off only if they switch it off.
@MainActor
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isTracking = false
    @Published private(set) var isStationary = false
    @Published private(set) var motionState: MotionState = .unknown
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastError: String?

    private let manager: CLLocationManager
    private let motion = CMMotionActivityManager()
    private let queue: UploadQueue
    private var tickTimer: Timer?
    private var backgroundSession: CLBackgroundActivitySession?
    private var powerObserver: NSObjectProtocol?
    private var wakeFenceCenter: CLLocation?
    nonisolated fileprivate static let wakeFenceId = "wake-fence"

    private var lastFlushAttempt = Date.distantPast
    private var lastMovementAt = Date()
    private var lastPointAt = Date()
    private var heartbeatRequestedAt: Date?

    /// Tracking intent. nil until it can be read: after a restart, before the first unlock.
    private var state: TrackerState? = TrackerState.load()

    /// Survives relaunches so tracking resumes after the system restarts the app. While the
    /// saved state is still locked away after a restart, "Always" location permission stands
    /// in for it: nobody grants that to an app they do not want tracking them. Once the phone
    /// is unlocked, reloadAfterUnlock() replaces the guess with the saved value.
    private var wantsTracking: Bool {
        get { state?.wantsTracking ?? (authorization == .authorizedAlways) }
        set { updateState { $0.wantsTracking = newValue } }
    }

    /// Only an explicit switch-off by the user keeps tracking from starting automatically.
    private var pausedByUser: Bool {
        get { state?.pausedByUser ?? false }
        set { updateState { $0.pausedByUser = newValue } }
    }

    /// Changes made before the first unlock cannot be saved and are dropped: the saved state
    /// read at unlock is the authority, and the user cannot have touched anything before it.
    private func updateState(_ change: (inout TrackerState) -> Void) {
        guard var current = state else { return }
        change(&current)
        state = current
        current.save()
    }

    /// Called when the phone is unlocked. After a restart this is the first moment the real
    /// tracking state can be read, and tracking started on a guess is corrected here.
    func reloadAfterUnlock() {
        guard state == nil, let loaded = TrackerState.load() else { return }
        state = loaded
        if !loaded.wantsTracking && isTracking {
            stop(flushRemaining: false)
        } else {
            resumeIfNeeded()
        }
    }

    private var isLowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var isLowPowerMode: Bool { isLowPower }

    init(queue: UploadQueue) {
        let manager = CLLocationManager()
        self.manager = manager
        self.queue = queue
        self.authorization = manager.authorizationStatus
        super.init()

        manager.delegate = self
        manager.activityType = .other
        // Automatic pausing would stop updates when iOS decides you are stationary, which
        // suspends the app and ends the heartbeat. Power saving is done by lowering accuracy
        // instead, which keeps the app running at a fraction of the GPS cost.
        manager.pausesLocationUpdatesAutomatically = false
        applyMode(stationary: false)

        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyMode(stationary: self.isStationary)
                self.objectWillChange.send()
            }
        }
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
        TrackingWatchdog.requestPermission()
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
        Notifier.trackingOff("You turned location sharing off. Turn it back on in the app at any time.")
    }

    /// `flushRemaining` is false on sign-out: the queue is about to be discarded and the
    /// session token is going away.
    func stop(flushRemaining: Bool = true) {
        wantsTracking = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        motion.stopActivityUpdates()
        motionState = .unknown
        removeWakeFence()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        tickTimer?.invalidate()
        tickTimer = nil
        isTracking = false
        TrackingWatchdog.disarm()
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

        lastMovementAt = Date()
        lastPointAt = Date()
        heartbeatRequestedAt = nil
        applyMode(stationary: false)

        // Requires UIBackgroundModes=location in Info.plist, or this line crashes.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // Both of these relaunch a terminated app in the background when they fire. They
        // piggyback on cell and Wi-Fi changes and cost almost nothing.
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
        startMotionUpdates()
        isTracking = true

        TrackingWatchdog.arm()
        Notifier.trackingOn()

        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    // MARK: - Power modes

    private func applyMode(stationary: Bool) {
        isStationary = stationary
        if stationary {
            manager.activityType = .other
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = AppConfig.stationaryDistanceFilterMeters
            return
        }

        switch motionState {
        case .automotive:
            // Navigation-grade accuracy keeps GPS locked instead of settling for Wi-Fi
            // positioning, and the automotive type lets iOS match fixes to roads.
            manager.activityType = .automotiveNavigation
            manager.desiredAccuracy = isLowPower ? kCLLocationAccuracyBest : kCLLocationAccuracyBestForNavigation
        case .onFoot, .cycling:
            manager.activityType = .fitness
            manager.desiredAccuracy = isLowPower ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        case .unknown, .stationary:
            manager.activityType = .other
            manager.desiredAccuracy = isLowPower ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyBest
        }
        manager.distanceFilter = AppConfig.distanceFilterMeters
    }

    // MARK: - Wake fence

    // Classic CLLocationManager region monitoring, not CLMonitor: the CLMonitor version crashed
    // the app at launch on a real device. Region monitoring is what iOS apps have relied on for
    // relaunch-on-exit for years. It persists across app termination and phone restarts, and
    // its events arrive through the manager delegate the tracker already has, so a relaunch
    // needs nothing more than creating the manager at launch.

    /// Leaving the fence: the user is on the move, and the app may have been relaunched just
    /// for this. Resume tracking; handle() re-centres the fence on the next fix.
    fileprivate func wakeFenceExited() {
        lastMovementAt = Date()
        resumeIfNeeded()
        if isTracking && isStationary { applyMode(stationary: false) }
    }

    /// Keeps the fence centred on the user. Re-centred only after real displacement, so a
    /// stationary phone does not churn it.
    private func placeWakeFenceIfNeeded(at location: CLLocation) {
        guard isTracking else { return }
        if let center = wakeFenceCenter,
           location.distance(from: center) < AppConfig.wakeFenceRadiusMeters * 0.66 { return }

        wakeFenceCenter = location
        (RegionMonitoring() as WakeFenceMonitoring).place(on: manager, id: Self.wakeFenceId,
                                 center: location.coordinate, radius: AppConfig.wakeFenceRadiusMeters)
    }

    private func removeWakeFence() {
        wakeFenceCenter = nil
        (RegionMonitoring() as WakeFenceMonitoring).remove(from: manager, id: Self.wakeFenceId)
    }

    // MARK: - Motion

    private func startMotionUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated { self?.handleMotion(activity) }
        }
    }

    private func handleMotion(_ activity: CMMotionActivity) {
        // Low-confidence readings flip-flop; waiting for a firmer one costs a few seconds.
        guard activity.confidence != .low else { return }

        let state: MotionState
        if activity.automotive { state = .automotive }
        else if activity.cycling { state = .cycling }
        else if activity.running || activity.walking { state = .onFoot }
        else if activity.stationary { state = .stationary }
        else { state = .unknown }

        guard state != motionState else { return }
        motionState = state

        if state.isMoving {
            lastMovementAt = Date()
        }
        // Re-apply even when already in moving mode: the activity type and accuracy depend on
        // how the user is moving, not just whether.
        if state.isMoving || !isStationary {
            applyMode(stationary: false)
        }
    }

    private var uploadInterval: TimeInterval {
        isLowPower ? AppConfig.lowPowerUploadInterval : AppConfig.uploadInterval
    }

    /// Periodic housekeeping. Runs every `tickInterval` while tracking; the app keeps
    /// running in the background because standard location updates are never paused.
    private func tick() {
        let now = Date()

        // While the motion chip says the user is moving, stay in full-accuracy mode however
        // still the positions look (a traffic jam, a train). When it says still, trust it
        // sooner than the position-based guess.
        if motionState.isMoving {
            lastMovementAt = now
        }
        let stillFor = now.timeIntervalSince(lastMovementAt)
        let stillThreshold = motionState == .stationary ? AppConfig.stationaryAfterMotionStill : AppConfig.stationaryAfter
        if !isStationary && stillFor >= stillThreshold {
            applyMode(stationary: true)
        }

        if let requested = heartbeatRequestedAt {
            // No fix arrived for the heartbeat (no signal indoors): give up for this round
            // and restore the power-saving filter rather than leave it wide open.
            if now.timeIntervalSince(requested) >= 60 {
                heartbeatRequestedAt = nil
                applyMode(stationary: isStationary)
            }
        } else if now.timeIntervalSince(lastPointAt) >= AppConfig.heartbeatInterval {
            // Removing the distance filter makes the running updates deliver the next fix
            // within seconds; handle() restores the filter once it arrives.
            heartbeatRequestedAt = now
            manager.distanceFilter = kCLDistanceFilterNone
        }

        TrackingWatchdog.arm()

        if now.timeIntervalSince(lastFlushAttempt) >= uploadInterval {
            Task { await flush() }
        }
    }

    // MARK: - Fixes

    private func handle(_ locations: [CLLocation]) {
        for location in locations {
            let isHeartbeat = heartbeatRequestedAt != nil
            let moved = isMovement(location, heartbeat: isHeartbeat)

            if isHeartbeat {
                heartbeatRequestedAt = nil
                applyMode(stationary: isStationary)
            }

            guard let point = Self.point(from: location) else { continue }
            lastLocation = location
            lastPointAt = Date()
            queue.enqueue(point)

            if moved {
                lastMovementAt = Date()
                if isStationary { applyMode(stationary: false) }
            }

            placeWakeFenceIfNeeded(at: location)
        }

        // While stationary each fix is a rare heartbeat or the first sign of movement, and
        // both are worth sending at once. While moving, fixes are batched.
        let interval = isStationary ? 0 : uploadInterval
        if Date().timeIntervalSince(lastFlushAttempt) >= interval {
            Task { await flush() }
        }
    }

    private func isMovement(_ location: CLLocation, heartbeat: Bool) -> Bool {
        if location.speed >= AppConfig.movingSpeedMps { return true }
        guard let previous = lastLocation else { return false }

        let distance = location.distance(from: previous)
        if isStationary {
            // In power-saving mode iOS reports only after ~50 m of travel, so an unrequested
            // fix is itself the signal. A heartbeat fix must show real displacement, beyond
            // the wobble of Wi-Fi and cell positioning.
            return heartbeat ? distance >= 150 : distance >= 30
        }

        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        return elapsed > 0 && distance >= 15 && distance / elapsed >= AppConfig.movingSpeedMps
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
                if self.isTracking {
                    self.stop(flushRemaining: false)
                    Notifier.trackingOff("Location access was turned off. Open Location Tracker to turn it back on.")
                }
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
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == LocationTracker.wakeFenceId else { return }
        Task { @MainActor in self.wakeFenceExited() }
    }

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

/// Tracking intent, kept in its own small file rather than UserDefaults. After a restart both
/// are unreadable until the first unlock, but a file can be re-read reliably afterwards,
/// whereas UserDefaults may keep serving the empty values it saw while locked.
struct TrackerState: Codable, Equatable {
    var wantsTracking = false
    var pausedByUser = false

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tracker-state.json")
    }

    /// nil while locked. On first run, carries over what earlier versions kept in UserDefaults.
    static func load() -> TrackerState? {
        guard TokenStore.isUnlockedSinceBoot else { return nil }
        if let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(TrackerState.self, from: data) {
            return state
        }
        let migrated = TrackerState(
            wantsTracking: UserDefaults.standard.bool(forKey: "wantsTracking"),
            pausedByUser: UserDefaults.standard.bool(forKey: "trackingPausedByUser"))
        migrated.save()
        return migrated
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The wake fence, through CLLocationManager region monitoring. iOS 17 deprecated these calls
/// in favour of CLMonitor, but CLMonitor crashed the app at launch on a real device, and the
/// classic API still works. The calls sit in deprecated witnesses of a non-deprecated
/// protocol, so they compile without deprecation warnings, and this is the only place to
/// change if CLMonitor is tried again.
private protocol WakeFenceMonitoring {
    func place(on manager: CLLocationManager, id: String, center: CLLocationCoordinate2D, radius: CLLocationDistance)
    func remove(from manager: CLLocationManager, id: String)
}

private struct RegionMonitoring {}

extension RegionMonitoring: WakeFenceMonitoring {
    @available(iOS, deprecated: 17.0)
    func place(on manager: CLLocationManager, id: String, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
        let region = CLCircularRegion(center: center, radius: min(radius, manager.maximumRegionMonitoringDistance), identifier: id)
        region.notifyOnExit = true
        region.notifyOnEntry = false
        // Starting a region with an identifier already in use replaces it.
        manager.startMonitoring(for: region)
    }

    @available(iOS, deprecated: 17.0)
    func remove(from manager: CLLocationManager, id: String) {
        for region in manager.monitoredRegions where region.identifier == id {
            manager.stopMonitoring(for: region)
        }
    }
}
