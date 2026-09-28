import Foundation

// MARK: - Entities (value types, frozen per spec/services.md)

/// One GPS fix, the unit uploaded to the server.
public struct LocationPoint: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyMeters: Double?
    public let speed: Double?
    public let heading: Double?
    public let recordedAtUtc: Date

    public init(latitude: Double, longitude: Double, accuracyMeters: Double?,
                speed: Double?, heading: Double?, recordedAtUtc: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.speed = speed
        self.heading = heading
        self.recordedAtUtc = recordedAtUtc
    }
}

/// A geographic coordinate, independent of CoreLocation.
public struct Coordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// What the motion coprocessor reports (maps from CMMotionActivity in the app layer).
public enum MotionState: Equatable, Sendable {
    case unknown, stationary, onFoot, cycling, automotive
    public var isMoving: Bool { self == .onFoot || self == .cycling || self == .automotive }
}

/// Accuracy tiers, independent of the CLLocationAccuracy constants.
public enum GPSAccuracy: Equatable, Sendable {
    case best, bestForNavigation, nearestTenMeters, hundredMeters
}

/// Activity hints, independent of CLActivityType.
public enum ActivityKind: Equatable, Sendable {
    case other, fitness, automotiveNavigation
}

/// A resolved location-manager configuration. The app translates this to CoreLocation.
public struct DesiredMode: Equatable, Sendable {
    public let accuracy: GPSAccuracy
    public let distanceFilterMeters: Double
    public let activity: ActivityKind
    public init(accuracy: GPSAccuracy, distanceFilterMeters: Double, activity: ActivityKind) {
        self.accuracy = accuracy
        self.distanceFilterMeters = distanceFilterMeters
        self.activity = activity
    }
}

/// A raw fix as delivered by the location service, before validation. `speed`/`course` follow
/// the CoreLocation convention where a negative value means "unknown". Pure, so the Controller
/// and its tests need no CoreLocation.
public struct RawFix: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyMeters: Double
    public let speed: Double
    public let course: Double
    public let timestamp: Date

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(latitude: Double, longitude: Double, accuracyMeters: Double,
                speed: Double, course: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }
}

/// Authorization state, independent of CLAuthorizationStatus.
public enum LocationAuthorization: Equatable, Sendable {
    case notDetermined, restricted, denied, authorizedAlways, authorizedWhenInUse
}

/// Tracking intent, persisted by the app; pure here.
public struct TrackerState: Codable, Equatable, Sendable {
    public var wantsTracking: Bool
    public var pausedByUser: Bool
    public init(wantsTracking: Bool = false, pausedByUser: Bool = false) {
        self.wantsTracking = wantsTracking
        self.pausedByUser = pausedByUser
    }
}
