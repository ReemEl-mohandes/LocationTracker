import Foundation

/// Every tunable the Model needs, injected so tests can vary it. Defaults mirror the app's
/// `AppConfig` exactly (spec-frozen values).
public struct TrackingConfig: Equatable, Sendable {
    public var maxAcceptedAccuracyMeters: Double
    public var distanceFilterMeters: Double
    public var stationaryDistanceFilterMeters: Double
    public var stationaryAfter: TimeInterval
    public var stationaryAfterMotionStill: TimeInterval
    public var heartbeatInterval: TimeInterval
    public var heartbeatTimeout: TimeInterval
    public var uploadInterval: TimeInterval
    public var lowPowerUploadInterval: TimeInterval
    public var movingSpeedMps: Double
    public var wakeFenceRadiusMeters: Double
    public var maxBatchSize: Int
    public var maxQueuedPoints: Int

    public init(
        maxAcceptedAccuracyMeters: Double = 150,
        distanceFilterMeters: Double = 10,
        stationaryDistanceFilterMeters: Double = 50,
        stationaryAfter: TimeInterval = 180,
        stationaryAfterMotionStill: TimeInterval = 60,
        heartbeatInterval: TimeInterval = 30,   // presence heartbeat: report every 30s while running
        heartbeatTimeout: TimeInterval = 60,
        uploadInterval: TimeInterval = 30,
        lowPowerUploadInterval: TimeInterval = 60,
        movingSpeedMps: Double = 1.0,
        wakeFenceRadiusMeters: Double = 150,
        maxBatchSize: Int = 500,
        maxQueuedPoints: Int = 20_000
    ) {
        self.maxAcceptedAccuracyMeters = maxAcceptedAccuracyMeters
        self.distanceFilterMeters = distanceFilterMeters
        self.stationaryDistanceFilterMeters = stationaryDistanceFilterMeters
        self.stationaryAfter = stationaryAfter
        self.stationaryAfterMotionStill = stationaryAfterMotionStill
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.uploadInterval = uploadInterval
        self.lowPowerUploadInterval = lowPowerUploadInterval
        self.movingSpeedMps = movingSpeedMps
        self.wakeFenceRadiusMeters = wakeFenceRadiusMeters
        self.maxBatchSize = maxBatchSize
        self.maxQueuedPoints = maxQueuedPoints
    }

    public static let `default` = TrackingConfig()
}

/// Injected clock (spec S10) so time-based rules are testable without waiting.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Great-circle distance in metres. Pure; used by the geofence policy.
public enum Geo {
    public static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_008.8
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return r * 2 * asin(min(1, sqrt(h)))
    }
}
