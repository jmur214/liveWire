import SwiftUI

/// Placeholder until the AudioEngine lands (build step 5).
struct PillPlayer: View {
    var body: some View {
        HStack {
            Text("SCANNER PAUSED")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .floatingSurface(radius: Theme.Radius.pill)
    }
}
