import Foundation

// The pure Model rules extracted from LocationTracker/UploadQueue. Each mirrors the current
// behavior characterized in spec/tests (behavior is FROZEN, including flagged `// TODO: bug?`
// quirks — those are preserved here, not fixed).

// MARK: - F3: point validation (from LocationTracker.point(from:))

public enum PointValidator {
    /// Raw fields from a platform fix. `speed`/`course` use the CoreLocation convention where a
    /// negative value means "unknown".
    public static func makePoint(
        latitude: Double, longitude: Double, accuracyMeters: Double,
        speed: Double, course: Double, timestamp: Date, config: TrackingConfig = .default
    ) -> LocationPoint? {
        guard accuracyMeters >= 0, accuracyMeters <= config.maxAcceptedAccuracyMeters else { return nil }
        let s = (speed >= 0 && speed <= 1000) ? speed : nil
        let h = (course >= 0 && course <= 360) ? course : nil
        return LocationPoint(latitude: latitude, longitude: longitude, accuracyMeters: accuracyMeters,
                             speed: s, heading: h, recordedAtUtc: timestamp)
    }
}

// MARK: - F4: accuracy mode selection (from applyMode)

public enum AccuracyPolicy {
    public static func desiredMode(stationary: Bool, motion: MotionState, lowPower: Bool,
                                   config: TrackingConfig = .default) -> DesiredMode {
        if stationary {
            return DesiredMode(accuracy: .hundredMeters,
                               distanceFilterMeters: config.stationaryDistanceFilterMeters,
                               activity: .other)
        }
        switch motion {
        case .automotive:
            return DesiredMode(accuracy: lowPower ? .best : .bestForNavigation,
                               distanceFilterMeters: config.distanceFilterMeters,
                               activity: .automotiveNavigation)
        case .onFoot, .cycling:
            return DesiredMode(accuracy: lowPower ? .nearestTenMeters : .best,
                               distanceFilterMeters: config.distanceFilterMeters,
                               activity: .fitness)
        case .unknown, .stationary:
            return DesiredMode(accuracy: lowPower ? .nearestTenMeters : .best,
                               distanceFilterMeters: config.distanceFilterMeters,
                               activity: .other)
        }
    }
}

// MARK: - F5: periodic housekeeping decisions (from tick)

public enum HeartbeatDecision: Equatable, Sendable { case none, request, timeout }

public enum ActivityPolicy {
    /// True when the tracker should drop to power-saving mode.
    public static func shouldEnterStationary(now: Date, lastMovementAt: Date, motion: MotionState,
                                             isStationary: Bool, config: TrackingConfig = .default) -> Bool {
        guard !isStationary else { return false }
        let threshold = motion == .stationary ? config.stationaryAfterMotionStill : config.stationaryAfter
        return now.timeIntervalSince(lastMovementAt) >= threshold
    }

    public static func heartbeat(now: Date, heartbeatRequestedAt: Date?, lastPointAt: Date,
                                 config: TrackingConfig = .default) -> HeartbeatDecision {
        if let requested = heartbeatRequestedAt {
            return now.timeIntervalSince(requested) >= config.heartbeatTimeout ? .timeout : .none
        }
        return now.timeIntervalSince(lastPointAt) >= config.heartbeatInterval ? .request : .none
    }

    public static func uploadInterval(lowPower: Bool, config: TrackingConfig = .default) -> TimeInterval {
        lowPower ? config.lowPowerUploadInterval : config.uploadInterval
    }

    public static func shouldFlush(now: Date, lastFlushAttempt: Date, lowPower: Bool,
                                   config: TrackingConfig = .default) -> Bool {
        now.timeIntervalSince(lastFlushAttempt) >= uploadInterval(lowPower: lowPower, config: config)
    }
}

// MARK: - F6: wake-fence placement (from placeWakeFenceIfNeeded)

public enum GeofencePolicy {
    /// Re-place the fence only after moving 2/3 of its radius (or if none placed yet).
    public static func shouldReplace(currentCenter: Coordinate?, at: Coordinate,
                                     config: TrackingConfig = .default) -> Bool {
        guard let center = currentCenter else { return true }
        return Geo.distanceMeters(center, at) >= config.wakeFenceRadiusMeters * 0.66
    }
}

// MARK: - F7: upload queue policy (from UploadQueue.enqueue / flush)

/// Outcome of one upload attempt, abstracted from URLSession/APIError.
public enum UploadOutcome: Equatable, Sendable {
    case success
    case rateLimited(retryAfter: TimeInterval?)
    case clientError            // 4xx: server will never accept this batch
    case retryable              // offline / 5xx / other
}

/// What the queue should do next after an attempt.
public enum FlushDecision: Equatable, Sendable {
    case dropAndContinue        // remove the batch, keep flushing
    case backoffAndStop(seconds: TimeInterval)
    case stopKeeping            // keep the batch, stop for now
}

public enum UploadPolicy {
    /// The next batch to send: the oldest `maxBatchSize` points.
    public static func nextBatch(_ pending: [LocationPoint], config: TrackingConfig = .default) -> [LocationPoint] {
        Array(pending.prefix(config.maxBatchSize))
    }

    /// Enforce the queue cap by dropping the oldest points (FIFO).
    public static func enforceCap(_ pending: [LocationPoint], config: TrackingConfig = .default) -> [LocationPoint] {
        guard pending.count > config.maxQueuedPoints else { return pending }
        return Array(pending.suffix(config.maxQueuedPoints))
    }

    /// Map an attempt outcome to the queue's next action. Mirrors current behavior exactly —
    /// note a 4xx drops the batch (spec F7.6 `// TODO: bug?`, preserved, not fixed).
    public static func decide(_ outcome: UploadOutcome) -> FlushDecision {
        switch outcome {
        case .success:                       return .dropAndContinue
        case .rateLimited(let retryAfter):   return .backoffAndStop(seconds: retryAfter ?? 30)
        case .clientError:                   return .dropAndContinue   // TODO: bug? preserved
        case .retryable:                     return .stopKeeping
        }
    }

    /// Merge an on-disk backlog with in-memory points after a reboot unlock (F10.11):
    /// sorted by time, de-duplicated by value, preserving order.
    public static func merge(disk: [LocationPoint], memory: [LocationPoint]) -> [LocationPoint] {
        let sorted = (disk + memory).sorted { $0.recordedAtUtc < $1.recordedAtUtc }
        var unique: [LocationPoint] = []
        for p in sorted where unique.last != p { unique.append(p) }
        return unique
    }
}
