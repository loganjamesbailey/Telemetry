import Foundation

/// Display unit for temperatures. Everything internal — SMC readings, curve
/// points, thresholds, the wire format — stays Celsius; conversion happens
/// only at the moment of display or user input.
public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius
    case fahrenheit

    public var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Absolute temperature conversion.
    public func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    public func inverse(_ display: Double) -> Double {
        self == .celsius ? display : (display - 32) * 5 / 9
    }

    /// Interval conversion (hysteresis, gaps): scale only, no +32 offset.
    public func convertDelta(_ celsiusDelta: Double) -> Double {
        self == .celsius ? celsiusDelta : celsiusDelta * 9 / 5
    }

    public func inverseDelta(_ displayDelta: Double) -> Double {
        self == .celsius ? displayDelta : displayDelta * 5 / 9
    }

    public func format(_ celsius: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f", convert(celsius))
    }
}
