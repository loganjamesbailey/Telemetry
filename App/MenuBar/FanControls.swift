import SwiftUI
import TelemetryShared

/// The control strip inside the popover's fan section: Auto / Set / Max, a
/// slider when in Set, and the helper install flow when control is not yet
/// available. Until the helper is enabled the app is a fully functional
/// monitor — controls are visibly locked, never broken.
struct FanControls: View {
    @Environment(SensorStore.self) private var sensors
    @Environment(FanControlStore.self) private var control
    @Environment(PresetStore.self) private var presets

    private enum Segment: String, CaseIterable {
        case auto = "AUTO"
        case curve = "CURVE"
        case set = "SET"
        case max = "MAX"
    }

    @State private var segment: Segment = .auto
    @State private var sliderRPM: Double = 3000

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            switch control.readiness {
            case .ready:
                controls
            case .notInstalled, .unknown:
                setupRow(
                    message: "Fan control needs a one-time helper install.",
                    button: "Install helper…"
                ) { control.installHelper() }
            case .awaitingApproval:
                setupRow(
                    message: "Approve Telemetry in Login Items & Extensions.",
                    button: "Open System Settings"
                ) { HelperInstaller.openLoginItemsSettings() }
            case .failed(let why):
                setupRow(message: why, button: "Retry") { control.refreshReadiness() }
            }

            if let note = control.lastResult {
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warn)
                    .lineLimit(2)
            }
        }
        .onAppear { syncFromStore() }
        .onChange(of: control.mode) { syncFromStore() }
    }

    // MARK: - Ready state

    private var controls: some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: segment) { _, new in applySegment(new) }

            if segment == .set, let fan = sensors.fan {
                HStack(spacing: Metrics.space8) {
                    Slider(
                        value: $sliderRPM,
                        in: fan.minRPM...fan.maxRPM,
                        step: 100
                    ) { editing in
                        // Apply on release, not per-tick — every target change
                        // is a root round-trip and an SMC write.
                        if !editing { control.apply(.constant(sliderRPM), maxRPM: fan.maxRPM) }
                    }
                    .controlSize(.small)
                    Text(verbatim: "\(Int(sliderRPM))")
                        .font(Typo.readoutSmall)
                        .foregroundStyle(Palette.accentControl)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            if segment == .curve {
                curveRow
            }
        }
    }

    /// Preset picker + live activity line. Curve editing lives in the
    /// dashboard; the popover only chooses and reports.
    private var curveRow: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            HStack(spacing: Metrics.space8) {
                Menu {
                    ForEach(presets.presets) { preset in
                        Button(preset.name) {
                            presets.activePresetID = preset.id
                            applySegment(.curve)
                        }
                    }
                } label: {
                    Text(presets.activePreset?.name ?? "No preset")
                        .font(Typo.body)
                        .foregroundStyle(Palette.accentControl)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if let activity = control.curveActivity {
                    Text(activity)
                        .font(Typo.caption)
                        .foregroundStyle(
                            control.hybridReleased ? Palette.nominal : Palette.textTertiary
                        )
                }
            }
        }
    }

    private func applySegment(_ new: Segment) {
        guard let fan = sensors.fan else { return }
        switch new {
        case .auto:
            control.apply(.systemAuto, maxRPM: fan.maxRPM)
        case .curve:
            guard let preset = presets.activePreset else { return }
            control.apply(.curve(preset), maxRPM: fan.maxRPM)
        case .set:
            control.apply(.constant(sliderRPM), maxRPM: fan.maxRPM)
        case .max:
            control.apply(.max, maxRPM: fan.maxRPM)
        }
    }

    private func syncFromStore() {
        switch control.mode {
        case .systemAuto: segment = .auto
        case .constant(let rpm):
            segment = .set
            sliderRPM = rpm
        case .curve: segment = .curve
        case .max: segment = .max
        }
    }

    // MARK: - Setup state

    private func setupRow(
        message: String, button: String, action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space8) {
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.accentData)
        }
    }
}
