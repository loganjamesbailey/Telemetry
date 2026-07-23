import Foundation

/// Stable identity for a sensor across polls. HID product names are not unique
/// on real hardware (MacBookPro17,1 reports six sensors all called "gas gauge
/// battery"), so the ordinal disambiguates them.
public enum SensorID: Hashable, Sendable, Codable {
    case smc(String)
    case hid(name: String, ordinal: Int)
    case virtual(String)

    public var displayKey: String {
        switch self {
        case .smc(let key): return key
        case .hid(let name, _): return name
        case .virtual(let name): return name
        }
    }
}

public struct SensorReading: Identifiable, Sendable, Hashable {
    public let id: SensorID
    public let name: String
    public let celsius: Double

    public init(id: SensorID, name: String, celsius: Double) {
        self.id = id
        self.name = name
        self.celsius = celsius
    }
}

public struct FanReading: Sendable, Hashable, Identifiable {
    public let id: Int
    public let actualRPM: Double
    public let targetRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    public let modeRaw: UInt8?

    public init(
        id: Int, actualRPM: Double, targetRPM: Double,
        minRPM: Double, maxRPM: Double, modeRaw: UInt8?
    ) {
        self.id = id
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.modeRaw = modeRaw
    }

    /// True when macOS owns the fan (mode 0 automatic or 3 system). Only mode 1
    /// means this app — or another one — is holding it.
    public var isUnderSystemControl: Bool {
        guard let modeRaw else { return true }
        return modeRaw != 1
    }

    public var modeDescription: String {
        switch modeRaw {
        case 0: return "AUTO"
        case 1: return "FORCED"
        case 3: return "SYSTEM"
        default: return "—"
        }
    }
}

/// One immutable sample of everything, handed from the polling queue to the UI.
public struct SensorSnapshot: Sendable {
    public let timestamp: Date
    public let readings: [SensorReading]
    public let fans: [FanReading]

    public init(timestamp: Date, readings: [SensorReading], fans: [FanReading]) {
        self.timestamp = timestamp
        self.readings = readings
        self.fans = fans
    }

    public static let empty = SensorSnapshot(timestamp: .distantPast, readings: [], fans: [])

    public func reading(_ id: SensorID) -> SensorReading? {
        readings.first { $0.id == id }
    }

    public var hottest: SensorReading? {
        readings.max { $0.celsius < $1.celsius }
    }
}
