import SwiftUI

enum Agency: String, Codable, CaseIterable, Identifiable, Hashable {
    case police, fire, sheriff, unknown

    var id: String { rawValue }

    /// Unknown strings from the server decode as `.unknown` instead of failing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Agency(rawValue: raw.lowercased()) ?? .unknown
    }

    /// Filterable agencies (the chips).
    static let filterable: [Agency] = [.police, .fire, .sheriff]

    var displayName: String {
        switch self {
        case .police: return "Police"
        case .fire: return "Fire"
        case .sheriff: return "Sheriff"
        case .unknown: return "Unknown"
        }
    }

    /// "POLICE" for the 11 pt bold headers.
    var label: String { rawValue.uppercased() }

    var color: Color { Theme.agency(self) }
}
