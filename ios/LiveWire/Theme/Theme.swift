import SwiftUI
import UIKit

/// Visual language from DESIGN.md A5. Agency colours are identical in both modes;
/// surfaces follow the system (or the Settings "Always dark" override).
enum Theme {
    // MARK: Agency palette
    static let police = Color(hex: 0x4F8EF7)
    static let fire = Color(hex: 0xF05D4F)
    static let sheriff = Color(hex: 0xD8A93C)
    static let unknown = Color(hex: 0x8A90A3)

    static func agency(_ a: Agency) -> Color {
        switch a {
        case .police: return police
        case .fire: return fire
        case .sheriff: return sheriff
        case .unknown: return unknown
        }
    }

    // MARK: Surfaces (dark / light)
    static let ground = Color.dynamic(dark: 0x0F1115, light: 0xEEF0F3)
    static let panel = Color.dynamic(dark: 0x171A21, light: 0xFFFFFF)
    static let text = Color.dynamic(dark: 0xE6E8EE, light: 0x14171C)
    static let muted = Color.dynamic(dark: 0x9AA1B4, light: 0x5B6270)
    static let hairline = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.08)
    })
    static let live = Color(hex: 0x3DDC84)

    // MARK: Radii
    enum Radius {
        static let card: CGFloat = 22
        static let pill: CGFloat = 32
        static let chip: CGFloat = 17
        static let button: CGFloat = 14
        static let cell: CGFloat = 12
    }

    static let touchTarget: CGFloat = 44
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { t in
            let v = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// `.ultraThinMaterial` + hairline border + the A5 shadow, for every floating surface.
struct FloatingSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.15), radius: 30, x: 0, y: 8)
    }
}

/// Opaque panel card (compact card, detail sections): panel colour + hairline.
struct PanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.15), radius: 30, x: 0, y: 8)
    }
}

extension View {
    func floatingSurface(radius: CGFloat) -> some View { modifier(FloatingSurface(radius: radius)) }
    func panelSurface(radius: CGFloat) -> some View { modifier(PanelSurface(radius: radius)) }
}

/// A small coloured dot used everywhere an agency is shown.
struct AgencyDot: View {
    var agency: Agency
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(Theme.agency(agency)).frame(width: size, height: size)
    }
}

/// Chip with the A5 geometry (radius 17, weight 600).
struct Chip: View {
    var text: String
    var bold = false
    var tint: Color? = nil
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: bold ? .bold : .semibold))
            .foregroundStyle(tint ?? Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background((tint ?? Theme.muted).opacity(0.12), in: Capsule())
    }
}

/// Pulsing live indicator.
struct LiveDot: View {
    var color: Color = Theme.live
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Formatting helpers

enum Format {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "11:52 AM"
    static func time(_ unix: Double) -> String {
        clock.string(from: Date(timeIntervalSince1970: unix))
    }

    /// "2m ago", "45s ago", "1.2h ago"
    static func ago(_ unix: Double, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince1970 - unix)
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return String(format: "%.1fh ago", s / 3600) }
        return "\(Int(s / 86400))d ago"
    }

    /// "11:52 AM · 2m ago"
    static func timeAndAgo(_ unix: Double, now: Date = Date()) -> String {
        "\(time(unix)) · \(ago(unix, now: now))"
    }

    /// 0.6 mi (<10 mi, one decimal) or 12 mi; "—" when unknown.
    static func distance(meters: Double?) -> String {
        guard let m = meters else { return "—" }
        let mi = m / 1609.344
        if mi < 10 { return String(format: "%.1f mi", mi) }
        return "\(Int(mi.rounded())) mi"
    }

    /// "Delayed ~14 min" / "Live"
    static func feedTiming(delayed: Bool, delaySec: Int) -> String {
        guard delayed, delaySec > 0 else { return "Live" }
        return "Delayed ~\(max(1, Int((Double(delaySec) / 60).rounded()))) min"
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// "engine 1" -> "Engine 1"; "battalion 1" -> "Battalion 1"
    static func unitName(_ s: String) -> String {
        s.split(separator: " ").map { capitalizedFirst(String($0)) }.joined(separator: " ")
    }

    static func unitStatus(_ s: String) -> String {
        switch s {
        case "en_route": return "en route"
        case "on_scene": return "on scene"
        case "clear": return "clear"
        default: return "dispatched"
        }
    }
}
