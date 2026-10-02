import CoreLocation
import XCTest
@testable import LiveWire

final class FormatTests: XCTestCase {
    func testDistance() {
        XCTAssertEqual(Format.distance(meters: nil), "—")
        XCTAssertEqual(Format.distance(meters: 965.6), "0.6 mi")
        XCTAssertEqual(Format.distance(meters: 1609.344 * 9.94), "9.9 mi")
        XCTAssertEqual(Format.distance(meters: 1609.344 * 12.4), "12 mi")
    }

    func testCLLocationDistanceMatchesHaversine() {
        let a = CLLocation(latitude: 40.8268, longitude: -96.69)
        let b = CLLocation(latitude: 40.8208, longitude: -96.6868)
        let d = a.distance(from: b)
        XCTAssert(d > 600 && d < 800, "\(d)")
    }

    func testAgo() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(Format.ago(9_970, now: now), "30s ago")
        XCTAssertEqual(Format.ago(9_880, now: now), "2m ago")
        XCTAssertEqual(Format.ago(10_000 - 5400, now: now), "1.5h ago")
    }

    func testFeedTimingAndUnits() {
        XCTAssertEqual(Format.feedTiming(delayed: false, delaySec: 0), "Live")
        XCTAssertEqual(Format.feedTiming(delayed: true, delaySec: 840), "Delayed ~14 min")
        XCTAssertEqual(Format.unitName("engine 1"), "Engine 1")
        XCTAssertEqual(Format.unitStatus("en_route"), "en route")
        XCTAssertEqual(Format.unitStatus("bogus"), "dispatched")
    }
}
