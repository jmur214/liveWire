import CoreLocation
import Foundation

/// One incident as returned by GET /api/incidents (and /api/incidents/{id}, which adds `transmissions`).
struct Incident: Codable, Identifiable, Hashable {
    let id: Int
    var city: String?
    var agency: Agency
    var incidentType: String?
    var summary: String?
    var address: String?
    var lat: Double
    var lon: Double
    var firstHeard: Double
    var lastHeard: Double
    var status: String
    var txCount: Int
    var units: [String: String]
    var delayed: Bool
    var delaySec: Int
    var locationKind: String?
    var locationConfidence: Double?
    var heardAs: String?
    var reportedWrong: Bool?
    /// Only present on the detail endpoint. Newest first.
    var transmissions: [Transmission]?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }
    var isActive: Bool { status == "active" }

    /// "Structure fire" — the big title everywhere.
    var title: String {
        if let t = incidentType, !t.isEmpty { return Format.capitalizedFirst(t) }
        if let s = summary, !s.isEmpty { return s }
        return "Incident"
    }

    var addressText: String { address ?? heardAs ?? "Unknown location" }

    /// High / Medium / Low from extract_confidence ≥.8 / ≥.6 / else.
    var confidenceLabel: String {
        let c = locationConfidence ?? 0
        if c >= 0.8 { return "High" }
        if c >= 0.6 { return "Medium" }
        return "Low"
    }

    /// Units as "Engine 1 en route" chips, stable order.
    var unitChips: [(unit: String, status: String)] {
        units.keys.sorted().map { (unit: Format.unitName($0), status: Format.unitStatus(units[$0] ?? "dispatched")) }
    }

    /// "Truck 8, Battalion 1" for banners and push bodies.
    var unitsSummary: String {
        units.keys.sorted().map(Format.unitName).joined(separator: ", ")
    }

    func hasRecentTraffic(now: Date, within seconds: TimeInterval = 120) -> Bool {
        now.timeIntervalSince1970 - lastHeard <= seconds
    }

    static func == (a: Incident, b: Incident) -> Bool { a.id == b.id && a.lastHeard == b.lastHeard && a.txCount == b.txCount && a.status == b.status && a.units == b.units && a.summary == b.summary && a.incidentType == b.incidentType && a.reportedWrong == b.reportedWrong }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct IncidentsResponse: Codable {
    var incidents: [Incident]
}
