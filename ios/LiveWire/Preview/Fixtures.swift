import Foundation

/// Sample data for SwiftUI previews and unit tests. Mirrors tests/fixtures/lincoln_day.json.
enum Fixtures {
    static let now = Date().timeIntervalSince1970

    static let incidents: [Incident] = [
        Incident(
            id: 1, city: "lincoln", agency: .fire, incidentType: "structure fire",
            summary: "Structure fire, smoke showing from the second floor", address: "1621 N 33rd St",
            lat: 40.8268, lon: -96.69, firstHeard: now - 600, lastHeard: now - 60, status: "active", txCount: 9,
            units: ["truck 8": "on_scene", "engine 1": "clear", "battalion 1": "clear", "engine 2": "en_route"],
            delayed: false, delaySec: 0, locationKind: "address", locationConfidence: 0.92,
            heardAs: "1621 North 33rd Street", reportedWrong: false, transmissions: nil
        ),
        Incident(
            id: 2, city: "lincoln", agency: .police, incidentType: "disturbance",
            summary: "Two males fighting in the Kwik Shop parking lot", address: "N 27th St & Vine St",
            lat: 40.8208, lon: -96.6868, firstHeard: now - 1500, lastHeard: now - 900, status: "active", txCount: 5,
            units: ["baker 12": "clear", "baker 14": "en_route"],
            delayed: true, delaySec: 863, locationKind: "intersection", locationConfidence: 0.85,
            heardAs: "27th and Vine, the Kwik Shop", reportedWrong: false, transmissions: nil
        ),
        Incident(
            id: 3, city: "lincoln", agency: .sheriff, incidentType: "injury accident",
            summary: "Two-vehicle injury accident blocking the eastbound lane", address: "Nebraska Highway 2 & S 84th St",
            lat: 40.7512, lon: -96.6067, firstHeard: now - 4000, lastHeard: now - 3500, status: "cleared", txCount: 7,
            units: ["lancaster 14": "clear", "lancaster 22": "on_scene", "medic 1": "on_scene"],
            delayed: false, delaySec: 0, locationKind: "intersection", locationConfidence: 0.88,
            heardAs: "Highway 2 and 84th Street", reportedWrong: false, transmissions: nil
        ),
    ]

    static let transmissions: [Transmission] = [
        Transmission(
            id: 9, incidentId: 1, agency: .fire, incidentType: nil, occurredAt: now - 60, heardAt: now - 60,
            transcript: "Truck 8 on scene, two story residential, smoke showing side alpha, establishing 33rd Street command.",
            summary: nil, address: nil, lat: nil, lon: nil, audioFile: "1790000000009.wav", duration: 6.1, units: ["Truck 8"]
        ),
        Transmission(
            id: 8, incidentId: nil, agency: .police, incidentType: nil, occurredAt: now - 120, heardAt: now - 120,
            transcript: "Lincoln, radio check.", summary: nil, address: nil, lat: nil, lon: nil,
            audioFile: "1790000000008.wav", duration: 1.2, units: []
        ),
        Transmission(
            id: 4, incidentId: 2, agency: .police, incidentType: "disturbance", occurredAt: now - 1500 - 863, heardAt: now - 1500,
            transcript: "Baker 12, Baker 14, disturbance, 27th and Vine, the Kwik Shop, two males fighting in the parking lot, time is 11:52.",
            summary: "Two males fighting in the Kwik Shop parking lot", address: "N 27th St & Vine St", lat: 40.8208, lon: -96.6868,
            audioFile: "1790000000004.wav", duration: 9.7, units: ["Baker 12", "Baker 14"]
        ),
        Transmission(
            id: 1, incidentId: 1, agency: .fire, incidentType: "structure fire", occurredAt: now - 600, heardAt: now - 600,
            transcript: "Truck 8, Engine 1, Battalion 1, structure fire, 1621 North 33rd Street, caller reports smoke showing from the second floor.",
            summary: "Structure fire, smoke showing from the second floor", address: "1621 N 33rd St", lat: 40.8268, lon: -96.69,
            audioFile: "1790000000001.wav", duration: 10.4, units: ["Truck 8", "Engine 1", "Battalion 1"]
        ),
    ]

    static let city = City(
        id: "lincoln", name: "Lincoln, NE", tz: "America/Chicago", center: [40.8136, -96.7026],
        bbox: [-96.85, 40.65, -96.50, 40.95],
        agencies: [
            "police": AgencyInfo(name: "Lincoln Police Department", delayed: true),
            "fire": AgencyInfo(name: "Lincoln Fire & Rescue", delayed: false),
            "sheriff": AgencyInfo(name: "Lancaster County Sheriff", delayed: false),
        ],
        incidentTypes: ["structure fire", "vehicle fire", "medical", "shooting", "disturbance", "traffic stop", "other"]
    )

    @MainActor
    static func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "livewire.previews")!
        defaults.removePersistentDomain(forName: "livewire.previews")
        let m = AppModel(settings: Settings(defaults: defaults))
        m.city = city
        for i in incidents { m.apply(.incident(i)) }
        for t in transmissions.reversed() { m.apply(.transmission(t)) }
        m.apply(.connected(.live))
        return m
    }
}
