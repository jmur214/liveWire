import XCTest
@testable import LiveWire

final class FeedStoreTests: XCTestCase {
    private func tx(_ id: Int, incident: Int? = nil) -> Transmission {
        Transmission(id: id, incidentId: incident, agency: .fire, incidentType: nil, occurredAt: Double(id), heardAt: Double(id),
                     transcript: "t\(id)", summary: nil, address: nil, lat: nil, lon: nil, audioFile: nil, duration: 1, units: [])
    }

    private func inc(_ id: Int, last: Double) -> Incident {
        let i = Fixtures.incidents[0]
        return Incident(id: id, city: i.city, agency: i.agency, incidentType: i.incidentType, summary: i.summary, address: i.address,
                        lat: i.lat, lon: i.lon, firstHeard: last - 100, lastHeard: last, status: "active", txCount: 1, units: [:],
                        delayed: false, delaySec: 0, locationKind: nil, locationConfidence: nil, heardAs: nil, reportedWrong: nil,
                        transmissions: nil)
    }

    func testTransmissionsNewestFirstAndDeduped() {
        var s = FeedStore()
        XCTAssertTrue(s.merge(tx(1)))
        XCTAssertTrue(s.merge(tx(3)))
        XCTAssertTrue(s.merge(tx(2)))          // out-of-order arrival
        XCTAssertFalse(s.merge(tx(3)))         // duplicate
        XCTAssertEqual(s.transmissions.map(\.id), [3, 2, 1])
        XCTAssertEqual(s.latestTransmissionId, 3)
        XCTAssertEqual(s.unreadCount(since: 1), 2)
        XCTAssertEqual(s.unreadCount(since: 3), 0)
    }

    func testTransmissionCap() {
        var s = FeedStore()
        s.maxTransmissions = 5
        for i in 1...8 { s.merge(tx(i)) }
        XCTAssertEqual(s.transmissions.count, 5)
        XCTAssertEqual(s.transmissions.first?.id, 8)
        XCTAssertEqual(s.transmissions.last?.id, 4)
    }

    func testIncidentsReplaceAndResort() {
        var s = FeedStore()
        XCTAssertTrue(s.merge(inc(1, last: 100)))
        XCTAssertTrue(s.merge(inc(2, last: 200)))
        XCTAssertEqual(s.incidents.map(\.id), [2, 1])
        XCTAssertFalse(s.merge(inc(1, last: 300)))   // update moves it to the top
        XCTAssertEqual(s.incidents.map(\.id), [1, 2])
        XCTAssertEqual(s.incident(1)?.lastHeard, 300)
    }

    func testIncidentUpdateKeepsLoadedTimeline() {
        var s = FeedStore()
        var detail = inc(1, last: 100)
        detail.transmissions = [tx(1, incident: 1)]
        s.merge(detail)
        s.merge(inc(1, last: 200))              // SSE update has no timeline
        XCTAssertEqual(s.incident(1)?.transmissions?.count, 1)
    }

    @MainActor
    func testModelFilterBannerAndBadge() {
        let m = Fixtures.model()
        XCTAssertEqual(m.visibleIncidents.count, 3)
        m.toggle(.police)
        XCTAssertEqual(m.visibleIncidents.map(\.agency).filter { $0 == .police }.count, 0)
        m.toggle(.police)
        // Banner = newest by first_heard with traffic in the last 30 min → incident 1
        XCTAssertEqual(m.bannerIncident?.id, 1)
        m.dismissBanner()
        XCTAssertNil(m.bannerIncident)
        // Badge
        m.settings.lastSeenTransmissionId = 4
        XCTAssertEqual(m.unreadCount, 2)
        m.showFeed = true
        XCTAssertEqual(m.unreadCount, 0)
    }
}
