import Foundation
import Observation
import Security

enum Appearance: String, CaseIterable, Identifiable {
    case system, dark
    var id: String { rawValue }
    var label: String { self == .system ? "System" : "Always dark" }
}

/// User settings. Backed by UserDefaults (the same store `@AppStorage` uses);
/// the API token lives in the Keychain.
@Observable
final class Settings {
    private let defaults: UserDefaults

    #if DEBUG
    static let defaultServerURL = "http://localhost:8000"
    #else
    static let defaultServerURL = "https://REPLACE_ME_SERVER_HOST"
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: "serverURL") ?? Settings.defaultServerURL
        apiToken = Keychain.get("apiToken") ?? ""
        cityId = defaults.string(forKey: "cityId") ?? "lincoln"
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        dispatchOnly = defaults.bool(forKey: "dispatchOnly")
        resumeOnLaunch = defaults.object(forKey: "resumeOnLaunch") as? Bool ?? true
        fadeWindowMinutes = defaults.object(forKey: "fadeWindowMinutes") as? Double ?? 60
        removeWindowMinutes = defaults.object(forKey: "removeWindowMinutes") as? Double ?? 120
        let ag = defaults.stringArray(forKey: "enabledAgencies") ?? Agency.filterable.map(\.rawValue)
        enabledAgencies = Set(ag.compactMap(Agency.init(rawValue:)))
        wasPlaying = defaults.bool(forKey: "wasPlaying")
        lastSeenTransmissionId = defaults.integer(forKey: "lastSeenTransmissionId")
        pushToken = defaults.string(forKey: "pushToken")
        if let data = defaults.data(forKey: "alertRules"),
           let rules = try? APIClient.decoder.decode(AlertRules.self, from: data) {
            alertRules = rules
        } else {
            alertRules = AlertRules()
        }
    }

    var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    var apiToken: String { didSet { Keychain.set(apiToken.isEmpty ? nil : apiToken, for: "apiToken") } }
    var cityId: String { didSet { defaults.set(cityId, forKey: "cityId") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var dispatchOnly: Bool { didSet { defaults.set(dispatchOnly, forKey: "dispatchOnly") } }
    var resumeOnLaunch: Bool { didSet { defaults.set(resumeOnLaunch, forKey: "resumeOnLaunch") } }
    /// 15 m – 2 h
    var fadeWindowMinutes: Double { didSet { defaults.set(fadeWindowMinutes, forKey: "fadeWindowMinutes") } }
    /// 30 m – 6 h
    var removeWindowMinutes: Double { didSet { defaults.set(removeWindowMinutes, forKey: "removeWindowMinutes") } }
    var enabledAgencies: Set<Agency> {
        didSet { defaults.set(enabledAgencies.map(\.rawValue).sorted(), forKey: "enabledAgencies") }
    }
    /// Persisted playing state for "Resume on launch".
    var wasPlaying: Bool { didSet { defaults.set(wasPlaying, forKey: "wasPlaying") } }
    var lastSeenTransmissionId: Int { didSet { defaults.set(lastSeenTransmissionId, forKey: "lastSeenTransmissionId") } }
    var pushToken: String? { didSet { defaults.set(pushToken, forKey: "pushToken") } }
    var alertRules: AlertRules {
        didSet {
            if let data = try? APIClient.encoder.encode(alertRules) { defaults.set(data, forKey: "alertRules") }
        }
    }

    var fadeWindow: TimeInterval { fadeWindowMinutes * 60 }
    var removeWindow: TimeInterval { removeWindowMinutes * 60 }

    var apiClient: APIClient? { APIClient(serverURL: serverURL, token: apiToken) }
}

/// Minimal generic-password Keychain wrapper for the API token.
enum Keychain {
    private static let service = "com.livewire.app"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
