import Foundation
import TelemetryShared
import WidgetKit

/// Feeds the widget: writes the snapshot file on a slow cadence and asks
/// WidgetKit to reload on a slower one, plus immediately when something the
/// user would notice changes (thermal band, fan mode). Respects the WidgetKit
/// refresh budget — hammering reloadTimelines gets throttled into uselessness.
@MainActor
final class WidgetSnapshotWriter {
    private var lastWrite: Date = .distantPast
    private var lastReload: Date = .distantPast
    private var lastBand: ThermalState?
    private var lastMode: String?

    /// One temperature point per minute for the widget's 30-minute trend.
    private var trend: [Double] = []
    private var lastTrendAppend: Date = .distantPast

    private let writeEvery: TimeInterval = 30
    private let reloadEvery: TimeInterval = 5 * 60

    func observe(
        primaryName: String?, primaryTempC: Double?,
        fanRPM: Double?, fanMode: String?, unit: TemperatureUnit
    ) {
        guard let primaryTempC else { return }
        let now = Date()

        if now.timeIntervalSince(lastTrendAppend) >= 60 {
            trend.append(primaryTempC)
            if trend.count > 30 { trend.removeFirst(trend.count - 30) }
            lastTrendAppend = now
        }

        let band = ThermalState(celsius: primaryTempC)
        let bandChanged = lastBand != nil && band != lastBand
        let modeChanged = lastMode != nil && fanMode != lastMode
        lastBand = band
        lastMode = fanMode

        guard bandChanged || modeChanged || now.timeIntervalSince(lastWrite) >= writeEvery else {
            return
        }
        lastWrite = now
        WidgetSnapshotFile.write(WidgetSnapshot(
            timestamp: now,
            primaryName: primaryName ?? "—",
            primaryTempC: primaryTempC,
            fanRPM: fanRPM ?? 0,
            fanModeDescription: fanMode ?? "—",
            tempTrend: trend,
            unit: unit
        ))

        if bandChanged || modeChanged || now.timeIntervalSince(lastReload) >= reloadEvery {
            lastReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: "TelemetryWidget")
        }
    }
}
