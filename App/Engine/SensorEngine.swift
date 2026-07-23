import Foundation
import HIDSensors
import SMCKit
import TelemetryShared

/// Polls the hardware on a background queue and publishes immutable snapshots
/// to the UI.
///
/// Energy discipline (a thermal monitor that heats the machine is
/// self-defeating): every timer carries leeway so macOS can coalesce wakeups,
/// all IOKit work happens off the main thread, and the cadence adapts to
/// whether anything is actually on screen.
final class SensorEngine {
    enum Cadence {
        /// Popover or dashboard visible.
        case active
        /// Only the menu bar label is live.
        case background

        var interval: TimeInterval {
            switch self {
            case .active: return 1.0
            case .background: return 5.0
            }
        }
    }

    private let queue = DispatchQueue(label: "com.jamesbailey.telemetry.sensors", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var smc: SMCClient?
    private var fanControl: FanControl?
    private var hid: HIDSensorReader?
    private var cadence: Cadence = .background

    /// Called on the main actor with each new snapshot.
    private let onSnapshot: @MainActor (SensorSnapshot) -> Void

    init(onSnapshot: @escaping @MainActor (SensorSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if smc == nil {
                smc = try? SMCClient()
                if let smc { fanControl = FanControl(smc: smc) }
                hid = HIDSensorReader()
            }
            scheduleTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func setCadence(_ new: Cadence) {
        queue.async { [weak self] in
            guard let self, cadence.interval != new.interval else { return }
            cadence = new
            if timer != nil { scheduleTimer() }
        }
    }

    /// Must be called on `queue`.
    private func scheduleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = cadence.interval
        t.schedule(
            deadline: .now(),
            repeating: interval,
            // ~10% leeway lets the system batch our wakeups with others.
            leeway: .milliseconds(Int(interval * 100))
        )
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    /// Must be called on `queue`.
    private func sample() {
        var readings: [SensorReading] = []

        // HID route: unprivileged, and gives far better names than raw SMC keys
        // ("PMU tdie1", "pACC MTR Temp Sensor3" vs "Tp2a").
        if let hid {
            var seen: [String: Int] = [:]
            for r in hid.readAll() where r.isLiveTemperature {
                let ordinal = seen[r.name, default: 0]
                seen[r.name] = ordinal + 1
                readings.append(
                    SensorReading(
                        id: .hid(name: r.name, ordinal: ordinal),
                        name: ordinal == 0 ? r.name : "\(r.name) #\(ordinal + 1)",
                        celsius: r.celsius
                    )
                )
            }
        }

        var fans: [FanReading] = []
        if let fanControl, let telemetry = try? fanControl.allFans() {
            fans = telemetry.map {
                FanReading(
                    id: $0.id,
                    actualRPM: Double($0.actualRPM),
                    targetRPM: Double($0.targetRPM),
                    minRPM: Double($0.minRPM),
                    maxRPM: Double($0.maxRPM),
                    modeRaw: $0.modeRaw
                )
            }
        }

        readings.append(contentsOf: VirtualSensors.derive(from: readings))

        let snapshot = SensorSnapshot(timestamp: Date(), readings: readings, fans: fans)
        Task { @MainActor [onSnapshot] in onSnapshot(snapshot) }
    }
}
