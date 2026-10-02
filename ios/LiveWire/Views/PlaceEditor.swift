import MapKit
import SwiftUI

/// Add / edit a saved place: name, address via MKLocalSearch, radius 0.1–2 mi.
struct PlaceEditor: View {
    enum Result {
        case save(AlertRules.Place)
        case delete(UUID)
        case cancel
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var place: AlertRules.Place
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var chosenAddress: String?
    @State private var searchTask: Task<Void, Never>?
    let isNew: Bool
    let onDone: (Result) -> Void

    init(place: AlertRules.Place, isNew: Bool, onDone: @escaping (Result) -> Void) {
        _place = State(initialValue: place)
        self.isNew = isNew
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Home", text: $place.name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                        TextField("Search an address or place", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onSubmit { runSearch() }
                        if searching { ProgressView() }
                    }
                    if let a = chosenAddress ?? (place.hasLocation ? "Saved location" : nil) {
                        Label(a, systemImage: "mappin.and.ellipse")
                            .foregroundStyle(Theme.text)
                            .font(.system(size: 14))
                    }
                    ForEach(results, id: \.self) { item in
                        Button {
                            choose(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Location").foregroundStyle(Theme.text)
                                Text(address(of: item)).font(.footnote).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("Only the coordinate and radius are stored on your server, never the address text.")
                }

                Section("Radius") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Alert within")
                            Spacer()
                            Text(String(format: "%.1f mi", place.radiusMi)).foregroundStyle(Theme.muted)
                        }
                        Slider(value: $place.radiusMi, in: 0.1...2, step: 0.1)
                            .accessibilityLabel("Radius")
                    }
                }

                if place.hasLocation {
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: place.lat ?? 0, longitude: place.lon ?? 0),
                            latitudinalMeters: place.radiusMi * 1609.344 * 2.6,
                            longitudinalMeters: place.radiusMi * 1609.344 * 2.6)), interactionModes: []) {
                            MapCircle(center: CLLocationCoordinate2D(latitude: place.lat ?? 0, longitude: place.lon ?? 0),
                                      radius: place.radiusMi * 1609.344)
                                .foregroundStyle(Theme.police.opacity(0.15))
                                .stroke(Theme.police, lineWidth: 1.5)
                            Marker(place.name.isEmpty ? "Place" : place.name,
                                   coordinate: CLLocationCoordinate2D(latitude: place.lat ?? 0, longitude: place.lon ?? 0))
                                .tint(Theme.police)
                        }
                        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                        .id("\(place.lat ?? 0),\(place.lon ?? 0),\(place.radiusMi)")
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete place", role: .destructive) {
                            onDone(.delete(place.id))
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add place" : "Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onDone(.cancel)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        var p = place
                        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = "Place" }
                        if isNew { p.enabled = true }
                        onDone(.save(p))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!place.hasLocation)
                }
            }
            .onChange(of: query) { scheduleSearch() }
        }
        .tint(Theme.police)
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else {
            results = []
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { runSearch() }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        let center = model.city?.centerCoordinate ?? CLLocationCoordinate2D(latitude: 40.8136, longitude: -96.7026)
        Task { @MainActor in
            defer { searching = false }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4))
            req.resultTypes = [.address, .pointOfInterest]
            do {
                let resp = try await MKLocalSearch(request: req).start()
                results = Array(resp.mapItems.prefix(6))
            } catch {
                results = []
            }
        }
    }

    private func choose(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        place.lat = c.latitude
        place.lon = c.longitude
        chosenAddress = address(of: item)
        if place.name.trimmingCharacters(in: .whitespaces).isEmpty, let n = item.name { place.name = n }
        results = []
        query = ""
    }

    private func address(of item: MKMapItem) -> String {
        let p = item.placemark
        let parts = [p.subThoroughfare, p.thoroughfare, p.locality].compactMap { $0 }
        if parts.isEmpty { return item.name ?? "Location" }
        let street = parts.prefix(2).joined(separator: " ")
        return p.locality.map { "\(street), \($0)" } ?? street
    }
}

#Preview {
    PlaceEditor(place: AlertRules.Place(name: "Home"), isNew: true) { _ in }
        .environment(Fixtures.model())
}
