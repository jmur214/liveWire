import SwiftUI

/// Alerts (A2.6): master switch, incident types, saved places, near me now, quiet hours.
/// Rules live in Settings.alertRules and are POSTed to /api/device on every change.
struct AlertsView: View {
    @Environment(AppModel.self) private var model

    @State private var editingPlace: AlertRules.Place?
    @State private var addingPlace = false
    @State private var nearMeExplainer = false

    private var types: [String] { model.city?.incidentTypes ?? Fixtures.city.incidentTypes }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Alerts", isOn: $settings.alertRules.enabled)
            } footer: {
                Text(model.push.statusText)
            }

            Section("Incident types, anywhere in city") {
                NavigationLink {
                    TypeChecklist(title: "Incident types", types: types, selection: $settings.alertRules.types)
                } label: {
                    HStack {
                        Text("Types")
                        Spacer()
                        Text(summary(settings.alertRules.types)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }

            Section("Near saved places, any type") {
                ForEach($settings.alertRules.places) { $place in
                    PlaceRow(place: $place, alertsThisWeek: model.push.stats?.count(forPlace: place.name) ?? 0) {
                        editingPlace = place
                    }
                }
                Button {
                    addingPlace = true
                } label: {
                    Label("Add place", systemImage: "plus.circle.fill")
                }
            }

            Section {
                Toggle("Near me now", isOn: nearMeBinding)
                if settings.alertRules.nearMe.enabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Radius")
                            Spacer()
                            Text(String(format: "%.1f mi", settings.alertRules.nearMe.radiusMi)).foregroundStyle(Theme.muted)
                        }
                        Slider(value: $settings.alertRules.nearMe.radiusMi, in: 0.1...2, step: 0.1)
                            .accessibilityLabel("Near me radius")
                    }
                }
            } header: {
                Text("Near me now")
            } footer: {
                Text("Alerts for any incident within the radius of where your phone is. Needs Always location and reports your position to the server every few minutes, which uses more battery.")
            }

            Section {
                Toggle("Quiet hours", isOn: $settings.alertRules.quiet.enabled)
                if settings.alertRules.quiet.enabled {
                    DatePicker("Start", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                    NavigationLink {
                        TypeChecklist(title: "Still alert for", types: types, selection: $settings.alertRules.quiet.allow)
                    } label: {
                        HStack {
                            Text("Still alert for")
                            Spacer()
                            Text(summary(settings.alertRules.quiet.allow)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("During quiet hours only the types in the allow-list get through.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingPlace) { place in
            PlaceEditor(place: place, isNew: false) { result in
                switch result {
                case .save(let p):
                    if let i = settings.alertRules.places.firstIndex(where: { $0.id == p.id }) {
                        settings.alertRules.places[i] = p
                    }
                case .delete(let id):
                    settings.alertRules.places.removeAll { $0.id == id }
                case .cancel:
                    break
                }
            }
        }
        .sheet(isPresented: $addingPlace) {
            PlaceEditor(place: AlertRules.Place(name: "", enabled: true), isNew: true) { result in
                if case .save(let p) = result { settings.alertRules.places.append(p) }
            }
        }
        .alert("Near me now uses your location in the background", isPresented: $nearMeExplainer) {
            Button("Turn on") { model.setNearMe(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LiveWire will ask for Always location access and send your approximate position to your server every few minutes while this is on. This uses more battery.")
        }
        .onChange(of: settings.alertRules) { model.push.sync() }
        .onChange(of: settings.alertRules.enabled) { _, on in
            if on { model.push.enable() }
        }
        .onAppear { model.push.refreshAuthorization() }
    }

    // MARK: Bindings / helpers

    private var nearMeBinding: Binding<Bool> {
        Binding(
            get: { model.settings.alertRules.nearMe.enabled },
            set: { on in
                if on { nearMeExplainer = true } else { model.setNearMe(false) }
            }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<AlertRules.Quiet, String>) -> Binding<Date> {
        Binding(
            get: { Self.date(fromHHMM: model.settings.alertRules.quiet[keyPath: keyPath]) },
            set: { model.settings.alertRules.quiet[keyPath: keyPath] = Self.hhmm(from: $0) }
        )
    }

    private func summary(_ list: [String]) -> String {
        if list.isEmpty { return "None" }
        if list.count <= 2 { return list.map(Format.capitalizedFirst).joined(separator: ", ") }
        return "\(list.count) selected"
    }

    static func date(fromHHMM s: String) -> Date {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = parts.count > 0 ? parts[0] : 0
        comps.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    static func hhmm(from d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// One saved place: on/off, radius, "N alerts this week"; tap to edit.
struct PlaceRow: View {
    @Binding var place: AlertRules.Place
    var alertsThisWeek: Int
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name.isEmpty ? "Place" : place.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(place.hasLocation
                         ? "\(String(format: "%.1f", place.radiusMi)) mi · \(alertsThisWeek) alert\(alertsThisWeek == 1 ? "" : "s") this week"
                         : "Tap to set an address")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $place.enabled)
                .labelsHidden()
                .disabled(!place.hasLocation)
                .accessibilityLabel("\(place.name) alerts")
        }
    }
}

/// Checklist of the server's incident-type vocabulary.
struct TypeChecklist: View {
    var title: String
    var types: [String]
    @Binding var selection: [String]

    var body: some View {
        List {
            ForEach(types, id: \.self) { t in
                Button {
                    if let i = selection.firstIndex(of: t) { selection.remove(at: i) } else { selection.append(t) }
                } label: {
                    HStack {
                        Text(Format.capitalizedFirst(t)).foregroundStyle(Theme.text)
                        Spacer()
                        if selection.contains(t) {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.police)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.isEmpty ? "All" : "Clear") {
                    selection = selection.isEmpty ? types : []
                }
            }
        }
    }
}

#Preview {
    NavigationStack { AlertsView() }.environment(Fixtures.model())
}
