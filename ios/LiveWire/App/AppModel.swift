import CoreLocation
import Foundation
import MapKit
import Observation
import SwiftUI

enum ConnectionState: Equatable {
    case connecting, live, polling, offline(String)

    var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .polling: return "Polling"
        case .offline(let msg): return "Offline: \(msg)"
        }
    }

    var isLive: Bool { self == .live }
}

/// Pure merge logic for incidents and transmissions, keyed by id (unit-tested).
struct FeedStore {
    /// Sorted by last_heard desc.
    private(set) var incidents: [Incident] = []
    /// Sorted by id desc (newest first).
    private(set) var transmissions: [Transmission] = []
    var maxTransmissions = 1000

    private var transmissionIds: Set<Int> = []

    /// Returns true if the incident was new.
    @discardableResult
    mutating func merge(_ inc: Incident) -> Bool {
        if let i = incidents.firstIndex(where: { $0.id == inc.id }) {
            var merged = inc
            if merged.transmissions == nil { merged.transmissions = incidents[i].transmissions }
            incidents[i] = merged
            sortIncidents()
            return false
        }
        incidents.append(inc)
        sortIncidents()
        return true
    }

    mutating func merge(incidents list: [Incident]) {
        for inc in list {
            if let i = incidents.firstIndex(where: { $0.id == inc.id }) {
                incidents[i] = inc
            } else {
                incidents.append(inc)
            }
        }
        sortIncidents()
    }

    private mutating func sortIncidents() {
        incidents.sort { ($0.lastHeard, $0.id) > ($1.lastHeard, $1.id) }
    }

    /// Returns true if the transmission was new.
    @discardableResult
    mutating func merge(_ tx: Transmission) -> Bool {
        if transmissionIds.contains(tx.id) {
            if let i = transmissions.firstIndex(where: { $0.id == tx.id }) { transmissions[i] = tx }
            return false
        }
        transmissionIds.insert(tx.id)
        // Newest first; most arrivals have the highest id, so insert near the front.
        if let first = transmissions.first, tx.id < first.id {
            let idx = transmissions.firstIndex(where: { $0.id < tx.id }) ?? transmissions.endIndex
            transmissions.insert(tx, at: idx)
        } else {
            transmissions.insert(tx, at: 0)
        }
        if transmissions.count > maxTransmissions {
            let dropped = transmissions.removeLast()
            transmissionIds.remove(dropped.id)
        }
        return true
    }

    mutating func merge(transmissions list: [Transmission]) {
        for t in list { merge(t) }
    }

    func incident(_ id: Int) -> Incident? { incidents.first { $0.id == id } }
    func transmission(_ id: Int) -> Transmission? { transmissions.first { $0.id == id } }

    var latestTransmissionId: Int? { transmissions.first?.id }

    func unreadCount(since lastSeen: Int) -> Int {
        transmissions.reduce(0) { $0 + ($1.id > lastSeen ? 1 : 0) }
    }
}

/// Thread-safe box so the stream client can ask for the latest id from any context.
final class LatestId: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int?
    var value: Int? {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

@MainActor
@Observable
final class AppModel {
    let settings: Settings
    let location = LocationService()
    let audio: AudioEngine

    private(set) var store = FeedStore()
    var city: City?
    var health: Health?
    var connection: ConnectionState = .connecting
    var lastError: String?

    /// Ticks once a second; pin ageing and "2m ago" labels derive from it.
    var now = Date()

    // Selection / navigation
    var selectedIncidentId: Int?          // compact card
    var focusedIncidentId: Int?           // enlarged pin (card or feed tap)
    var highlightedTransmissionId: Int?   // feed row highlight
    var dismissedBannerId: Int?
    var showFeed = false {
        didSet { if showFeed { markFeedSeen() } }
    }
    var showSettings = false
    var path: [Int] = []                  // Detail pushes (incident ids)

    // Map
    var cameraPosition: MapCameraPosition
    var visibleRegion: MKCoordinateRegion?
    var mapSize: CGSize = .zero

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var stream: StreamClient?
    let latestId = LatestId()

    static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    static let focusSpan = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

    init(settings: Settings) {
        self.settings = settings
        audio = AudioEngine(settings: settings)
        cameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.8136, longitude: -96.7026), span: Self.defaultSpan))
    }

    // MARK: Derived state

    var incidents: [Incident] { store.incidents }
    var transmissions: [Transmission] { store.transmissions }
    var enabledAgencies: Set<Agency> { settings.enabledAgencies }

    /// One filter drives pins, the feed and audio. Unknown-agency items follow
    /// whether anything is enabled at all.
    func passesFilter(_ a: Agency) -> Bool {
        a == .unknown ? !settings.enabledAgencies.isEmpty : settings.enabledAgencies.contains(a)
    }

    /// Pins: agency filter + remove window measured from last_heard.
    var visibleIncidents: [Incident] {
        let cutoff = now.timeIntervalSince1970 - settings.removeWindow
        return store.incidents.filter { $0.lastHeard >= cutoff && passesFilter($0.agency) }
    }

    /// Newest mapped incident (by first_heard) with traffic in the last 30 min.
    var bannerIncident: Incident? {
        let cutoff = now.timeIntervalSince1970 - 30 * 60
        let candidates = visibleIncidents.filter { $0.lastHeard >= cutoff }
        guard let newest = candidates.max(by: { ($0.firstHeard, $0.id) < ($1.firstHeard, $1.id) }) else { return nil }
        return newest.id == dismissedBannerId ? nil : newest
    }

    var selectedIncident: Incident? { selectedIncidentId.flatMap(store.incident) }

    var unreadCount: Int { store.unreadCount(since: settings.lastSeenTransmissionId) }

    var lastHourCount: Int {
        let cutoff = now.timeIntervalSince1970 - 3600
        return store.transmissions.reduce(0) { $0 + ($1.heardAt >= cutoff ? 1 : 0) }
    }

    func incident(_ id: Int) -> Incident? { store.incident(id) }

    func distanceText(to incident: Incident) -> String { location.distanceText(to: incident.coordinate) }

    func agencyName(_ a: Agency) -> String { city?.agencyName(a) ?? a.displayName }

    // MARK: Lifecycle

    @ObservationIgnored private var didResumeAudio = false

    func start() {
        location.requestWhenInUse()
        if !didResumeAudio {
            didResumeAudio = true
            // No autoplay on cold launch unless we were playing when backgrounded/killed
            // and "Resume on launch" is on.
            if settings.resumeOnLaunch && settings.wasPlaying {
                audio.startLive()
            }
        }
        if tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.now = Date()
                }
            }
        }
        reconnect()
    }

    /// (Re)build the API client from Settings and restart the initial load + stream.
    func reconnect() {
        streamTask?.cancel()
        stream?.stop()
        stream = nil
        audio.configure(api: settings.apiClient)
        guard let api = settings.apiClient else {
            connection = .offline("Invalid server URL")
            return
        }
        connection = .connecting
        streamTask = Task { [weak self] in await self?.run(api) }
    }

    private func run(_ api: APIClient) async {
        if let cities = try? await api.cities() {
            let c = cities.first { $0.id == settings.cityId } ?? cities.first
            if let c, c.id != city?.id || store.incidents.isEmpty {
                cameraPosition = .region(MKCoordinateRegion(center: c.centerCoordinate, span: Self.defaultSpan))
            }
            city = c
        }
        health = try? await api.health()
        if Task.isCancelled { return }

        do {
            let hours = max(2, settings.removeWindowMinutes / 60)
            let incs = try await api.incidents(hours: hours)
            let txs = try await api.transmissions(limit: 200)
            store.merge(incidents: incs)
            store.merge(transmissions: txs.transmissions)
            latestId.value = store.latestTransmissionId
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            connection = .offline(error.localizedDescription)
        }
        if Task.isCancelled { return }

        let latest = latestId
        let client = StreamClient(api: api) { latest.value }
        stream = client
        for await event in client.events() {
            if Task.isCancelled { break }
            apply(event)
        }
    }

    func apply(_ event: StreamClient.Event) {
        switch event {
        case .connected(let mode):
            connection = mode == .live ? .live : .polling
        case .transmission(let t):
            if store.merge(t) {
                latestId.value = store.latestTransmissionId
                didReceive(t)
            }
        case .incident(let i):
            store.merge(i)
        case .ping:
            if case .offline = connection { connection = .polling }
        case .dropped(let msg):
            connection = .offline(msg)
        }
    }

    /// Live audio (A3): every new transmission that passes the agency filter — and,
    /// with Dispatch-only on, has a summary — is appended to the player's queue.
    func shouldPlay(_ t: Transmission) -> Bool {
        passesFilter(t.agency) && (!settings.dispatchOnly || t.summary != nil)
    }

    private func didReceive(_ t: Transmission) {
        if shouldPlay(t) { audio.enqueue(t) }
    }

    func refreshHealth() async -> Health? {
        guard let api = settings.apiClient else { return nil }
        health = try? await api.health()
        return health
    }

    func fetchIncidentDetail(_ id: Int) async -> Incident? {
        guard let api = settings.apiClient else { return store.incident(id) }
        if let inc = try? await api.incident(id) {
            store.merge(inc)
            return inc
        }
        return store.incident(id)
    }

    func reportWrongLocation(_ id: Int) async -> Bool {
        guard let api = settings.apiClient else { return false }
        do {
            try await api.report(incidentId: id)
            if var inc = store.incident(id) {
                inc.reportedWrong = true
                store.merge(inc)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Filters, selection, map

    func toggle(_ agency: Agency) {
        var s = settings.enabledAgencies
        if s.contains(agency) { s.remove(agency) } else { s.insert(agency) }
        settings.enabledAgencies = s
        audio.dropQueued { !self.shouldPlay($0) }
        if let sel = selectedIncident, !passesFilter(sel.agency) { select(nil) }
    }

    /// Pin tap → compact card. The map pans so the pin sits centred above the card.
    func select(_ incident: Incident?, cardHeight: CGFloat = 250) {
        selectedIncidentId = incident?.id
        focusedIncidentId = incident?.id
        if let incident {
            pan(to: incident.coordinate, bottomInset: cardHeight, zoomIn: false)
        }
    }

    /// Feed row tap. Mapped rows pan + enlarge the pin; unmapped rows only highlight (0.5 s).
    func focus(on tx: Transmission) {
        highlightedTransmissionId = tx.id
        let hold: Double = tx.isMapped ? 2.5 : 0.5
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            if self?.highlightedTransmissionId == tx.id { self?.highlightedTransmissionId = nil }
        }
        guard tx.isMapped, let iid = tx.incidentId, let inc = store.incident(iid) else { return }
        selectedIncidentId = nil
        focusedIncidentId = iid
        // The sheet sits at the half detent, so centre the pin in the top half.
        pan(to: inc.coordinate, bottomInset: mapSize.height * 0.5, zoomIn: true)
    }

    func openDetail(_ id: Int) {
        showFeed = false
        selectedIncidentId = nil
        if path.last != id { path.append(id) }
    }

    func dismissBanner() {
        dismissedBannerId = bannerIncident?.id
    }

    func markFeedSeen() {
        if let latest = store.latestTransmissionId, latest > settings.lastSeenTransmissionId {
            settings.lastSeenTransmissionId = latest
        }
    }

    func locateMe() {
        location.requestWhenInUse()
        guard let loc = location.location else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            cameraPosition = .region(MKCoordinateRegion(center: loc.coordinate, span: Self.focusSpan))
        }
    }

    /// Centre `coordinate` in the part of the map above `bottomInset` points of overlay.
    func pan(to coordinate: CLLocationCoordinate2D, bottomInset: CGFloat, zoomIn: Bool) {
        var span = visibleRegion?.span ?? Self.focusSpan
        if zoomIn || span.latitudeDelta > 0.06 { span = Self.focusSpan }
        let height = max(mapSize.height, 1)
        let latPerPoint = span.latitudeDelta / height
        // Visible area is [0, height - inset]; its centre is inset/2 above the map centre,
        // so move the map centre south by that much.
        let center = CLLocationCoordinate2D(
            latitude: coordinate.latitude - latPerPoint * Double(bottomInset) / 2,
            longitude: coordinate.longitude)
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}
