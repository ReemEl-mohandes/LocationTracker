import XCTest
@testable import LocationTrackerCore

/// F4 — accuracy modes.
final class AccuracyPolicyTests: XCTestCase {
    func testAutomotiveFull() {
        let m = AccuracyPolicy.desiredMode(stationary: false, motion: .automotive, lowPower: false)
        XCTAssertEqual(m, DesiredMode(accuracy: .bestForNavigation, distanceFilterMeters: 10, activity: .automotiveNavigation))
    }
    func testOnFootFull() {
        let m = AccuracyPolicy.desiredMode(stationary: false, motion: .onFoot, lowPower: false)
        XCTAssertEqual(m, DesiredMode(accuracy: .best, distanceFilterMeters: 10, activity: .fitness))
    }
    func testUnknownFull() {
        let m = AccuracyPolicy.desiredMode(stationary: false, motion: .unknown, lowPower: false)
        XCTAssertEqual(m, DesiredMode(accuracy: .best, distanceFilterMeters: 10, activity: .other))
    }
    func testLowPowerDropsNotch() {
        XCTAssertEqual(AccuracyPolicy.desiredMode(stationary: false, motion: .automotive, lowPower: true).accuracy, .best)
        XCTAssertEqual(AccuracyPolicy.desiredMode(stationary: false, motion: .onFoot, lowPower: true).accuracy, .nearestTenMeters)
    }
    func testStationaryOverridesMotion() {
        let m = AccuracyPolicy.desiredMode(stationary: true, motion: .automotive, lowPower: false)
        XCTAssertEqual(m, DesiredMode(accuracy: .hundredMeters, distanceFilterMeters: 50, activity: .other))
    }
}

/// F5 — power saving & heartbeat.
final class ActivityPolicyTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 10_000)

    func testEntersStationaryAfter180sWhenMotionUnknown() {
        XCTAssertTrue(ActivityPolicy.shouldEnterStationary(
            now: base.addingTimeInterval(180), lastMovementAt: base, motion: .unknown, isStationary: false))
        XCTAssertFalse(ActivityPolicy.shouldEnterStationary(
            now: base.addingTimeInterval(179), lastMovementAt: base, motion: .unknown, isStationary: false))
    }
    func testMotionStillEntersSooner() {
        XCTAssertTrue(ActivityPolicy.shouldEnterStationary(
            now: base.addingTimeInterval(60), lastMovementAt: base, motion: .stationary, isStationary: false))
    }
    func testAlreadyStationaryNoOp() {
        XCTAssertFalse(ActivityPolicy.shouldEnterStationary(
            now: base.addingTimeInterval(9999), lastMovementAt: base, motion: .unknown, isStationary: true))
    }
    func testHeartbeatRequestedAfterInterval() {
        // Presence heartbeat is 30 s (report every 30 s while running).
        XCTAssertEqual(ActivityPolicy.heartbeat(now: base.addingTimeInterval(30), heartbeatRequestedAt: nil, lastPointAt: base), .request)
        XCTAssertEqual(ActivityPolicy.heartbeat(now: base.addingTimeInterval(29), heartbeatRequestedAt: nil, lastPointAt: base), .none)
    }
    func testHeartbeatTimeout() {
        XCTAssertEqual(ActivityPolicy.heartbeat(now: base.addingTimeInterval(60), heartbeatRequestedAt: base, lastPointAt: base), .timeout)
        XCTAssertEqual(ActivityPolicy.heartbeat(now: base.addingTimeInterval(59), heartbeatRequestedAt: base, lastPointAt: base), .none)
    }
    func testUploadIntervalByPower() {
        XCTAssertEqual(ActivityPolicy.uploadInterval(lowPower: false), 30)
        XCTAssertEqual(ActivityPolicy.uploadInterval(lowPower: true), 60)
    }
    func testShouldFlush() {
        XCTAssertTrue(ActivityPolicy.shouldFlush(now: base.addingTimeInterval(30), lastFlushAttempt: base, lowPower: false))
        XCTAssertFalse(ActivityPolicy.shouldFlush(now: base.addingTimeInterval(30), lastFlushAttempt: base, lowPower: true))
    }
}

/// F6 — wake geofence placement.
final class GeofencePolicyTests: XCTestCase {
    let origin = Coordinate(latitude: 30, longitude: 31)
    func testFirstPlacement() {
        XCTAssertTrue(GeofencePolicy.shouldReplace(currentCenter: nil, at: origin))
    }
    func testSmallMoveKeepsFence() {
        // ~50 m north, under 99 m threshold
        let near = Coordinate(latitude: 30 + 50 / 111_320.0, longitude: 31)
        XCTAssertFalse(GeofencePolicy.shouldReplace(currentCenter: origin, at: near))
    }
    func testLargeMoveReplaces() {
        // ~120 m north, over 99 m threshold
        let far = Coordinate(latitude: 30 + 120 / 111_320.0, longitude: 31)
        XCTAssertTrue(GeofencePolicy.shouldReplace(currentCenter: origin, at: far))
    }
}

/// F7 — upload queue policy.
final class UploadPolicyTests: XCTestCase {
    func pt(_ i: Int) -> LocationPoint {
        LocationPoint(latitude: 0, longitude: 0, accuracyMeters: 5, speed: nil, heading: nil,
                      recordedAtUtc: Date(timeIntervalSince1970: TimeInterval(i)))
    }
    func testNextBatchTakesOldest500() {
        let pending = (0..<700).map(pt)
        let batch = UploadPolicy.nextBatch(pending)
        XCTAssertEqual(batch.count, 500)
        XCTAssertEqual(batch.first, pt(0))
        XCTAssertEqual(batch.last, pt(499))
    }
    func testEnforceCapDropsOldest() {
        let pending = (0..<20_005).map(pt)
        let capped = UploadPolicy.enforceCap(pending)
        XCTAssertEqual(capped.count, 20_000)
        XCTAssertEqual(capped.first, pt(5))   // oldest 5 dropped
    }
    func testDecideSuccess() { XCTAssertEqual(UploadPolicy.decide(.success), .dropAndContinue) }
    func testDecideRateLimited() {
        XCTAssertEqual(UploadPolicy.decide(.rateLimited(retryAfter: 45)), .backoffAndStop(seconds: 45))
        XCTAssertEqual(UploadPolicy.decide(.rateLimited(retryAfter: nil)), .backoffAndStop(seconds: 30))
    }
    func testDecideClientErrorDropsBatch() {   // F7.6 — preserved behavior, not fixed
        XCTAssertEqual(UploadPolicy.decide(.clientError), .dropAndContinue)
    }
    func testDecideRetryableKeeps() { XCTAssertEqual(UploadPolicy.decide(.retryable), .stopKeeping) }

    func testMergeSortsAndDedups() {
        let disk = [pt(1), pt(3)]
        let memory = [pt(2), pt(3)]   // pt(3) duplicated
        XCTAssertEqual(UploadPolicy.merge(disk: disk, memory: memory), [pt(1), pt(2), pt(3)])
    }
}
