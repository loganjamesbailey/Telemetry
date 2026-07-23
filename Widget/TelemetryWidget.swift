import SwiftUI
import TelemetryShared
import WidgetKit

// The desktop widget: the app's last snapshot, honestly aged. No glow — a
// widget sits on the desktop as furniture, and the honest-light rule from the
// design system applies doubly here.
//
// Colour values mirror App/Design/DesignTokens.swift; the widget target cannot
// link the app target, so the four hexes it needs are restated here.

private enum WPalette {
    static let bg = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x1C / 255)
    static let cyan = Color(red: 0x36 / 255, green: 0xF9 / 255, blue: 0xF6 / 255)
    static let cyanLight = Color(red: 0x0A / 255, green: 0x7C / 255, blue: 0x82 / 255)
    static let magenta = Color(red: 0xFF / 255, green: 0x7E / 255, blue: 0xDB / 255)
    static let magentaLight = Color(red: 0xB0 / 255, green: 0x2E / 255, blue: 0x8C / 255)

    static func temp(_ scheme: ColorScheme) -> Color { scheme == .dark ? cyan : cyanLight }
    static func fan(_ scheme: ColorScheme) -> Color { scheme == .dark ? magenta : magentaLight }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    var isStale: Bool {
        guard let snapshot else { return true }
        return Date().timeIntervalSince(snapshot.timestamp) > WidgetSnapshot.staleAfter
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(
            timestamp: Date(), primaryName: "CPU Hottest", primaryTempC: 48.5,
            fanRPM: 0, fanModeDescription: "AUTO",
            tempTrend: [46, 47, 45, 48, 52, 50, 49, 48]
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotFile.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotFile.read())
        // The app pushes reloads on real changes; this is just the fallback
        // cadence that also lets staleness become visible.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct TelemetryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private func content(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.primaryName.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if entry.isStale {
                    Text("as of \(s.timestamp, style: .relative) ago")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: String(format: "%.0f", s.primaryTempC))
                    .font(.system(size: 30, weight: .light, design: .monospaced))
                    .foregroundStyle(WPalette.temp(scheme))
                Text("°C")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if family == .systemMedium, s.tempTrend.count > 1 {
                TrendLine(values: s.tempTrend, color: WPalette.temp(scheme))
                    .frame(height: 22)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(verbatim: s.fanRPM > 0 ? String(format: "%.0f RPM", s.fanRPM) : "fan idle")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(WPalette.fan(scheme))
                Spacer()
                Text(s.fanModeDescription)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(entry.isStale ? 0.5 : 1)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("TELEMETRY")
                .font(.system(size: 9, weight: .medium)).tracking(1.2)
                .foregroundStyle(.tertiary)
            Text("Open the app to start")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Plain stroked path — no chart dependency, no interpolation flourishes.
private struct TrendLine: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let span = max(maxV - minV, 0.001)
            let stepX = geo.size.width / CGFloat(values.count - 1)
            Path { path in
                for (i, v) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(i) * stepX,
                        y: geo.size.height - CGFloat((v - minV) / span) * geo.size.height
                    )
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }
}

@main
struct TelemetryWidgetBundle: WidgetBundle {
    var body: some Widget {
        TelemetryWidget()
    }
}

struct TelemetryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TelemetryWidget", provider: SnapshotProvider()) { entry in
            TelemetryWidgetView(entry: entry)
        }
        .configurationDisplayName("Telemetry")
        .description("Temperature and fan speed at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
