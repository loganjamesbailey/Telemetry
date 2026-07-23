import SwiftUI

/// Hairline rule. Load-bearing between adjacent dark surfaces, which sit only
/// a few percent apart in luminance.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: Metrics.hairlineWidth(for: displayScale))
    }
}

/// Braun-instrument micro-label: uppercase, tracked out, quiet.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Typo.sensorLabel)
            .tracking(0.6)
            .foregroundStyle(Palette.textTertiary)
    }
}

/// A numeric readout. Always monospaced so digits do not jitter as values
/// update, and right-alignable so columns share a decimal axis.
struct Readout: View {
    let value: String
    let unit: String?
    var font: Font = Typo.readout
    var color: Color = Palette.textPrimary
    var glow: Double = GlowLevel.off

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Text(value)
                .font(font)
                .foregroundStyle(color)
                .neonGlow(color, intensity: glow)
            if let unit {
                Text(unit)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

/// Grouped surface. Elevation is the surface step plus a hairline border —
/// no drop shadows between dark surfaces.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Metrics.space16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: Metrics.hairline)
            )
    }
}

/// One sensor in the grid: name, value, and a state dot. The dot exists so
/// state is never conveyed by colour alone.
struct SensorRow: View {
    let name: String
    let celsius: Double

    private var state: ThermalState { ThermalState(celsius: celsius) }

    var body: some View {
        HStack(spacing: Metrics.space8) {
            Circle()
                .fill(state.color)
                .frame(width: 5, height: 5)
            Text(name)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Metrics.space8)
            Text(String(format: "%.1f", celsius))
                .font(Typo.readoutSmall)
                .foregroundStyle(Palette.textPrimary)
            Text("°C")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}

/// A compact sparkline. Deliberately plain: a single stroked path, no axes, no
/// interpolation flourishes that could imply data we do not have.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Palette.accentData
    var glow: Double = GlowLevel.off

    var body: some View {
        GeometryReader { geo in
            let path = makePath(in: geo.size)
            path.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .neonGlow(color, intensity: glow)
        }
    }

    private func makePath(in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        // A flat series must render as a flat line, not divide by zero.
        let span = max(maxV - minV, 0.001)
        let stepX = size.width / CGFloat(values.count - 1)

        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height - (CGFloat((v - minV) / span) * size.height)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
