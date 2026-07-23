import ServiceManagement
import SwiftUI
import TelemetryShared

/// Preferences live here as a dashboard tab — deliberately NOT a SwiftUI
/// Settings scene, whose opening mechanisms are broken on macOS 26.
struct SettingsTab: View {
    @Environment(SensorStore.self) private var store
    @Environment(FanControlStore.self) private var control

    /// Never cached: users can toggle login items in System Settings at any
    /// moment, so read the live status every render.
    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space16) {
            generalCard
            helperCard
            aboutCard
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    // MARK: - General

    private var generalCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.space12) {
                FieldLabel(text: "General")

                Toggle(isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Keeps the menu bar readout alive after restarts.")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if let error = launchAtLoginError {
                    Text(error).font(Typo.caption).foregroundStyle(Palette.warn)
                }

                Hairline()

                HStack(spacing: Metrics.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu bar sensor")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Drives the menu bar label and hero readout.")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    sensorPicker
                }
            }
        }
    }

    private var sensorPicker: some View {
        @Bindable var store = store
        return Picker("", selection: $store.primarySensor) {
            Section("Derived") {
                ForEach(store.virtualReadings) { reading in
                    Text(reading.name).tag(reading.id)
                }
            }
            Section("Sensors") {
                ForEach(store.physicalReadings.prefix(24)) { reading in
                    Text(reading.name).tag(reading.id)
                }
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 220)
    }

    // MARK: - Helper

    private var helperCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.space12) {
                FieldLabel(text: "Fan control helper")

                HStack(spacing: Metrics.space8) {
                    Circle()
                        .fill(control.isReady ? Palette.nominal : Palette.warn)
                        .frame(width: 6, height: 6)
                    Text(helperStatusText)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }

                Text("A ~100 KB root daemon that writes fan targets. It restores macOS control on its own if this app crashes, sleeps, or stops responding — and you can remove it any time.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Metrics.space16) {
                    switch control.readiness {
                    case .ready:
                        Button("Uninstall helper") { uninstallHelper() }
                            .buttonStyle(.plain).font(Typo.body)
                            .foregroundStyle(Palette.critical)
                    case .awaitingApproval:
                        Button("Open System Settings") { HelperInstaller.openLoginItemsSettings() }
                            .buttonStyle(.plain).font(Typo.body)
                            .foregroundStyle(Palette.accentData)
                    default:
                        Button("Install helper…") { control.installHelper() }
                            .buttonStyle(.plain).font(Typo.body)
                            .foregroundStyle(Palette.accentData)
                    }
                }
            }
        }
    }

    private var helperStatusText: String {
        switch control.readiness {
        case .ready(let version): return "Enabled · v\(version)"
        case .awaitingApproval: return "Waiting for approval in Login Items & Extensions"
        case .notInstalled: return "Not installed — monitoring only"
        case .unknown: return "Checking…"
        case .failed(let why): return why
        }
    }

    private func uninstallHelper() {
        // Fans back to macOS first, then remove the registration.
        control.apply(.systemAuto, maxRPM: store.fan?.maxRPM ?? 7199)
        HelperInstaller.unregister()
        control.refreshReadiness()
    }

    // MARK: - About

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.space8) {
                FieldLabel(text: "About")
                HStack(alignment: .firstTextBaseline, spacing: Metrics.space8) {
                    Text("Telemetry")
                        .font(Typo.headline)
                        .foregroundStyle(Palette.textPrimary)
                    Text(verbatim: appVersion)
                        .font(Typo.readoutSmall)
                        .foregroundStyle(Palette.textTertiary)
                }
                Text("Free, open-source fan control and thermal monitoring for Apple Silicon Macs. MIT licensed.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(short)"
    }
}
