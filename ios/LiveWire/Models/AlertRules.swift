import Foundation

/// Alert rules, stored on the server (POST /api/device) and evaluated there. Shape: DESIGN.md B3.
struct AlertRules: Codable, Equatable {
    struct Place: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var lat: Double?
        var lon: Double?
        var radiusMi: Double = 0.5
        var enabled: Bool = false

        var hasLocation: Bool { lat != nil && lon != nil }
    }

    struct NearMe: Codable, Equatable {
        var enabled: Bool = false
        var radiusMi: Double = 0.5
    }

    struct Quiet: Codable, Equatable {
        var enabled: Bool = false
        var start: String = "23:00"
        var end: String = "07:00"
        var allow: [String] = []
    }

    struct LastLocation: Codable, Equatable {
        var lat: Double
        var lon: Double
        var at: Double
    }

    var enabled: Bool = false
    var types: [String] = []
    var places: [Place] = [Place(name: "Home"), Place(name: "Work")]
    var nearMe: NearMe = NearMe()
    var quiet: Quiet = Quiet()
    var lastLocation: LastLocation?

    /// What the server receives: places without a resolved address are dropped.
    var forServer: AlertRules {
        var r = self
        r.places = places.filter(\.hasLocation)
        return r
    }
}

struct DeviceRegistration: Codable {
    var token: String
    var city: String
    var sandbox: Bool
    var rules: AlertRules
}

/// Alerts delivered in the last 7 days, from the POST /api/device response.
struct AlertStats: Codable, Equatable {
    var weekTotal: Int
    var places: [String: Int]
    var types: Int
    var nearMe: Int
}

struct DeviceResponse: Codable {
    var ok: Bool
    var stats: AlertStats?
}

struct ReportBody: Codable {
    var incidentId: Int
    var reason: String
}
