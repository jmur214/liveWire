import SwiftUI

/// Locate-me + Feed (with unread badge), bottom-right above the pill.
struct RightRail: View {
    var unread: Int
    var onLocate: () -> Void
    var onFeed: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            RailButton(systemImage: "location.fill", label: "Locate me", action: onLocate)
            RailButton(systemImage: "list.bullet.rectangle.fill", label: "Feed", action: onFeed)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Theme.fire, in: Capsule())
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3), value: unread)
                .accessibilityValue(unread > 0 ? "\(unread) new" : "")
        }
    }
}

struct RailButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .floatingSurface(radius: Theme.touchTarget / 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    RightRail(unread: 7, onLocate: {}, onFeed: {})
        .padding()
        .background(Theme.ground)
}
