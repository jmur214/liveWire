import SwiftUI

/// Placeholder until build step 6.
struct IncidentCard: View {
    var incident: Incident
    var body: some View {
        Text(incident.title).padding().panelSurface(radius: Theme.Radius.card)
    }
}
