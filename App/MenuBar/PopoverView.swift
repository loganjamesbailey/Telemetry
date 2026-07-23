import SwiftUI
import TelemetryShared

/// The quick-glance surface. Fixed width, no scrolling, no chrome — everything
/// here is either a live value or a control.
struct PopoverView: View {
    @Environment(SensorStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            heroSection
            Hairline()
            fanSection
            Hairline()
            sensorSection
            Hairline()
            footer
        }
        .frame(width: Metrics.popoverWidth)
        .background(Palette.bgPanel)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("TELEMETRY")
                .font(Typo.sensorLabel)
                .tracking(1.4)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(store.thermalState.label)
                .font(Typo.sensorLabel)
                .tracking(0.6)
                .foregroundStyle(store.thermalState.color)
        }
        .padding(.horizontal, Metrics.space16)
        .padding(.vertical, Metrics.space12)
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            FieldLabel(text: store.primaryReading?.name ?? "No sensor")

            HStack(alignment: .firstTextBaseline, spacing: Metrics.space4) {
                if let temp = store.primaryTemperature {
                    // The one steady glow in the popover: this is the live value.
                    Readout(
                        value: String(format: "%.1f", temp),
                        unit: "°C",
                        font: Typo.heroReadout,
                        color: Palette.accentData,
                        glow: GlowLevel.steady
                    )
                } else {
                    Text("—")
                        .font(Typo.heroReadout)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            if store.recentPrimary.count > 1 {
                Sparkline(
                    values: store.recentPrimary,
                    color: Palette.accentData,
                    glow: GlowLevel.steady
                )
                .frame(height: 28)
            }
        }
        .padding(Metrics.space16)
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            HStack {
                FieldLabel(text: "Fan")
                Spacer()
                Text(store.fan?.modeDescription ?? "—")
                    .font(Typo.sensorLabel)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textTertiary)
            }

            if let fan = store.fan {
                HStack(alignment: .firstTextBaseline) {
                    Readout(
                        value: fan.actualRPM > 0 ? String(format: "%.0f", fan.actualRPM) : "0",
                        unit: "RPM",
                        color: Palette.accentControl
                    )
                    Spacer()
                    if fan.actualRPM == 0 {
                        // Worth stating plainly: 0 RPM under macOS control is
                        // the quietest the machine can be, and it is unreachable
                        // while holding a manual target.
                        Text("idle · silent")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    } else {
                        // verbatim: SwiftUI treats interpolated Text as a
                        // LocalizedStringKey and would render "1,199–7,199".
                        Text(verbatim: "\(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                            .font(Typo.axisLabel)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }

                fanBar(fan)
                FanControls()
                    .padding(.top, Metrics.space4)
            } else {
                Text("No fan detected")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Metrics.space16)
    }

    private func fanBar(_ fan: FanReading) -> some View {
        GeometryReader { geo in
            let span = max(fan.maxRPM - fan.minRPM, 1)
            let fraction = fan.actualRPM <= 0
                ? 0
                : min(max((fan.actualRPM - fan.minRPM) / span, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule()
                    .fill(Palette.accentControl)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            FieldLabel(text: "Hottest sensors")
            ForEach(store.physicalReadings.prefix(5)) { reading in
                SensorRow(name: reading.name, celsius: reading.celsius)
            }
            if store.physicalReadings.isEmpty {
                Text("Reading sensors…")
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Metrics.space16)
    }

    private var footer: some View {
        HStack(spacing: Metrics.space16) {
            Button("Dashboard") { openWindow(id: DashboardWindow.id) }
                .buttonStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.accentData)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Metrics.space16)
        .padding(.vertical, Metrics.space12)
    }
}
