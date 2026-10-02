import CoreLocation
import Foundation
import Observation
import UIKit
import UserNotifications

/// Notification permission, APNs token, and POST /api/device (rules + last location).
@MainActor
@Observable
final class PushRegistrar {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var lastSyncError: String?
    private(set) var lastSyncAt: Date?
    /// "N alerts this week" per place etc., from the server's /api/device response.
    private(set) var stats: AlertStats?

    private let settings: Settings
    private var api: APIClient?
    private var syncTask: Task<Void, Never>?
    private var lastReportedLocation: CLLocation?
    private var lastReportAt: Date = .distantPast

    /// Dev (Xcode) builds get sandbox APNs tokens; TestFlight / App Store use production.
    static var isSandboxBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    init(settings: Settings) {
        self.settings = settings
        AppDelegate.onPushToken = { [weak self] hex in
            Task { @MainActor in self?.tokenReceived(hex) }
        }
        AppDelegate.onPushTokenError = { [weak self] error in
            Task { @MainActor in self?.lastSyncError = "APNs registration failed: \(error.localizedDescription)" }
        }
        refreshAuthorization()
    }

    func configure(api: APIClient?) {
        self.api = api
        sync()
    }

    func refreshAuthorization() {
        Task { @MainActor in
            let s = await UNUserNotificationCenter.current().notificationSettings()
            authorization = s.authorizationStatus
        }
    }

    /// Master switch turned on: ask for permission, then register for a token.
    func enable() {
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            refreshAuthorization()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                lastSyncError = "Notifications are off for LiveWire in iOS Settings."
            }
            sync()
        }
    }

    /// On launch: refresh the token if alerts are on (tokens can rotate).
    func registerIfNeeded() {
        guard settings.alertRules.enabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func tokenReceived(_ hex: String) {
        if settings.pushToken != hex { settings.pushToken = hex }
        sync()
    }

    /// POST the current rules (debounced so slider drags don't spam the server).
    func sync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let api = self.api, let token = self.settings.pushToken else { return }
            let reg = DeviceRegistration(
                token: token, city: self.settings.cityId, sandbox: Self.isSandboxBuild,
                rules: self.settings.alertRules.forServer)
            do {
                let resp = try await api.registerDevice(reg)
                self.stats = resp.stats
                self.lastSyncError = nil
                self.lastSyncAt = Date()
            } catch {
                self.lastSyncError = error.localizedDescription
            }
        }
    }

    /// Near-me: report the phone's location when it moved ≥ 250 m or 5 min passed.
    func reportLocation(_ loc: CLLocation) {
        guard settings.alertRules.nearMe.enabled else { return }
        if let last = lastReportedLocation,
           loc.distance(from: last) < 250, Date().timeIntervalSince(lastReportAt) < 300 {
            return
        }
        lastReportedLocation = loc
        lastReportAt = Date()
        settings.alertRules.lastLocation = .init(
            lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, at: Date().timeIntervalSince1970)
        sync()
    }

    var statusText: String {
        if let e = lastSyncError { return e }
        switch authorization {
        case .denied: return "Notifications are off for LiveWire in iOS Settings."
        case .notDetermined: return settings.alertRules.enabled ? "Waiting for notification permission…" : "Rules are evaluated on the server; one push per incident."
        default:
            if settings.pushToken == nil { return "Waiting for a device token…" }
            if let at = lastSyncAt { return "Rules saved to the server \(Format.ago(at.timeIntervalSince1970))." }
            return "Rules are evaluated on the server; one push per incident."
        }
    }
}
