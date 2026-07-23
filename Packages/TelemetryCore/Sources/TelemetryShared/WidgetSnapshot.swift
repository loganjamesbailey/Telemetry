import Foundation
import Security

/// What the app hands the widget, as a JSON file in the app-group container.
/// WidgetKit extensions are sandboxed and budgeted — they cannot read the SMC
/// themselves, so the widget renders the app's last snapshot and is honest
/// about its age.
public struct WidgetSnapshot: Codable, Sendable {
    public var timestamp: Date
    public var primaryName: String
    public var primaryTempC: Double
    public var fanRPM: Double
    public var fanModeDescription: String
    /// Last ~30 minutes of the primary temperature, one point per minute.
    public var tempTrend: [Double]
    /// Display unit chosen in the app; temperatures above remain Celsius.
    public var unit: TemperatureUnit

    public init(
        timestamp: Date, primaryName: String, primaryTempC: Double,
        fanRPM: Double, fanModeDescription: String, tempTrend: [Double],
        unit: TemperatureUnit = .celsius
    ) {
        self.timestamp = timestamp
        self.primaryName = primaryName
        self.primaryTempC = primaryTempC
        self.fanRPM = fanRPM
        self.fanModeDescription = fanModeDescription
        self.tempTrend = tempTrend
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, primaryName, primaryTempC, fanRPM, fanModeDescription, tempTrend, unit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        primaryName = try c.decode(String.self, forKey: .primaryName)
        primaryTempC = try c.decode(Double.self, forKey: .primaryTempC)
        fanRPM = try c.decode(Double.self, forKey: .fanRPM)
        fanModeDescription = try c.decode(String.self, forKey: .fanModeDescription)
        tempTrend = try c.decode([Double].self, forKey: .tempTrend)
        // Tolerate snapshots written before the unit field existed.
        unit = try c.decodeIfPresent(TemperatureUnit.self, forKey: .unit) ?? .celsius
    }

    /// Snapshots older than this render dimmed with an "app not running" hint.
    public static let staleAfter: TimeInterval = 30 * 60
}

public enum WidgetSnapshotFile {
    /// The app-group id is `<TeamID>.com.jamesbailey.telemetry`. The team is
    /// read from this process's own code signature rather than hard-coded, so
    /// build-from-source users' groups resolve to their own team without
    /// editing anything.
    public static func containerURL() -> URL? {
        guard let team = currentTeamIdentifier() else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "\(team).com.jamesbailey.telemetry"
        )
    }

    public static func fileURL() -> URL? {
        containerURL()?.appendingPathComponent("snapshot.json")
    }

    public static func write(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func read() -> WidgetSnapshot? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
