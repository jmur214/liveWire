import MapKit
import SwiftUI

/// Detail (A2.4): header, mini map, units, details grid, timeline, report.
struct IncidentDetailView: View {
    @Environment(AppModel.self) private var model
    var incidentId: Int

    @State private var detail: Incident?
    @State private var reported = false
    @State private var reporting = false
    @State private var mapPosition: MapCameraPosition = .automatic

    private var incident: Incident? { detail ?? model.incident(incidentId) }
    private var timeline: [Transmission] { detail?.transmissions ?? [] }

    var body: some View {
        Group {
            if let inc = incident {
                content(inc)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ground)
        .navigationTitle("Incident")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let inc = incident {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText(inc), subject: Text(inc.title)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .task(id: incidentId) { await load() }
        .onChange(of: model.incident(incidentId)?.txCount) {
            Task { @MainActor in await load() }
        }
    }

    @MainActor
    private func load() async {
        if let inc = await model.fetchIncidentDetail(incidentId) {
            detail = inc
            reported = inc.reportedWrong ?? false
            mapPosition = .region(MKCoordinateRegion(
                center: inc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
        }
    }

    // MARK: Layout

    private func content(_ inc: Incident) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(inc)
                miniMap(inc)
                if !inc.units.isEmpty { units(inc) }
                detailsGrid(inc)
                timelineSection(inc)
                reportButton(inc)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
    }

    private func header(_ inc: Incident) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(inc.agency.label) · \(inc.isActive ? "ACTIVE" : "CLEARED") · \(inc.txCount) TRANSMISSION\(inc.txCount == 1 ? "" : "S")")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(inc.agency.color)
            Text(inc.title)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Theme.text)
            Text(inc.addressText)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(text: model.distanceText(to: inc), bold: true)
                    Chip(text: "First \(Format.time(inc.firstHeard))")
                    Chip(text: "Last \(Format.time(inc.lastHeard))")
                }
            }
        }
    }

    private func miniMap(_ inc: Incident) -> some View {
        Map(position: $mapPosition, interactionModes: []) {
            UserAnnotation()
            Annotation("", coordinate: inc.coordinate, anchor: .center) {
                IncidentPin(incident: inc, now: model.now, fadeWindow: model.settings.fadeWindow, enlarged: true)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            Button { openInMaps(inc) } label: {
                Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .floatingSurface(radius: 18)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    private func units(_ inc: Incident) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Units")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(inc.unitChips) { chip in
                    HStack(spacing: 6) {
                        Text(chip.unit).font(.system(size: 13, weight: .semibold))
                        Text(chip.status).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(statusTint(chip.status).opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private func detailsGrid(_ inc: Incident) -> some View {
        let kind = inc.locationKind.map(Format.capitalizedFirst) ?? "—"
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            cell("Agency", model.agencyName(inc.agency))
            cell("Feed timing", Format.feedTiming(delayed: inc.delayed, delaySec: inc.delaySec))
            cell("Heard as", inc.heardAs ?? "—")
            cell("Location confidence", "\(inc.confidenceLabel) · \(kind)")
        }
    }

    private func timelineSection(_ inc: Incident) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Timeline")
                Spacer()
                if model.audio.mode == .playAll {
                    Button { model.audio.stopReplay() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button { model.audio.playAll(Array(timeline.reversed())) } label: {
                        Label("Play all", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(timeline.isEmpty)
                }
            }
            if timeline.isEmpty {
                Text("Loading transmissions…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            VStack(spacing: 0) {
                ForEach(timeline) { tx in
                    TimelineRow(tx: tx, playing: model.audio.current?.id == tx.id) { model.audio.replay(tx) }
                    if tx.id != timeline.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        }
    }

    private func reportButton(_ inc: Incident) -> some View {
        Button {
            guard !reported, !reporting else { return }
            reporting = true
            Task { @MainActor in
                if await model.reportWrongLocation(inc.id) { reported = true }
                reporting = false
            }
        } label: {
            Text(reported ? "Reported" : "Report wrong location")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(reported ? Theme.muted : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(reported || reporting)
    }

    // MARK: Pieces

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.muted)
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "on scene": return Theme.fire
        case "en route": return Theme.sheriff
        case "clear": return Theme.muted
        default: return Theme.police
        }
    }

    private func shareText(_ inc: Incident) -> String {
        var lines = ["\(inc.title) · \(inc.addressText)"]
        if let s = inc.summary { lines.append(s) }
        lines.append("Heard \(Format.time(inc.firstHeard))–\(Format.time(inc.lastHeard)) · \(model.agencyName(inc.agency))")
        let q = inc.addressText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        lines.append("https://maps.apple.com/?ll=\(inc.lat),\(inc.lon)&q=\(q)")
        return lines.joined(separator: "\n")
    }

    private func openInMaps(_ inc: Incident) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: inc.coordinate))
        item.name = "\(inc.title) · \(inc.addressText)"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

/// Timeline row: time, unit (first unit mentioned, else "Dispatch"), transcript, Play.
struct TimelineRow: View {
    var tx: Transmission
    var playing: Bool
    var onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Format.time(tx.occurredAt))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Text(tx.primaryUnit)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tx.agency.color)
                }
                Text(tx.transcript)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onPlay) {
                Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(Theme.text.opacity(0.12), in: Circle())
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tx.audioFile == nil)
            .accessibilityLabel("Play")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

#Preview {
    NavigationStack {
        IncidentDetailView(incidentId: 1)
    }
    .environment(Fixtures.model())
}
