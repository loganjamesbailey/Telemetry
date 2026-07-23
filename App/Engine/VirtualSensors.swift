import Foundation
import TelemetryShared

/// Composite sensors derived from physical ones.
///
/// These exist because binding a fan curve to one physical sensor is exactly
/// the limitation users complain about in Macs Fan Control: on this machine the
/// hottest P-core moves between `pACC MTR Temp Sensor2/3/4/8` from second to
/// second, so tracking any single one of them under-reports the real peak.
enum VirtualSensors {
    static let cpuHottest = SensorID.virtual("CPU Hottest")
    static let socAverage = SensorID.virtual("SOC Average")
    static let systemHottest = SensorID.virtual("System Hottest")

    static func derive(from readings: [SensorReading]) -> [SensorReading] {
        var out: [SensorReading] = []

        let cpu = readings.filter {
            let n = $0.name
            return n.hasPrefix("pACC") || n.hasPrefix("eACC")
        }
        if let peak = cpu.map(\.celsius).max() {
            out.append(SensorReading(id: cpuHottest, name: "CPU Hottest", celsius: peak))
        }

        let soc = readings.filter { $0.name.hasPrefix("SOC MTR") }
        if !soc.isEmpty {
            let mean = soc.map(\.celsius).reduce(0, +) / Double(soc.count)
            out.append(SensorReading(id: socAverage, name: "SOC Average", celsius: mean))
        }

        if let peak = readings.map(\.celsius).max() {
            out.append(SensorReading(id: systemHottest, name: "System Hottest", celsius: peak))
        }

        return out
    }
}
