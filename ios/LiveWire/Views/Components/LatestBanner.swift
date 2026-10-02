import SwiftUI

/// Newest mapped incident. Tap → Detail; swipe up dismisses until the next one.
struct LatestBanner: View {
    var incident: Incident
    var distance: String
    var now: Date
    var onTap: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AgencyDot(agency: incident.agency, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(incident.title) · \(incident.addressText)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(distance) · \(Format.ago(incident.lastHeard, now: now)) · \(incident.unitsSummary.isEmpty ? "no units yet" : incident.unitsSummary)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
        .floatingSurface(radius: Theme.Radius.button)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { v in if v.translation.height < -25 { onDismiss() } }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    LatestBanner(incident: Fixtures.incidents[0], distance: "0.6 mi", now: Date(), onTap: {}, onDismiss: {})
        .padding()
        .background(Theme.ground)
}
