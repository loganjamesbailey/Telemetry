import Foundation
import Observation
import TelemetryShared

/// Named fan-curve presets, persisted as plain JSON in Application Support.
/// Unlimited and free — this is exactly the feature Macs Fan Control paywalls.
@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [FanCurve] = []
    var activePresetID: UUID? {
        didSet { UserDefaults.standard.set(activePresetID?.uuidString, forKey: "activePresetID") }
    }

    var activePreset: FanCurve? {
        presets.first { $0.id == activePresetID } ?? presets.first
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    init() {
        load()
        if presets.isEmpty {
            presets = Self.defaultPresets
            save()
        }
        if let saved = UserDefaults.standard.string(forKey: "activePresetID"),
           let id = UUID(uuidString: saved),
           presets.contains(where: { $0.id == id }) {
            activePresetID = id
        } else {
            activePresetID = presets.first?.id
        }
    }

    // MARK: - CRUD

    func update(_ curve: FanCurve) {
        guard let index = presets.firstIndex(where: { $0.id == curve.id }) else { return }
        presets[index] = curve
        save()
    }

    func add(basedOn template: FanCurve? = nil) -> FanCurve {
        var curve = template ?? Self.defaultPresets[0]
        curve.id = UUID()
        curve.name = template.map { "\($0.name) copy" } ?? "New curve"
        presets.append(curve)
        save()
        return curve
    }

    func delete(_ id: UUID) {
        // Never delete the last preset; the curve mode needs one to exist.
        guard presets.count > 1 else { return }
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = presets.first?.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FanCurve].self, from: data) else { return }
        presets = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Defaults

    /// Shipped starting points. All drive CPU Hottest; RPM values sit inside
    /// this machine's real 1199–7199 envelope but are sanitized against the
    /// live fan range before use.
    static let defaultPresets: [FanCurve] = [
        FanCurve(
            name: "Quiet",
            input: SensorID.virtual("CPU Hottest"),
            points: [
                CurvePoint(tempC: 65, rpm: 1199),
                CurvePoint(tempC: 80, rpm: 2400),
                CurvePoint(tempC: 92, rpm: 4800),
                CurvePoint(tempC: 100, rpm: 7199),
            ],
            hysteresisC: 4,
            minDwellSeconds: 12,
            hybridAuto: HybridAutoConfig(releaseBelowC: 60, reacquireAboveC: 68)
        ),
        FanCurve(
            name: "Balanced",
            input: SensorID.virtual("CPU Hottest"),
            points: [
                CurvePoint(tempC: 55, rpm: 1199),
                CurvePoint(tempC: 70, rpm: 2600),
                CurvePoint(tempC: 85, rpm: 4600),
                CurvePoint(tempC: 95, rpm: 7199),
            ],
            hybridAuto: HybridAutoConfig(releaseBelowC: 50, reacquireAboveC: 58)
        ),
        FanCurve(
            name: "Cool",
            input: SensorID.virtual("CPU Hottest"),
            points: [
                CurvePoint(tempC: 45, rpm: 1800),
                CurvePoint(tempC: 60, rpm: 3400),
                CurvePoint(tempC: 75, rpm: 5200),
                CurvePoint(tempC: 88, rpm: 7199),
            ],
            hysteresisC: 2,
            minDwellSeconds: 6
        ),
    ]
}
