import CoreLocation
import Foundation

/// One radio transmission (GET /api/transmissions row, SSE `transmission` event,
/// and the rows inside an incident's `transmissions` timeline).
struct Transmission: Codable, Identifiable, Hashable {
    let id: Int
    var incidentId: Int?
    var agency: Agency
    var incidentType: String?
    var occurredAt: Double
    var heardAt: Double
    var transcript: String
    var summary: String?
    var address: String?
    var lat: Double?
    var lon: Double?
    var audioFile: String?
    var duration: Double?
    var units: [String]

    var isMapped: Bool { lat != nil && lon != nil }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// First unit mentioned, else "Dispatch" (Detail timeline).
    var primaryUnit: String { units.first.map(Format.unitName) ?? "Dispatch" }

    /// One-line summary for mapped feed rows.
    var headline: String? {
        if let s = summary, !s.isEmpty { return s }
        if let t = incidentType, !t.isEmpty { return Format.capitalizedFirst(t) }
        return nil
    }

    func matches(search q: String) -> Bool {
        let n = q.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty { return true }
        if transcript.lowercased().contains(n) { return true }
        if summary?.lowercased().contains(n) == true { return true }
        if address?.lowercased().contains(n) == true { return true }
        return units.contains { $0.lowercased().contains(n) }
    }

    static func == (a: Transmission, b: Transmission) -> Bool { a.id == b.id && a.incidentId == b.incidentId }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct TransmissionsResponse: Codable {
    var transmissions: [Transmission]
    var latestId: Int
}
