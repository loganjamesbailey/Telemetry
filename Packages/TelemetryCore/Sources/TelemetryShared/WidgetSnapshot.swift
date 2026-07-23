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

    public init(
        timestamp: Date, primaryName: String, primaryTempC: Double,
        fanRPM: Double, fanModeDescription: String, tempTrend: [Double]
    ) {
        self.timestamp = timestamp
        self.primaryName = primaryName
        self.primaryTempC = primaryTempC
        self.fanRPM = fanRPM
        self.fanModeDescription = fanModeDescription
        self.tempTrend = tempTrend
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
