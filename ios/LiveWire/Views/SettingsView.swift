import SwiftUI

/// Settings (A2.5): City, Server (URL + token + Test), Appearance, Audio, Map,
/// Alerts (own screen), About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var serverDraft = ""
    @State private var tokenDraft = ""
    @State private var testing = false
    @State private var testResult: TestResult?
    @FocusState private var focused: Field?

    private enum Field { case server, token }
    private enum TestResult {
        case ok(Health)
        case fail(String)
    }

    private var dirty: Bool {
        serverDraft.trimmingCharacters(in: .whitespaces) != model.settings.serverURL || tokenDraft != model.settings.apiToken
    }

    private var cityOptions: [City] {
        if !model.cities.isEmpty { return model.cities }
        return [model.city].compactMap { $0 }
    }

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                Section("City") {
                    if cityOptions.isEmpty {
                        Text("Connect to a server to list cities").foregroundStyle(Theme.muted)
                    } else {
                        Picker("City", selection: $settings.cityId) {
                            ForEach(cityOptions) { c in Text(c.name).tag(c.id) }
                        }
                    }
                }

                Section {
                    TextField("https://scanner.example.com", text: $serverDraft)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .server)
                        .onSubmit { apply() }
                    SecureField("API token", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .token)
                        .onSubmit { apply() }
                    HStack {
                        Button("Apply") { apply() }
                            .disabled(!dirty)
                        Spacer()
                        Button { test() } label: {
                            if testing { ProgressView() } else { Text("Test") }
                        }
                        .disabled(testing)
                    }
                    if let r = testResult { testRow(r) }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Every request carries the token as a bearer header. The token is kept in the Keychain. Changes apply without relaunching.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(Appearance.allCases) { a in Text(a.label).tag(a) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Dispatch only", isOn: $settings.dispatchOnly)
                    Toggle("Resume on launch", isOn: $settings.resumeOnLaunch)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Dispatch only skips acknowledgements and plays transmissions that describe an incident. Resume on launch continues playing if the app was playing when it was closed.")
                }

                Section("Map") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Fade window")
                            Spacer()
                            Text(minutes(settings.fadeWindowMinutes)).foregroundStyle(Theme.muted)
                        }
                        Slider(value: $settings.fadeWindowMinutes, in: 15...120, step: 5)
                            .accessibilityLabel("Fade window")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Remove window")
                            Spacer()
                            Text(minutes(settings.removeWindowMinutes)).foregroundStyle(Theme.muted)
                        }
                        Slider(value: $settings.removeWindowMinutes, in: 30...360, step: 15)
                            .accessibilityLabel("Remove window")
                    }
                }

                Section("Alerts") {
                    NavigationLink {
                        AlertsView()
                    } label: {
                        HStack {
                            Text("Alerts")
                            Spacer()
                            Text(settings.alertRules.enabled ? "On" : "Off").foregroundStyle(Theme.muted)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("App version", value: appVersion)
                    LabeledContent("Server version", value: model.health?.version ?? "—")
                    LabeledContent("Connection", value: model.connection.label)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        apply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                serverDraft = settings.serverURL
                tokenDraft = settings.apiToken
            }
            .onChange(of: settings.fadeWindowMinutes) {
                if settings.removeWindowMinutes < settings.fadeWindowMinutes {
                    settings.removeWindowMinutes = settings.fadeWindowMinutes
                }
            }
            .onChange(of: settings.removeWindowMinutes) {
                if settings.removeWindowMinutes < settings.fadeWindowMinutes {
                    settings.fadeWindowMinutes = settings.removeWindowMinutes
                }
            }
        }
        .tint(Theme.police)
    }

    // MARK: Actions

    /// Commit the drafts to Settings; RootView reconnects on change.
    private func apply() {
        let url = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if url != model.settings.serverURL { model.settings.serverURL = url }
        if tokenDraft != model.settings.apiToken { model.settings.apiToken = tokenDraft }
        focused = nil
    }

    private func test() {
        apply()
        testing = true
        testResult = nil
        let url = serverDraft, token = tokenDraft
        Task { @MainActor in
            defer { testing = false }
            guard let api = APIClient(serverURL: url, token: token) else {
                testResult = .fail("Enter a valid http(s) URL")
                return
            }
            do {
                let h = try await api.health()
                testResult = .ok(h)
                model.health = h
            } catch {
                testResult = .fail(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func testRow(_ r: TestResult) -> some View {
        switch r {
        case .ok(let h):
            VStack(alignment: .leading, spacing: 4) {
                Label("Server OK · v\(h.version) · \(h.city)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.live)
                Text("Ingest \(h.ingestAlive ? "alive" : "down") · police delay \(Format.feedTiming(delayed: true, delaySec: h.policeDelaySec).replacingOccurrences(of: "Delayed ", with: "")) · last transmission \(h.lastTransmissionAt.map { Format.ago($0) } ?? "never")")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        case .fail(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.fire)
                .font(.footnote)
        }
    }

    private func minutes(_ m: Double) -> String {
        let v = Int(m)
        if v % 60 == 0 { return "\(v / 60) h" }
        if v > 60 { return "\(v / 60) h \(v % 60) m" }
        return "\(v) min"
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

#Preview {
    SettingsView().environment(Fixtures.model())
}
