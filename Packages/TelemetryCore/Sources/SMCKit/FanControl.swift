import Foundation

public enum FanMode: UInt8, CustomStringConvertible {
    case automatic = 0
    case forced = 1
    case system = 3  // thermalmonitord's hold on newer chips

    public var description: String {
        switch self {
        case .automatic: return "automatic"
        case .forced: return "forced"
        case .system: return "system"
        }
    }
}

public struct FanTelemetry {
    public let id: Int
    public let actualRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let targetRPM: Float
    public let modeRaw: UInt8?

    public var mode: FanMode? { modeRaw.flatMap(FanMode.init(rawValue:)) }
}

/// Fan telemetry and control over SMC keys. Shared verbatim by the smcspike
/// CLI and the root helper daemon so the exact code path proven in the spike
/// ships in the product.
///
/// Write-path facts this encodes. Items marked (measured) were established
/// empirically on MacBookPro17,1 / macOS 26.5 and CONTRADICT the published
/// reference behaviour, which came from a MacBookPro18,1 — see
/// docs/research/research-smc.md and docs/hardware-notes.md.
/// - Fan keys on Apple Silicon are "flt " floats; the mode key is ui8.
/// - The mode key is `F%dMd` on M1-era chips, lowercase `F%dmd` on newer ones —
///   probe at runtime.
/// - (measured) Mode changes apply ASYNCHRONOUSLY, ~150 ms. An immediate
///   read-back reports the old mode, which looks exactly like a hard rejection.
/// - (measured) Writes to `F%dTg` are IGNORED while the fan is in automatic
///   mode — firmware owns the target until control is handed over, so the
///   target cannot be staged before the mode switch.
/// - (measured) There is no `Ftst` key on MacBookPro17,1; the diagnostic-unlock
///   fallback is kept for machines that do have it.
/// - Firmware does NOT clamp targets — callers must respect [minRPM, maxRPM].
/// - Nothing survives reboot; sleep also drops forced state.
public final class FanControl {
    private let smc: SMCClient
    private var cachedModeKeys: [Int: String] = [:]

    /// The SMC applies fan-mode changes asynchronously — an immediate read-back
    /// still reports the old mode. Measured at ~150 ms on MacBookPro17,1;
    /// 250 ms gives margin without making control feel sluggish.
    public var modeSettleMicroseconds: UInt32 = 250_000
    /// How many times to re-assert a mode+target pair before giving up.
    public var applyAttempts = 6

    public init(smc: SMCClient) {
        self.smc = smc
    }

    // MARK: - Telemetry (unprivileged)

    public func fanCount() throws -> Int {
        Int(try smc.readUInt("FNum"))
    }

    public func telemetry(fan id: Int) throws -> FanTelemetry {
        FanTelemetry(
            id: id,
            actualRPM: try smc.readFloat("F\(id)Ac"),
            minRPM: try smc.readFloat("F\(id)Mn"),
            maxRPM: try smc.readFloat("F\(id)Mx"),
            targetRPM: try smc.readFloat("F\(id)Tg"),
            modeRaw: try? UInt8(smc.readUInt(modeKey(fan: id)))
        )
    }

    public func allFans() throws -> [FanTelemetry] {
        try (0..<(try fanCount())).map { try telemetry(fan: $0) }
    }

    /// `F0md` (lowercase) exists on newer chips, `F0Md` on M1 — probe once.
    public func modeKey(fan id: Int) -> String {
        if let cached = cachedModeKeys[id] { return cached }
        let lower = "F\(id)md"
        let upper = "F\(id)Md"
        let key = smc.keyExists(lower) ? lower : upper
        cachedModeKeys[id] = key
        return key
    }

    public func currentMode(fan id: Int) throws -> FanMode? {
        let raw = try smc.readUInt(modeKey(fan: id))
        return FanMode(rawValue: UInt8(truncatingIfNeeded: raw))
    }

    // MARK: - Control (root required)

    /// Puts the fan into forced mode. Tries the direct write first (sufficient
    /// on M1); falls back to the Ftst diagnostic unlock used on newer firmware.
    /// Reports which path succeeded so the spike can document this machine.
    ///
    /// Safety contract: if this throws, it has already undone anything it did.
    /// In particular `Ftst` is never left at 1 on a failure path — that state
    /// means thermalmonitord has yielded but nobody has taken over, and macOS
    /// will not reclaim the fans until sleep or reboot.
    ///
    /// `isCancelled` is polled inside the multi-second unlock waits so a user
    /// interrupt does not have to wait ~38 s (and reach for SIGKILL, which
    /// would strand exactly that state).
    @discardableResult
    public func ensureForcedMode(
        fan id: Int,
        directModeAttempts: Int = 8,
        isCancelled: () -> Bool = { false },
        log: (String) -> Void = { _ in }
    ) throws -> String {
        let key = modeKey(fan: id)
        if let mode = try? currentMode(fan: id), mode == .forced {
            return "already-forced"
        }

        // Preserve the genuine cause rather than reporting a firmware result
        // the firmware never returned.
        var directFailure: Error?

        // The firmware can accept the write (result byte 0x00) and still not
        // apply it, and on some models the mode change lands asynchronously —
        // so retry with a delay before concluding the direct path is unusable.
        for attempt in 0..<directModeAttempts {
            if isCancelled() { throw SMCError.cancelled }
            do {
                try smc.writeUInt8(key, FanMode.forced.rawValue)
                usleep(150_000)
                let readback = try currentMode(fan: id)
                if readback == .forced {
                    return attempt == 0 ? "direct" : "direct (attempt \(attempt + 1))"
                }
                directFailure = SMCError.writeVerifyFailed(key: key)
            } catch SMCError.notPrivileged {
                throw SMCError.notPrivileged
            } catch {
                directFailure = error
            }
        }
        log("direct \(key)=1 did not stick after \(directModeAttempts) attempts; trying Ftst unlock")

        guard smc.keyExists("Ftst") else {
            throw directFailure ?? SMCError.smcResult(SMCResult.badCommand, key: key)
        }
        if isCancelled() { throw SMCError.cancelled }

        // Ftst unlock: write 1, wait for thermalmonitord to yield, retry mode.
        // From here on, every exit that is not a success must relock.
        try smc.writeUInt8("Ftst", 1, attempts: 100)
        var unlockedByUs = false
        defer {
            if !unlockedByUs {
                try? smc.writeUInt8("Ftst", 0, attempts: 100)
                log("unlock failed; Ftst rolled back to 0")
            }
        }

        log("Ftst=1 written; waiting 3 s for thermalmonitord to yield")
        for _ in 0..<30 {
            if isCancelled() { throw SMCError.cancelled }
            usleep(100_000)
        }

        var lastFailure: Error = directFailure ?? SMCError.smcResult(SMCResult.badCommand, key: key)
        for attempt in 0..<300 {
            if isCancelled() { throw SMCError.cancelled }
            do {
                try smc.writeBytes(key, bytes: [FanMode.forced.rawValue])
                if try currentMode(fan: id) == .forced {
                    unlockedByUs = true
                    return "ftst-unlock (attempt \(attempt + 1))"
                }
                lastFailure = SMCError.writeVerifyFailed(key: key)
            } catch SMCError.notPrivileged {
                throw SMCError.notPrivileged  // defer relocks
            } catch {
                lastFailure = error  // transient — keep retrying
            }
            usleep(100_000)
        }
        throw lastFailure  // defer relocks
    }

    /// Modes 0 (automatic) and 3 (system/thermalmonitord) both mean macOS owns
    /// the fan again; only 1 (forced) is a failed handback.
    public func isUnderSystemControl(fan id: Int) -> Bool {
        guard let mode = try? currentMode(fan: id) else { return false }
        return mode == .automatic || mode == .system
    }

    /// Fan ids still stuck in forced mode. Empty means the handback worked.
    public func fansStillForced() -> [Int] {
        let count = (try? fanCount()) ?? 1
        return (0..<count).filter { !isUnderSystemControl(fan: $0) }
    }

    /// Sets a forced RPM target, clamped to the fan's reported [min, max].
    /// Returns the RPM actually applied.
    @discardableResult
    public func setTargetRPM(
        fan id: Int,
        rpm: Double,
        isCancelled: () -> Bool = { false },
        log: (String) -> Void = { _ in }
    ) throws -> (applied: Float, clamped: Bool, unlockPath: String) {
        guard rpm.isFinite else { throw SMCError.invalidKey("non-finite RPM") }
        let t = try telemetry(fan: id)
        // Refuse to act on implausible limits rather than writing a target
        // derived from garbage — the firmware will not second-guess us.
        guard t.minRPM.isFinite, t.maxRPM.isFinite,
              t.minRPM >= 0, t.maxRPM > t.minRPM, t.maxRPM < 20000 else {
            throw SMCError.unexpectedType(
                key: "F\(id)Mn/F\(id)Mx",
                expected: "0 <= min < max < 20000",
                actual: "min \(t.minRPM), max \(t.maxRPM)"
            )
        }
        let applied = Float(min(max(rpm, Double(t.minRPM)), Double(t.maxRPM)))
        let clamped = applied != Float(rpm)

        // Capture the pre-existing target before touching anything: entering
        // forced mode makes the fan obey whatever F0Tg already holds, and
        // restoreAutomatic deliberately leaves it at 0.0 — so a failure between
        // the mode switch and the target write would pin the fan at 0 RPM.
        let priorTarget = try? smc.readFloat("F\(id)Tg")

        var committed = false
        // Declared before the target write so the rollback also covers a
        // failure during the mode transition itself.
        var weTookControl = false
        defer {
            if !committed {
                if weTookControl {
                    // Undo our own transition — fully, including the unlock.
                    try? smc.writeUInt8(modeKey(fan: id), FanMode.automatic.rawValue, attempts: 20)
                    if smc.keyExists("Ftst") {
                        try? smc.writeUInt8("Ftst", 0, attempts: 20)
                    }
                    log("target write failed; released fan \(id) back to automatic")
                } else if let prior = priorTarget {
                    // Someone else owns forced mode; restore only what we clobbered.
                    try? smc.writeFloat("F\(id)Tg", prior, attempts: 20)
                    log("target write failed; restored prior target \(prior) RPM")
                }
            }
        }

        // Apply mode and target as a PAIR, then verify both together.
        //
        // Two firmware behaviours observed on MacBookPro17,1 force this shape:
        //  1. Writes to F0Tg are ignored while the fan is in automatic mode —
        //     the firmware owns the target until control is handed over. So the
        //     target cannot be staged first.
        //  2. The F0Md change applies ASYNCHRONOUSLY. An immediate read-back
        //     still reports automatic; ~200 ms later it reports forced. Trusting
        //     the immediate read-back is what made the first attempt look like a
        //     hard failure.
        //
        // Writing both back-to-back keeps the window in which the fan is forced
        // to a stale target (restoreAutomatic leaves 0.0 = stopped) down to
        // microseconds, and the pair is re-asserted until both verify.
        let modeK = modeKey(fan: id)
        let targetKey = "F\(id)Tg"
        var lastFailure: Error = SMCError.writeVerifyFailed(key: modeK)
        var applyPath = "pair-write"

        for attempt in 0..<applyAttempts {
            if isCancelled() { throw SMCError.cancelled }
            do {
                let alreadyForced = (try? currentMode(fan: id)) == .forced
                if !alreadyForced {
                    try smc.writeUInt8(modeK, FanMode.forced.rawValue, attempts: 2)
                    weTookControl = true
                }
                try smc.writeFloat(targetKey, applied, attempts: 2)
            } catch SMCError.notPrivileged {
                throw SMCError.notPrivileged
            } catch {
                lastFailure = error
            }

            usleep(modeSettleMicroseconds)

            let mode = try? currentMode(fan: id)
            let readback = try? smc.readFloat(targetKey)
            if mode == .forced, let readback, abs(readback - applied) < 1.0 {
                committed = true
                applyPath = attempt == 0 ? "pair-write" : "pair-write (attempt \(attempt + 1))"
                return (applied, clamped, applyPath)
            }
            lastFailure = SMCError.writeVerifyFailed(
                key: mode == .forced ? targetKey : modeK
            )
        }
        throw lastFailure
    }

    /// Hands all fans back to macOS automatic control. Safe to call
    /// repeatedly; must succeed even in degraded states, so it accumulates
    /// errors rather than stopping at the first.
    public func restoreAutomatic(log: (String) -> Void = { _ in }) throws {
        var errors: [Error] = []

        if smc.keyExists("Ftst"), (try? smc.readUInt("Ftst")) == 1 {
            do {
                try smc.writeUInt8("Ftst", 0, attempts: 100)
                log("Ftst=0 written")
            } catch { errors.append(error) }
        }

        let count = (try? fanCount()) ?? 1
        for id in 0..<count {
            let key = modeKey(fan: id)
            // The mode change lands asynchronously, so re-assert and confirm
            // rather than trusting a single write's return value. Reporting a
            // handback that never happened is the worst possible lie here.
            var handedBack = false
            for _ in 0..<applyAttempts {
                do {
                    try smc.writeUInt8(key, FanMode.automatic.rawValue, attempts: 2)
                    try? smc.writeFloat("F\(id)Tg", 0.0, attempts: 2)
                } catch SMCError.notPrivileged {
                    throw SMCError.notPrivileged
                } catch {
                    errors.append(error)
                }
                usleep(modeSettleMicroseconds)
                if isUnderSystemControl(fan: id) {
                    handedBack = true
                    break
                }
            }
            if handedBack {
                log("fan \(id): handed back to macOS (\(key)=0, verified)")
            } else {
                let failure = SMCError.writeVerifyFailed(key: key)
                errors.append(failure)
                log("fan \(id): STILL FORCED after \(applyAttempts) attempts")
            }
        }

        if let first = errors.first { throw first }
    }
}
