import SwiftUI

/// Police · Fire · Sheriff toggles. Off = 45 % opacity + strikethrough.
struct AgencyChips: View {
    var enabled: Set<Agency>
    var toggle: (Agency) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Agency.filterable) { agency in
                let on = enabled.contains(agency)
                Button { toggle(agency) } label: {
                    HStack(spacing: 6) {
                        AgencyDot(agency: agency)
                        Text(agency.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .strikethrough(!on, color: Theme.text)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .floatingSurface(radius: Theme.Radius.chip)
                    .opacity(on ? 1 : 0.45)
                    .frame(minHeight: Theme.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(agency.displayName) \(on ? "shown" : "hidden")")
            }
        }
    }
}

#Preview {
    AgencyChips(enabled: [.police, .fire]) { _ in }
        .padding()
        .background(Theme.ground)
}
