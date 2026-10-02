import CoreLocation
import Foundation

struct AgencyInfo: Codable, Hashable {
    var name: String
    var delayed: Bool
}

struct City: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var tz: String?
    var center: [Double]
    var bbox: [Double]?
    var agencies: [String: AgencyInfo]
    var incidentTypes: [String]

    var centerCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: center.first ?? 0, longitude: center.count > 1 ? center[1] : 0)
    }

    func agencyName(_ a: Agency) -> String { agencies[a.rawValue]?.name ?? a.displayName }
}

struct CitiesResponse: Codable {
    var cities: [City]
}

struct Health: Codable, Hashable {
    var ok: Bool
    var version: String
    var city: String
    var ingestAlive: Bool
    var policeDelaySec: Int
    var lastTransmissionAt: Double?
}

struct OKResponse: Codable {
    var ok: Bool
}

struct APIErrorBody: Codable {
    var error: String
}
