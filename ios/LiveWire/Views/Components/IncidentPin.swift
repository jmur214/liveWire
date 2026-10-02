import SwiftUI

/// Map pin. 18 pt at age 0 → 12 pt at the fade window; opacity 1 → 0.35; 26 pt when
/// enlarged (selected). A pulsing ring marks traffic in the last 2 minutes.
struct IncidentPin: View {
    var incident: Incident
    var now: Date
    var fadeWindow: TimeInterval
    var enlarged: Bool

    @State private var pulse = false

    var body: some View {
        let age = max(0, now.timeIntervalSince1970 - incident.lastHeard)
        let f = fadeWindow > 0 ? min(1, age / fadeWindow) : 1
        let size: CGFloat = enlarged ? 26 : (18 - 6 * CGFloat(f))
        let opacity = enlarged ? 1.0 : (1 - 0.65 * f)
        let color = incident.agency.color
        let recent = incident.hasRecentTraffic(now: now)

        ZStack {
            if recent {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 4)
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        }
        .opacity(opacity)
        .frame(width: Theme.touchTarget, height: Theme.touchTarget)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.25), value: enlarged)
        .accessibilityLabel("\(incident.title), \(incident.addressText)")
    }
}

#Preview {
    HStack(spacing: 30) {
        IncidentPin(incident: Fixtures.incidents[0], now: Date(), fadeWindow: 3600, enlarged: false)
        IncidentPin(incident: Fixtures.incidents[1], now: Date(), fadeWindow: 3600, enlarged: true)
        IncidentPin(incident: Fixtures.incidents[2], now: Date().addingTimeInterval(3000), fadeWindow: 3600, enlarged: false)
    }
    .padding()
    .background(Theme.ground)
}
