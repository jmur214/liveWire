import XCTest
@testable import LiveWire

final class DecodingTests: XCTestCase {
    func testIncidentListDecodes() throws {
        let json = """
        {"incidents": [{
          "id": 123, "agency": "fire", "incident_type": "structure fire",
          "summary": "Structure fire, smoke showing", "address": "1621 N 33rd St",
          "lat": 40.8268, "lon": -96.69, "first_heard": 1790831900.0,
          "last_heard": 1790831991.1, "status": "active", "tx_count": 3,
          "units": {"truck 8": "on_scene", "battalion 1": "on_scene", "engine 1": "en_route"},
          "delayed": false, "delay_sec": 0, "location_kind": "address",
          "location_confidence": 0.9, "heard_as": "1621 North 33rd"}]}
        """
        let r = try APIClient.decoder.decode(IncidentsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.incidents.count, 1)
        let i = r.incidents[0]
        XCTAssertEqual(i.id, 123)
        XCTAssertEqual(i.agency, .fire)
        XCTAssertEqual(i.title, "Structure fire")
        XCTAssertEqual(i.units["engine 1"], "en_route")
        XCTAssertEqual(i.txCount, 3)
        XCTAssertEqual(i.confidenceLabel, "High")
        XCTAssertEqual(i.unitChips.map { $0.unit }, ["Battalion 1", "Engine 1", "Truck 8"])
        XCTAssertNil(i.transmissions)
    }

    func testIncidentDetailWithTimeline() throws {
        let json = """
        {"id": 5, "agency": "police", "incident_type": "shooting", "summary": null, "address": "N 22nd St & Y St",
         "lat": 40.82, "lon": -96.69, "first_heard": 1.0, "last_heard": 2.0, "status": "cleared", "tx_count": 2,
         "units": {}, "delayed": true, "delay_sec": 863, "location_kind": "intersection", "location_confidence": 0.5,
         "heard_as": "22nd and Y", "reported_wrong": true,
         "transmissions": [
           {"id": 9001, "agency": "police", "occurred_at": 2.0, "heard_at": 865.0, "transcript": "Adam 20 en route",
            "audio_file": "a.wav", "duration": 2.5, "units": ["Adam 20"], "summary": null},
           {"id": 9000, "agency": "police", "occurred_at": 1.0, "heard_at": 864.0, "transcript": "Shots fired",
            "audio_file": "b.wav", "duration": 6.0, "units": [], "summary": "Shots fired"}]}
        """
        let i = try APIClient.decoder.decode(Incident.self, from: Data(json.utf8))
        XCTAssertEqual(i.transmissions?.count, 2)
        XCTAssertEqual(i.transmissions?[0].primaryUnit, "Adam 20")
        XCTAssertEqual(i.transmissions?[1].primaryUnit, "Dispatch")
        XCTAssertFalse(i.transmissions![0].isMapped)
        XCTAssertEqual(i.confidenceLabel, "Low")
        XCTAssertEqual(i.reportedWrong, true)
        XCTAssertFalse(i.isActive)
        XCTAssertEqual(Format.feedTiming(delayed: i.delayed, delaySec: i.delaySec), "Delayed ~14 min")
    }

    func testTransmissionsAndUnknownAgency() throws {
        let json = """
        {"transmissions": [{"id": 9001, "incident_id": null, "agency": "coast guard",
          "occurred_at": 1.0, "heard_at": 1.0, "transcript": "Radio check", "summary": null,
          "address": null, "lat": null, "lon": null, "audio_file": "x.wav", "duration": 1.1, "units": []}],
         "latest_id": 9001}
        """
        let r = try APIClient.decoder.decode(TransmissionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.latestId, 9001)
        XCTAssertEqual(r.transmissions[0].agency, .unknown)
        XCTAssertNil(r.transmissions[0].incidentId)
        XCTAssertFalse(r.transmissions[0].isMapped)
        XCTAssertTrue(r.transmissions[0].matches(search: "radio"))
        XCTAssertFalse(r.transmissions[0].matches(search: "engine"))
    }

    func testHealthAndCities() throws {
        let h = try APIClient.decoder.decode(Health.self, from: Data("""
        {"ok": true, "version": "1.0.0", "city": "lincoln", "ingest_alive": true, "police_delay_sec": 873, "last_transmission_at": 1790831991.1}
        """.utf8))
        XCTAssertTrue(h.ingestAlive)
        XCTAssertEqual(h.policeDelaySec, 873)

        let c = try APIClient.decoder.decode(CitiesResponse.self, from: Data("""
        {"cities": [{"id":"lincoln","name":"Lincoln, NE","center":[40.8136,-96.7026],
          "agencies":{"police":{"name":"Lincoln Police Department","delayed":true}},
          "incident_types":["structure fire","shooting"]}]}
        """.utf8))
        XCTAssertEqual(c.cities[0].centerCoordinate.latitude, 40.8136, accuracy: 1e-6)
        XCTAssertEqual(c.cities[0].agencyName(.police), "Lincoln Police Department")
        XCTAssertEqual(c.cities[0].agencyName(.fire), "Fire")
    }

    func testDeviceResponseDecodes() throws {
        let r = try APIClient.decoder.decode(DeviceResponse.self, from: Data("""
        {"ok": true, "stats": {"week_total": 4, "places": {"Home": 3}, "types": 1, "near_me": 0}}
        """.utf8))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.stats?.weekTotal, 4)
        XCTAssertEqual(r.stats?.places["Home"], 3)
        XCTAssertEqual(r.stats?.nearMe, 0)
    }

    func testDeviceRegistrationEncodesSnakeCase() throws {
        var rules = AlertRules()
        rules.enabled = true
        rules.types = ["structure fire"]
        rules.places = [AlertRules.Place(name: "Home", lat: 40.81, lon: -96.70, radiusMi: 0.5, enabled: true),
                        AlertRules.Place(name: "Work")]
        rules.nearMe = .init(enabled: false, radiusMi: 0.5)
        rules.quiet = .init(enabled: true, start: "23:00", end: "07:00", allow: ["shooting"])
        let reg = DeviceRegistration(token: "abc", city: "lincoln", sandbox: true, rules: rules.forServer)
        let data = try APIClient.encoder.encode(reg)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let r = obj["rules"] as! [String: Any]
        XCTAssertEqual(obj["sandbox"] as? Bool, true)
        XCTAssertNotNil(r["near_me"])
        XCTAssertEqual((r["places"] as! [[String: Any]]).count, 1, "places without coordinates are not sent")
        XCTAssertEqual(((r["places"] as! [[String: Any]])[0])["radius_mi"] as? Double, 0.5)
        XCTAssertEqual((r["quiet"] as! [String: Any])["start"] as? String, "23:00")
    }
}
