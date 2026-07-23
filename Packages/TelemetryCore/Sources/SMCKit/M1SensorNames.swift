import Foundation

/// Human-readable overlay for known M1-generation SMC temperature keys.
/// Sources: exelban/stats values.swift, narugit/smctemp smctemp.h,
/// acidanthera VirtualSMC docs (see docs/research/research-smc.md).
/// Keys absent from this table still surface with their raw four-char code —
/// discovery is dynamic, the table is cosmetic.
public enum M1SensorNames {
    public static let table: [String: String] = [
        // Performance cores
        "Tp01": "CPU P-core 1", "Tp05": "CPU P-core 2",
        "Tp0D": "CPU P-core 3", "Tp0H": "CPU P-core 4",
        "Tp0L": "CPU P-core 5", "Tp0P": "CPU P-core 6",
        "Tp0X": "CPU P-core 7", "Tp0b": "CPU P-core 8",
        // Efficiency cores
        "Tp09": "CPU E-core 1", "Tp0T": "CPU E-core 2",
        // GPU
        "Tg05": "GPU 1", "Tg0D": "GPU 2", "Tg0L": "GPU 3", "Tg0T": "GPU 4",
        "Tg1b": "GPU 5", "Tg4b": "GPU 6",
        // Memory
        "Tm02": "Memory 1", "Tm06": "Memory 2", "Tm08": "Memory 3", "Tm09": "Memory 4",
        // Aux CPU die
        "Tc0a": "CPU die aux 1", "Tc0b": "CPU die aux 2",
        "Tc0x": "CPU die aux 3", "Tc0z": "CPU die aux 4",
        // Other
        "TB1T": "Battery", "TW0P": "Airport", "Ts0P": "Palm rest",
    ]

    public static func name(for key: String) -> String {
        table[key] ?? key
    }
}
