import CoreLocation
import Foundation
import LocationTrackerCore

// S1 — the location service (spec/services.md), the seam around CLLocationManager and its
// background/relaunch machinery (startUpdatingLocation, significant-change, visits, region
// monitoring, the iOS 17 background session). The Controller depends on `LocationProviding`,
// not on CoreLocation, so it can be driven by a fake in tests (Liskov). The boundary speaks in
// the app's own pure types (RawFix, Coordinate, DesiredMode, LocationAuthorization) — no
// CoreLocation type leaks past this file.

@MainActor
protocol LocationProviderDelegate: AnyObject {
    func locationProviderDidChangeAuthorization(_ status: LocationAuthorization)
    func locationProvider(didReceive fixes: [RawFix])
    func locationProviderDidExitWakeFence(id: String)
    func locationProviderDidVisit()
    func locationProviderDidFail(transient: Bool, message: String)
}

protocol LocationProviding: AnyObject {
    var delegate: LocationProviderDelegate? { get set }
    var authorization: LocationAuthorization { get }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    /// Accuracy + distance filter + activity type, decided by the Model (AccuracyPolicy).
    func apply(_ mode: DesiredMode)
    /// Start the standard stream plus the relaunch services and the background session.
    func startUpdating()
    func stopUpdating()
    /// Drop the distance filter so the next fix arrives quickly (the heartbeat).
    func requestSingleFix()
    func placeWakeFence(center: Coordinate, radiusMeters: Double, id: String)
    func removeWakeFence(id: String)
}

/// Production implementation. This is the ONLY place that talks to CoreLocation.
final class CLLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    weak var delegate: LocationProviderDelegate?

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        // Automatic pausing would suspend the app when iOS thinks we stopped, ending the
        // heartbeat. Power saving is done by lowering accuracy instead.
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestAlwaysAuthorization() { manager.requestAlwaysAuthorization() }

    func apply(_ mode: DesiredMode) {
        manager.desiredAccuracy = Self.map(mode.accuracy)
        manager.distanceFilter = mode.distanceFilterMeters
        manager.activityType = Self.map(mode.activity)
    }

    func startUpdating() {
        // Requires UIBackgroundModes=location in Info.plist, or this crashes — an intentional
        // tripwire keeping plist and code in agreement.
        backgroundSession = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // These relaunch a terminated (incl. force-quit) app in the background on movement.
        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    func requestSingleFix() { manager.distanceFilter = kCLDistanceFilterNone }

    func placeWakeFence(center: Coordinate, radiusMeters: Double, id: String) {
        let radius = min(radiusMeters, manager.maximumRegionMonitoringDistance)
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
            radius: radius, identifier: id)
        region.notifyOnExit = true
        region.notifyOnEntry = false
        manager.startMonitoring(for: region)   // reusing an id replaces the region
    }

    func removeWakeFence(id: String) {
        for region in manager.monitoredRegions where region.identifier == id {
            manager.stopMonitoring(for: region)
        }
    }

    // MARK: CLLocationManagerDelegate → forward as pure types on the main actor

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.map(manager.authorizationStatus)
        Task { @MainActor in self.delegate?.locationProviderDidChangeAuthorization(status) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map(Self.map)
        Task { @MainActor in self.delegate?.locationProvider(didReceive: fixes) }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.delegate?.locationProviderDidExitWakeFence(id: id) }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in self.delegate?.locationProviderDidVisit() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let transient = (error as? CLError)?.code == .locationUnknown
        let message = error.localizedDescription
        Task { @MainActor in self.delegate?.locationProviderDidFail(transient: transient, message: message) }
    }

    // MARK: CoreLocation ↔ pure-type mapping

    private static func map(_ s: CLAuthorizationStatus) -> LocationAuthorization {
        switch s {
        case .authorizedAlways: return .authorizedAlways
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    private static func map(_ l: CLLocation) -> RawFix {
        RawFix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
               accuracyMeters: l.horizontalAccuracy, speed: l.speed, course: l.course,
               timestamp: l.timestamp)
    }

    private static func map(_ a: GPSAccuracy) -> CLLocationAccuracy {
        switch a {
        case .best: return kCLLocationAccuracyBest
        case .bestForNavigation: return kCLLocationAccuracyBestForNavigation
        case .nearestTenMeters: return kCLLocationAccuracyNearestTenMeters
        case .hundredMeters: return kCLLocationAccuracyHundredMeters
        }
    }

    private static func map(_ a: ActivityKind) -> CLActivityType {
        switch a {
        case .other: return .other
        case .fitness: return .fitness
        case .automotiveNavigation: return .automotiveNavigation
        }
    }
}
