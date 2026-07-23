import CHIDShim
import CoreFoundation
import Foundation

public struct HIDSensorReading: Sendable {
    public let name: String
    public let celsius: Double

    /// True for sensors that report a live die/block temperature, as opposed to
    /// calibration or reference values.
    ///
    /// `PMU tcal` / `PMU2 tcal` sit at a fixed 51.9 °C on MacBookPro17,1 and
    /// never move under load — taking a naive max() across all sensors picks
    /// them and reports a machine as permanently 52 °C. Anything driving a fan
    /// curve or a "hottest sensor" readout must exclude them.
    public var isLiveTemperature: Bool {
        let lowered = name.lowercased()
        if lowered.contains("tcal") { return false }
        if lowered.contains("gas gauge") { return false }  // battery pack, not silicon
        return true
    }
}

/// Reads Apple Silicon temperature sensors via the private
/// IOHIDEventSystemClient route (usage page 0xff00, usage 5). Unprivileged,
/// and yields far better sensor names than raw SMC keys ("PMU tdie", "SOC MTR
/// Temp Sensor2", "NAND CH0 temp", ...).
public final class HIDSensorReader {
    private let client: IOHIDEventSystemClient

    public init?() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let matching: [String: Int] = [
            "PrimaryUsagePage": Int(HIDSHIM_USAGE_PAGE_APPLE_VENDOR),
            "PrimaryUsage": Int(HIDSHIM_USAGE_TEMPERATURE_SENSOR),
        ]
        _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        self.client = client
    }

    /// Snapshot of every readable named temperature sensor. Services with no
    /// current event are skipped (IOHIDServiceClientCopyEvent returns NULL for
    /// some matched services); readings outside 0...110 °C are discarded as
    /// garbage, matching what Stats ships.
    public func readAll() -> [HIDSensorReading] {
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return [] }

        var readings: [HIDSensorReading] = []
        let count = CFArrayGetCount(services)
        readings.reserveCapacity(count)

        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = unsafeBitCast(ptr, to: IOHIDServiceClient.self)

            guard let event = IOHIDServiceClientCopyEvent(
                service, Int64(HIDSHIM_EVENT_TYPE_TEMPERATURE), 0, 0
            ) else { continue }

            let value = IOHIDEventGetFloatValue(
                event, Int32(HIDSHIM_EVENT_TYPE_TEMPERATURE) << 16
            )
            guard value > 0, value < 110 else { continue }

            let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String)
                ?? "Unknown sensor \(i)"
            readings.append(HIDSensorReading(name: name, celsius: value))
        }
        return readings.sorted { $0.name < $1.name }
    }
}
