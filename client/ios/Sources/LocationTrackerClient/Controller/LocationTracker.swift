import CoreMotion
import Foundation
import LocationTrackerCore

/// Presentation label for the motion state (view concern kept out of the pure Core enum).
extension MotionState {
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

/// The tracking **Controller** (MVC). It coordinates:
///   * the location **Service** (`LocationProviding`, injected — the seam around
///     CLLocationManager / startUpdatingLocation and the relaunch machinery),
///   * the motion **Service** (CMMotionActivityManager, still inline — next to extract),
///   * the **Model** (LocationTrackerCore policies: accuracy, heartbeat, geofence, validation),
///   * the upload **Service** (`UploadQueue`).
///
/// It holds no CoreLocation types and constructs no concrete services except the defaults in its
/// initializer — those are the composition-root defaults, overridable by tests with fakes.
///
/// Background/force-quit/reboot survival is unchanged: the injected provider starts
/// significant-change + region monitoring + the iOS 17 background session, so iOS relaunches the
/// app headlessly on movement and this controller resumes via the authorization callback.
@MainActor
final class LocationTracker: NSObject, ObservableObject, LocationProviderDelegate {
    @Published private(set) var authorization: LocationAuthorization
    @Published private(set) var isTracking = false
    @Published private(set) var isStationary = false
    @Published private(set) var motionState: MotionState = .unknown
    @Published private(set) var lastFix: RawFix?
    @Published private(set) var lastError: String?

    private let provider: LocationProviding
    private let motion = CMMotionActivityManager()
    private let queue: UploadQueue
    private let config = TrackingConfig.default

    private var tickTimer: Timer?
    private var powerObserver: NSObjectProtocol?
    private var wakeFenceCenter: Coordinate?
    private static let wakeFenceId = "wake-fence"

    private var lastFlushAttempt = Date.distantPast
    private var lastMovementAt = Date()
    private var lastPointAt = Date()
    private var heartbeatRequestedAt: Date?

    /// Tracking intent. nil until it can be read: after a restart, before the first unlock.
    private var state: TrackerState? = TrackerStateStore.load()

    /// While the saved state is locked away after a restart, "Always" permission stands in for
    /// it (nobody grants Always to an app they do not want tracking them); corrected at unlock.
    private var wantsTracking: Bool {
        get { state?.wantsTracking ?? (authorization == .authorizedAlways) }
        set { updateState { $0.wantsTracking = newValue } }
    }
    private var pausedByUser: Bool {
        get { state?.pausedByUser ?? false }
        set { updateState { $0.pausedByUser = newValue } }
    }

    private func updateState(_ change: (inout TrackerState) -> Void) {
        guard var current = state else { return }
        change(&current)
        state = current
        TrackerStateStore.save(current)
    }

    func reloadAfterUnlock() {
        guard state == nil, let loaded = TrackerStateStore.load() else { return }
        state = loaded
        if !loaded.wantsTracking && isTracking {
            stop(flushRemaining: false)
        } else {
            resumeIfNeeded()
        }
    }

    private var isLowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var isLowPowerMode: Bool { isLowPower }

    init(queue: UploadQueue, provider: LocationProviding = CLLocationProvider()) {
        self.queue = queue
        self.provider = provider
        self.authorization = provider.authorization
        super.init()

        provider.delegate = self

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
            provider.requestWhenInUseAuthorization()
        case .denied, .restricted:
            lastError = "Location access is off. Enable it in Settings."
        default:
            beginUpdates()
        }
    }

    func pauseByUser() {
        pausedByUser = true
        stop()
        Notifier.trackingOff("You turned location sharing off. Turn it back on in the app at any time.")
    }

    func stop(flushRemaining: Bool = true) {
        wantsTracking = false
        provider.stopUpdating()
        removeWakeFence()
        motion.stopActivityUpdates()
        motionState = .unknown
        tickTimer?.invalidate()
        tickTimer = nil
        isTracking = false
        TrackingWatchdog.disarm()
        if flushRemaining {
            Task { await queue.flush() }
        }
    }

    func resumeIfNeeded() {
        if wantsTracking && !isTracking && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse) {
            beginUpdates()
        }
    }

    private func beginUpdates() {
        guard !isTracking else { return }
        lastError = nil

        let now = Date()
        lastMovementAt = now
        lastPointAt = now
        heartbeatRequestedAt = nil

        applyMode(stationary: false)
        provider.startUpdating()
        startMotionUpdates()
        isTracking = true

        TrackingWatchdog.arm()
        Notifier.trackingOn()

        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        if authorization == .authorizedWhenInUse {
            provider.requestAlwaysAuthorization()
        }
    }

    // MARK: - Power modes (Model decides the mode; the Service applies it)

    private func applyMode(stationary: Bool) {
        isStationary = stationary
        provider.apply(AccuracyPolicy.desiredMode(
            stationary: stationary, motion: motionState, lowPower: isLowPower, config: config))

        // Applying a mode restores the distance filter. If a heartbeat is still waiting for its
        // fix, that would silently cancel it: a still phone never moves far enough to deliver
        // one, and the next attempt only comes after the timeout, leaving the user shown
        // offline. Re-open the filter so the pending heartbeat fix still arrives. The two places
        // that end a heartbeat (fix received, timeout) clear heartbeatRequestedAt first, so they
        // do restore the filter.
        if heartbeatRequestedAt != nil {
            provider.requestSingleFix()
        }
    }

    // MARK: - Wake fence

    private func placeWakeFenceIfNeeded(at coordinate: Coordinate) {
        guard isTracking else { return }
        if GeofencePolicy.shouldReplace(currentCenter: wakeFenceCenter, at: coordinate, config: config) {
            wakeFenceCenter = coordinate
            provider.placeWakeFence(center: coordinate, radiusMeters: config.wakeFenceRadiusMeters, id: Self.wakeFenceId)
        }
    }

    private func removeWakeFence() {
        wakeFenceCenter = nil
        provider.removeWakeFence(id: Self.wakeFenceId)
    }

    private func wakeFenceExited() {
        lastMovementAt = Date()
        resumeIfNeeded()
        if isTracking && isStationary { applyMode(stationary: false) }
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
        guard activity.confidence != .low else { return }

        let newState: MotionState
        if activity.automotive { newState = .automotive }
        else if activity.cycling { newState = .cycling }
        else if activity.running || activity.walking { newState = .onFoot }
        else if activity.stationary { newState = .stationary }
        else { newState = .unknown }

        guard newState != motionState else { return }
        motionState = newState

        if newState.isMoving { lastMovementAt = Date() }
        if newState.isMoving || !isStationary { applyMode(stationary: false) }
    }

    // MARK: - Periodic housekeeping (Model decides; Controller acts)

    private func tick() {
        let now = Date()

        if motionState.isMoving { lastMovementAt = now }

        if ActivityPolicy.shouldEnterStationary(
            now: now, lastMovementAt: lastMovementAt, motion: motionState,
            isStationary: isStationary, config: config) {
            applyMode(stationary: true)
        }

        switch ActivityPolicy.heartbeat(now: now, heartbeatRequestedAt: heartbeatRequestedAt,
                                        lastPointAt: lastPointAt, config: config) {
        case .timeout:
            heartbeatRequestedAt = nil
            applyMode(stationary: isStationary)
        case .request:
            heartbeatRequestedAt = now
            provider.requestSingleFix()
        case .none:
            break
        }

        TrackingWatchdog.arm()

        if ActivityPolicy.shouldFlush(now: now, lastFlushAttempt: lastFlushAttempt, lowPower: isLowPower, config: config) {
            Task { await flush() }
        }
    }

    // MARK: - Fixes

    private func handle(_ fixes: [RawFix]) {
        for fix in fixes {
            let isHeartbeat = heartbeatRequestedAt != nil
            let moved = isMovement(fix, heartbeat: isHeartbeat)

            if isHeartbeat {
                heartbeatRequestedAt = nil
                applyMode(stationary: isStationary)
            }

            guard let point = Self.point(from: fix, config: config) else { continue }
            lastFix = fix
            lastPointAt = Date()
            queue.enqueue(point)

            if moved {
                lastMovementAt = Date()
                if isStationary { applyMode(stationary: false) }
            }

            placeWakeFenceIfNeeded(at: fix.coordinate)
        }

        let interval = isStationary ? 0 : ActivityPolicy.uploadInterval(lowPower: isLowPower, config: config)
        if Date().timeIntervalSince(lastFlushAttempt) >= interval {
            Task { await flush() }
        }
    }

    private func isMovement(_ fix: RawFix, heartbeat: Bool) -> Bool {
        if fix.speed >= config.movingSpeedMps { return true }
        guard let previous = lastFix else { return false }

        let distance = Geo.distanceMeters(previous.coordinate, fix.coordinate)
        if isStationary {
            return heartbeat ? distance >= 150 : distance >= 30
        }

        let elapsed = fix.timestamp.timeIntervalSince(previous.timestamp)
        return elapsed > 0 && distance >= 15 && distance / elapsed >= config.movingSpeedMps
    }

    private func flush() async {
        lastFlushAttempt = Date()
        await queue.flush()
    }

    /// Validation lives in the tested Model (PointValidator); the result is mapped to the app's
    /// upload DTO.
    private static func point(from fix: RawFix, config: TrackingConfig) -> LocationPoint? {
        guard let core = PointValidator.makePoint(
            latitude: fix.latitude, longitude: fix.longitude, accuracyMeters: fix.accuracyMeters,
            speed: fix.speed, course: fix.course, timestamp: fix.timestamp, config: config) else { return nil }
        return LocationPoint(latitude: core.latitude, longitude: core.longitude,
                             accuracyMeters: core.accuracyMeters, speed: core.speed,
                             heading: core.heading, recordedAtUtc: core.recordedAtUtc)
    }

    // MARK: - LocationProviderDelegate

    func locationProviderDidChangeAuthorization(_ status: LocationAuthorization) {
        authorization = status
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            if wantsTracking { beginUpdates() }
        case .denied, .restricted:
            if isTracking {
                stop(flushRemaining: false)
                Notifier.trackingOff("Location access was turned off. Open Location Tracker to turn it back on.")
            }
            wantsTracking = false
            lastError = "Location access is off. Enable it in Settings."
        case .notDetermined:
            break
        }
    }

    func locationProvider(didReceive fixes: [RawFix]) { handle(fixes) }

    func locationProviderDidExitWakeFence(id: String) {
        guard id == Self.wakeFenceId else { return }
        wakeFenceExited()
    }

    func locationProviderDidVisit() { resumeIfNeeded() }

    func locationProviderDidFail(transient: Bool, message: String) {
        if transient { return }
        lastError = message
    }
}

/// App-side persistence for the pure `TrackerState` (Core owns the data; file + Keychain I/O
/// belong here). Mirrors the previous behavior, including the first-unlock handling.
enum TrackerStateStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tracker-state.json")
    }

    /// nil while locked. On first run, carries over the old UserDefaults keys.
    static func load() -> TrackerState? {
        guard TokenStore.isUnlockedSinceBoot else { return nil }
        if let data = try? Data(contentsOf: fileURL),
           let state = try? JSONDecoder().decode(TrackerState.self, from: data) {
            return state
        }
        let migrated = TrackerState(
            wantsTracking: UserDefaults.standard.bool(forKey: "wantsTracking"),
            pausedByUser: UserDefaults.standard.bool(forKey: "trackingPausedByUser"))
        save(migrated)
        return migrated
    }

    static func save(_ state: TrackerState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
