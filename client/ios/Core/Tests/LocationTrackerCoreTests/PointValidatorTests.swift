import XCTest
@testable import LocationTrackerCore

/// Characterization of F3 — location capture & validation.
final class PointValidatorTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_000)

    // F3.1 valid fix — happy
    func testValidFix() {
        let p = PointValidator.makePoint(latitude: 30, longitude: 31, accuracyMeters: 8,
                                         speed: 12, course: 90, timestamp: t)
        XCTAssertEqual(p, LocationPoint(latitude: 30, longitude: 31, accuracyMeters: 8,
                                        speed: 12, heading: 90, recordedAtUtc: t))
    }

    // F3.2 accuracy out of range — edge/error
    func testNegativeAccuracyRejected() {
        XCTAssertNil(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: -1,
                                              speed: 0, course: 0, timestamp: t))
    }
    func testTooCoarseRejected() {
        XCTAssertNil(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: 150.1,
                                              speed: 0, course: 0, timestamp: t))
    }
    func testAccuracyBoundaryInclusive() {
        XCTAssertNotNil(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: 150,
                                                 speed: 0, course: 0, timestamp: t))
    }

    // F3.3 unknown speed/course — edge
    func testUnknownSpeedBecomesNil() {
        XCTAssertNil(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: 5,
                                              speed: -1, course: 0, timestamp: t)?.speed)
    }
    func testOverSpeedBecomesNil() {
        XCTAssertNil(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: 5,
                                              speed: 1500, course: 0, timestamp: t)?.speed)
    }
    func testUnknownCourseBecomesNil() {
        XCTAssertNil(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: 5,
                                              speed: 0, course: -1, timestamp: t)?.heading)
    }
    func testCourseBoundaryInclusive() {
        XCTAssertEqual(PointValidator.makePoint(latitude: 0, longitude: 0, accuracyMeters: 5,
                                                speed: 0, course: 360, timestamp: t)?.heading, 360)
    }
}
