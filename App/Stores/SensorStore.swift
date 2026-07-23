import Foundation
import Observation
import SwiftUI
import TelemetryShared

/// Single source of truth for live telemetry.
///
/// `@Observable` rather than `ObservableObject`: views invalidate only on the
/// properties they actually read, which matters when a snapshot lands every
/// second and most views care about one number in it.
@MainActor
@Observable
final class SensorStore {
    private(set) var snapshot: SensorSnapshot = .empty
    private(set) var isConnected = false

    /// Long-run history behind the dashboard charts.
    let history = HistoryStore()

    /// Display unit for every temperature in the app and widget. Persisted.
    var unit: TemperatureUnit = TemperatureUnit(
        rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? ""
    ) ?? .celsius {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: "temperatureUnit") }
    }

    /// Which sensor drives the menu bar label and hero readout. Persisted.
    var primarySensor: SensorID = SensorStore.loadPrimarySensor() {
        didSet {
            if let data = try? JSONEncoder().encode(primarySensor) {
                UserDefaults.standard.set(data, forKey: "primarySensor")
            }
        }
    }

    private static func loadPrimarySensor() -> SensorID {
        guard let data = UserDefaults.standard.data(forKey: "primarySensor"),
              let decoded = try? JSONDecoder().decode(SensorID.self, from: data) else {
            return VirtualSensors.cpuHottest
        }
        return decoded
    }

    /// Short rolling history for the popover sparkline. Bounded — an unbounded
    /// array behind a live chart is the classic way to make SwiftUI crawl.
    private(set) var recentPrimary: [Double] = []
    private let historyLimit = 120

    private var engine: SensorEngine?

    func start() {
        guard engine == nil else { return }
        let engine = SensorEngine { [weak self] snapshot in
            self?.apply(snapshot)
        }
        self.engine = engine
        engine.start()
    }

    func setCadence(_ cadence: SensorEngine.Cadence) {
        engine?.setCadence(cadence)
    }

    private func apply(_ snapshot: SensorSnapshot) {
        self.snapshot = snapshot
        isConnected = !snapshot.readings.isEmpty || !snapshot.fans.isEmpty

        let primary = snapshot.reading(primarySensor)?.celsius ?? snapshot.hottest?.celsius
        if let value = primary {
            recentPrimary.append(value)
            if recentPrimary.count > historyLimit {
                recentPrimary.removeFirst(recentPrimary.count - historyLimit)
            }
        }
        history.append(
            primaryTemp: primary,
            fanRPM: snapshot.fans.first?.actualRPM,
            at: snapshot.timestamp
        )
        widgetWriter.observe(
            primaryName: primaryReading?.name,
            primaryTempC: primary,
            fanRPM: snapshot.fans.first?.actualRPM,
            fanMode: snapshot.fans.first?.modeDescription,
            unit: unit
        )
    }

    private let widgetWriter = WidgetSnapshotWriter()

    // MARK: - Derived values for the UI

    var primaryReading: SensorReading? {
        snapshot.reading(primarySensor) ?? snapshot.hottest
    }

    var primaryTemperature: Double? { primaryReading?.celsius }

    var thermalState: ThermalState {
        ThermalState(celsius: primaryTemperature ?? 0)
    }

    var fan: FanReading? { snapshot.fans.first }

    /// Physical sensors only, hottest first — virtual aggregates are shown
    /// separately so the list is not double-counting.
    var physicalReadings: [SensorReading] {
        snapshot.readings
            .filter { if case .virtual = $0.id { return false } else { return true } }
            .sorted { $0.celsius > $1.celsius }
    }

    var virtualReadings: [SensorReading] {
        snapshot.readings.filter { if case .virtual = $0.id { return true } else { return false } }
    }

    /// Compact menu bar text, e.g. `61° 2.4k`. Fan RPM is abbreviated so the
    /// label width stays stable as values change; the unit letter is omitted
    /// to keep the label narrow (the popover states it).
    var menuBarText: String {
        guard let temp = primaryTemperature else { return "—" }
        let tempPart = "\(Int(unit.convert(temp).rounded()))°"
        guard let fan, fan.actualRPM > 0 else { return tempPart }
        let rpm = fan.actualRPM
        let rpmPart = rpm >= 1000
            ? String(format: "%.1fk", rpm / 1000)
            : String(format: "%.0f", rpm)
        return "\(tempPart) \(rpmPart)"
    }
}
