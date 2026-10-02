import SwiftUI

/// Bottom pill (A2.1): 64 pt, material blur, 48 pt play/pause, two text lines and
/// a 5-bar meter. Tapping the text opens the feed.
struct PillPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let audio = model.audio
        let shown = audio.current ?? audio.lastTransmission
        let tint: Color = audio.isLive || audio.isPlayingSomething ? (audio.current?.agency.color ?? Theme.live) : Theme.muted

        HStack(spacing: 12) {
            Button { audio.toggleLive() } label: {
                Image(systemName: audio.isLive ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(audio.isLive ? Theme.ground : Theme.text)
                    .frame(width: 48, height: 48)
                    .background(audio.isLive ? Theme.text : Theme.text.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isLive ? "Pause scanner" : "Play scanner")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if audio.isLive || audio.isPlayingSomething { LiveDot(color: tint) }
                    Text(line1(audio))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(shown?.transcript ?? "Tap play to listen live")
                    .font(.system(size: 14))
                    .foregroundStyle(shown == nil ? Theme.muted : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.showFeed = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the feed")

            if audio.isPlayingSomething || audio.isLive {
                LevelMeter(level: audio.level, color: tint)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 64)
        .floatingSurface(radius: Theme.Radius.pill)
    }

    private func line1(_ audio: AudioEngine) -> String {
        var s: String
        switch audio.mode {
        case .replay, .playAll:
            s = "REPLAY · \(audio.current?.agency.label ?? "") · \(audio.current?.primaryUnit.uppercased() ?? "")"
        case .live:
            s = "LIVE · \(audio.current?.agency.label ?? "") · \(audio.current?.primaryUnit.uppercased() ?? "")"
        case .idle:
            s = audio.isLive ? (audio.isBuffering ? "LIVE · LOADING" : "LIVE · LISTENING") : "SCANNER PAUSED"
        }
        if audio.skippedNotice > 0 { s += " · SKIPPED \(audio.skippedNotice)" }
        return s
    }
}

/// Five bars driven by the player's level (0…1).
struct LevelMeter: View {
    var level: Float
    var color: Color

    private let heights: [CGFloat] = [8, 14, 20, 14, 8]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(level >= Float(i + 1) / 6 ? color : color.opacity(0.25))
                    .frame(width: 3, height: heights[i])
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack {
        Spacer()
        PillPlayer().environment(Fixtures.model()).padding(16)
    }
    .background(Theme.ground)
}
