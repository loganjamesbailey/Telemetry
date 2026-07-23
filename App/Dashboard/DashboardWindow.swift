import SwiftUI
import TelemetryShared

/// The full view. Deliberately a plain Window scene, not a Settings scene:
/// `openSettings` is broken on macOS 26 and the workarounds are timing- and
/// scene-order-sensitive, so preferences live here as a tab instead.
struct DashboardWindow: View {
    static let id = "dashboard"

    @Environment(SensorStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space24) {
                overview
                sensorGrid
            }
            .padding(Metrics.space24)
        }
        .background(Palette.bgBase)
        .frame(minWidth: 640, minHeight: 480)
    }

    private var overview: some View {
        HStack(alignment: .top, spacing: Metrics.space16) {
            Card {
                VStack(alignment: .leading, spacing: Metrics.space8) {
                    FieldLabel(text: store.primaryReading?.name ?? "No sensor")
                    if let temp = store.primaryTemperature {
                        Readout(
                            value: String(format: "%.1f", temp),
                            unit: "°C",
                            font: Typo.heroReadout,
                            color: Palette.accentData,
                            glow: GlowLevel.steady
                        )
                    }
                    Text(store.thermalState.label)
                        .font(Typo.sensorLabel)
                        .tracking(0.6)
                        .foregroundStyle(store.thermalState.color)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Metrics.space8) {
                    FieldLabel(text: "Fan")
                    if let fan = store.fan {
                        Readout(
                            value: String(format: "%.0f", fan.actualRPM),
                            unit: "RPM",
                            font: Typo.heroReadout,
                            color: Palette.accentControl,
                            glow: GlowLevel.steady
                        )
                        Text(fan.modeDescription)
                            .font(Typo.sensorLabel)
                            .tracking(0.6)
                            .foregroundStyle(Palette.textTertiary)
                    } else {
                        Text("—").font(Typo.heroReadout).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }

    private var sensorGrid: some View {
        VStack(alignment: .leading, spacing: Metrics.space24) {
            // Derived sensors are listed separately so the physical count stays
            // honest and aggregates are not mistaken for hardware readings.
            VStack(alignment: .leading, spacing: Metrics.space12) {
                FieldLabel(text: "Derived")
                grid(store.virtualReadings, uppercase: true)
            }
            VStack(alignment: .leading, spacing: Metrics.space12) {
                FieldLabel(text: "Sensors · \(store.physicalReadings.count)")
                grid(store.physicalReadings, uppercase: false)
            }
        }
    }

    private func grid(_ readings: [SensorReading], uppercase: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: Metrics.space12)],
            alignment: .leading,
            spacing: Metrics.space8
        ) {
            ForEach(readings) { reading in
                SensorRow(
                    name: uppercase ? reading.name.uppercased() : reading.name,
                    celsius: reading.celsius
                )
            }
        }
    }
}
