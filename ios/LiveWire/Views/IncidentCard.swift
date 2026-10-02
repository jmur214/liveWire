import SwiftUI

/// Pin tap → compact card (A2.2). Exactly: type, address, distance/time/agency
/// chips, and "More details". Close, swipe-down or a map tap dismisses.
struct IncidentCard: View {
    @Environment(AppModel.self) private var model
    var incident: Incident

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgencyDot(agency: incident.agency, size: 10)
                Text(incident.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { model.select(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .background(Theme.muted.opacity(0.12), in: Circle())
                        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text(incident.addressText)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .lineLimit(2)

            HStack(spacing: 8) {
                Chip(text: model.distanceText(to: incident), bold: true)
                Chip(text: "\(Format.time(incident.lastHeard)) · \(Format.agoLong(incident.lastHeard, now: model.now))")
                Chip(text: incident.agency.displayName, tint: incident.agency.color)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            Button { model.openDetail(incident.id) } label: {
                Text("More details")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .panelSurface(radius: Theme.Radius.card)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in if v.translation.height > 40 { model.select(nil) } }
        )
    }
}

#Preview {
    VStack {
        Spacer()
        IncidentCard(incident: Fixtures.incidents[0]).padding(12)
    }
    .background(Theme.ground)
    .environment(Fixtures.model())
}
