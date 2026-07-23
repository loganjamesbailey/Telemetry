import SwiftUI

// Telemetry's design language: Dieter Rams meets 80s neon.
//
// The discipline that keeps it Rams rather than vaporwave kitsch is a ratio:
//   ~90% of pixels  neutral surfaces and text
//   <=8%            accent colour, permitted ONLY where it encodes data
//   <=2%            glow
//
// Every coloured pixel must mean something. Accent on chrome, decoration, or
// "because it looks cool" is a bug. Temperature is always cyan and fan speed is
// always magenta, app-wide, so hue itself carries information.
//
// Views must never reference raw hex — only the semantic tokens below.

// MARK: - Colour

extension Color {
    /// Builds a colour that resolves per appearance. Every token is dynamic so
    /// light mode is a first-class citizen rather than an inverted afterthought.
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    fileprivate convenience init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let hasAlpha = cleaned.count == 8
        let r, g, b, a: CGFloat
        if hasAlpha {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

enum Palette {
    // Surfaces. Violet-tinted near-black so the neons harmonise rather than
    // vibrate; elevation is encoded by surface step plus a hairline, never by
    // a drop shadow (honest flatness).
    static let bgBase = Color(light: "#F5F5F7", dark: "#0D0D12")
    static let bgPanel = Color(light: "#FFFFFF", dark: "#14141C")
    static let bgCard = Color(light: "#FFFFFF", dark: "#1B1B26")
    static let bgOverlay = Color(light: "#FFFFFF", dark: "#232330")

    // Text
    static let textPrimary = Color(light: "#1D1D1F", dark: "#F2F2F7")
    static let textSecondary = Color(light: "#00000099", dark: "#FFFFFF99")
    static let textTertiary = Color(light: "#00000066", dark: "#FFFFFF61")

    // Structure. Load-bearing, not decorative: the surface steps are only
    // 3–5% luminance apart and collapse on cheap external displays.
    static let hairline = Color(light: "#0000001A", dark: "#FFFFFF14")

    // Data accents. Softened Synthwave '84 values — the pure meme hexes
    // (#00FFFF/#FF00FF) bloom on wide-gamut displays and read as kitsch.
    /// Temperature, live readouts, focus.
    static let accentData = Color(light: "#0A7C82", dark: "#36F9F6")
    static let accentDataDim = Color(light: "#0A7C8288", dark: "#1FA8A5")
    /// Fan speed, control affordances, selection.
    static let accentControl = Color(light: "#B02E8C", dark: "#FF7EDB")
    static let accentControlDim = Color(light: "#B02E8C88", dark: "#A6518F")

    // State
    static let nominal = Color(light: "#1D7A5C", dark: "#72F1B8")
    static let warn = Color(light: "#C25E00", dark: "#FF8B39")
    static let critical = Color(light: "#D62839", dark: "#FE4450")
}

// MARK: - Typography

enum Typo {
    /// Big temperature readout. Light weight reads as calm; SF Mono keeps the
    /// digits from jittering as values tick.
    static let heroReadout = Font.system(size: 36, weight: .light, design: .monospaced)
    static let readout = Font.system(size: 20, weight: .regular, design: .monospaced)
    static let readoutSmall = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let title = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    /// macOS body text is 13pt, not iOS's 17 — an iOS scale feels bloated here.
    static let body = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    /// Braun-instrument micro-label: uppercase, tracked out.
    static let sensorLabel = Font.system(size: 11, weight: .medium)
    static let axisLabel = Font.system(size: 10, weight: .regular, design: .monospaced)
}

// MARK: - Metrics

enum Metrics {
    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    static let space48: CGFloat = 48

    static let radiusControl: CGFloat = 6
    static let radiusCard: CGFloat = 10
    static let radiusPanel: CGFloat = 16

    /// 1 device pixel on a 2x display. On 1x displays 0.5pt renders blurry, so
    /// callers round up via `hairlineWidth(for:)`.
    static let hairline: CGFloat = 0.5

    static func hairlineWidth(for scale: CGFloat) -> CGFloat {
        scale >= 2 ? hairline : 1
    }

    static let popoverWidth: CGFloat = 320
}

// MARK: - Thermal state

/// Maps a temperature to its semantic state. Colour is never the only signal —
/// callers pair it with a label or icon change (Rams: "understandable", and it
/// doubles as colour-blind accessibility).
enum ThermalState {
    case cool, nominal, warm, hot

    init(celsius: Double) {
        switch celsius {
        case ..<50: self = .cool
        case ..<70: self = .nominal
        case ..<85: self = .warm
        default: self = .hot
        }
    }

    var color: Color {
        switch self {
        case .cool: return Palette.accentData
        case .nominal: return Palette.nominal
        case .warm: return Palette.warn
        case .hot: return Palette.critical
        }
    }

    var label: String {
        switch self {
        case .cool: return "COOL"
        case .nominal: return "NOMINAL"
        case .warm: return "WARM"
        case .hot: return "HOT"
        }
    }
}
