import Foundation

/// One point on a fan curve: at `tempC`, run the fan at `rpm`.
public struct CurvePoint: Codable, Hashable, Sendable {
    public var tempC: Double
    public var rpm: Double

    public init(tempC: Double, rpm: Double) {
        self.tempC = tempC
        self.rpm = rpm
    }
}

/// Zero-RPM hybrid mode: below `releaseBelowC` (sustained for
/// `releaseDelaySeconds`) the curve releases the fan back to macOS automatic
/// control — the only way to reach the 0 RPM idle, since forced mode is
/// floored at F0Mn. At `reacquireAboveC` the curve takes control back.
///
/// The gap between the two thresholds is the anti-flap margin; `sanitized`
/// enforces a minimum of 2 °C.
public struct HybridAutoConfig: Codable, Hashable, Sendable {
    public var releaseBelowC: Double
    public var reacquireAboveC: Double
    public var releaseDelaySeconds: Double

    public init(releaseBelowC: Double, reacquireAboveC: Double, releaseDelaySeconds: Double = 30) {
        self.releaseBelowC = releaseBelowC
        self.reacquireAboveC = reacquireAboveC
        self.releaseDelaySeconds = releaseDelaySeconds
    }
}

/// A user-editable fan curve: the product's core feature. Everything here is
/// Codable so presets persist as plain JSON.
public struct FanCurve: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The sensor driving the curve — physical or virtual aggregate.
    public var input: SensorID
    /// 2–8 points, kept sorted by temperature.
    public var points: [CurvePoint]
    /// Temperature must fall this far below the level that set the current
    /// RPM before the curve lowers the fan again (spin-up is never delayed
    /// by hysteresis — heat is the thing we cannot argue with).
    public var hysteresisC: Double
    /// Minimum seconds between RPM decreases.
    public var minDwellSeconds: Double
    public var hybridAuto: HybridAutoConfig?

    public init(
        id: UUID = UUID(),
        name: String,
        input: SensorID,
        points: [CurvePoint],
        hysteresisC: Double = 3,
        minDwellSeconds: Double = 8,
        hybridAuto: HybridAutoConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.points = points
        self.hysteresisC = hysteresisC
        self.minDwellSeconds = minDwellSeconds
        self.hybridAuto = hybridAuto
    }

    /// Returns a copy with every invariant enforced: points sorted and
    /// bounded (2–8), hysteresis/dwell non-negative, hybrid thresholds
    /// ordered with a ≥2 °C gap and sitting below the first curve point.
    public func sanitized(minRPM: Double, maxRPM: Double) -> FanCurve {
        var copy = self
        copy.points = copy.points
            .map { CurvePoint(tempC: min(max($0.tempC, 0), 120),
                              rpm: min(max($0.rpm, minRPM), maxRPM)) }
            .sorted { $0.tempC < $1.tempC }
        if copy.points.count > 8 { copy.points = Array(copy.points.prefix(8)) }
        while copy.points.count < 2 {
            copy.points.append(CurvePoint(tempC: 90, rpm: maxRPM))
        }
        copy.hysteresisC = max(0, copy.hysteresisC)
        copy.minDwellSeconds = max(0, copy.minDwellSeconds)
        if var hybrid = copy.hybridAuto {
            hybrid.releaseBelowC = min(max(hybrid.releaseBelowC, 0), 110)
            hybrid.reacquireAboveC = max(hybrid.reacquireAboveC, hybrid.releaseBelowC + 2)
            hybrid.releaseDelaySeconds = max(5, hybrid.releaseDelaySeconds)
            copy.hybridAuto = hybrid
        }
        return copy
    }
}

// MARK: - Evaluation

public enum CurveMath {
    /// Piecewise-linear interpolation. Below the first point → first RPM;
    /// above the last → last RPM. Assumes sorted points (see `sanitized`).
    public static func targetRPM(curve points: [CurvePoint], tempC: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if tempC <= first.tempC { return first.rpm }
        if tempC >= last.tempC { return last.rpm }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if tempC <= b.tempC {
                let span = b.tempC - a.tempC
                // Duplicate temps: step straight to the later point's RPM.
                guard span > 0.0001 else { return b.rpm }
                let f = (tempC - a.tempC) / span
                return a.rpm + f * (b.rpm - a.rpm)
            }
        }
        return last.rpm
    }
}

// MARK: - Control loop

/// The curve state machine, deliberately pure: time is an argument, effects
/// are returned as `Action`s, and every transition is unit-testable without
/// hardware. The caller (FanControlStore) owns actually talking to the daemon.
public struct CurveRuntime: Sendable {
    public enum Action: Equatable, Sendable {
        /// Send this target to the daemon.
        case set(rpm: Double)
        /// Hand the fan to macOS automatic (hybrid zone entered).
        case release
        case none
    }

    public enum Phase: Equatable, Sendable {
        case controlling
        /// Hybrid-auto released; macOS owns the fan until reacquire.
        case released
    }

    public private(set) var phase: Phase = .controlling
    private var curve: FanCurve
    private var lastSentRPM: Double?
    private var tempAtLastSend: Double?
    private var lastDecreaseAt: Date?
    private var belowSince: Date?

    /// RPM changes smaller than this are noise, not signal — and every write
    /// is a root round-trip.
    public static let minimumDeltaRPM: Double = 50
    /// Floor between any two sends, even increases, to avoid write spam.
    public static let minimumSendInterval: TimeInterval = 2
    /// Increases require the temperature itself to have risen this much since
    /// the last send. Without it, ±1 °C sensor jitter on a steep curve segment
    /// (~210 RPM/°C above the knee on this machine) ratchets the fan upward on
    /// pure noise. A real load spike clears 1.5 °C within a tick or two, so
    /// genuine spin-up is delayed by at most one evaluation.
    public static let upDeadbandC: Double = 1.5

    private var lastSendAt: Date?

    public init(curve: FanCurve) {
        self.curve = curve
    }

    /// Advances the state machine one tick. `tempC` nil means the input sensor
    /// could not be read — after the caller's own tolerance, it should release.
    public mutating func step(tempC: Double, now: Date) -> Action {
        // Hybrid-auto transitions take priority over target updates.
        if let hybrid = curve.hybridAuto {
            switch phase {
            case .released:
                if tempC >= hybrid.reacquireAboveC {
                    phase = .controlling
                    belowSince = nil
                    // Re-entry: send unconditionally; there is no "last sent"
                    // state worth honouring after macOS had control.
                    let target = CurveMath.targetRPM(curve: curve.points, tempC: tempC)
                    recordSend(target, tempC: tempC, now: now)
                    return .set(rpm: target)
                }
                return .none

            case .controlling:
                if tempC < hybrid.releaseBelowC {
                    if let since = belowSince {
                        if now.timeIntervalSince(since) >= hybrid.releaseDelaySeconds {
                            phase = .released
                            belowSince = nil
                            lastSentRPM = nil
                            tempAtLastSend = nil
                            return .release
                        }
                    } else {
                        belowSince = now
                    }
                } else {
                    belowSince = nil
                }
            }
        }

        let target = CurveMath.targetRPM(curve: curve.points, tempC: tempC)

        guard let last = lastSentRPM else {
            recordSend(target, tempC: tempC, now: now)
            return .set(rpm: target)
        }

        let delta = target - last
        guard abs(delta) >= Self.minimumDeltaRPM else { return .none }

        if let lastSend = lastSendAt, now.timeIntervalSince(lastSend) < Self.minimumSendInterval {
            return .none
        }

        if delta > 0 {
            // Spin-up: prompt, but only for a real temperature rise — see
            // upDeadbandC. Never delayed by hysteresis or dwell.
            if let anchor = tempAtLastSend, tempC - anchor < Self.upDeadbandC {
                return .none
            }
            recordSend(target, tempC: tempC, now: now)
            return .set(rpm: target)
        }

        // Spin-down: both hysteresis and dwell must clear. This is what stops
        // RPM ping-pong when the temperature hovers at a curve knee.
        if let anchor = tempAtLastSend, anchor - tempC < curve.hysteresisC {
            return .none
        }
        if let lastDecrease = lastDecreaseAt,
           now.timeIntervalSince(lastDecrease) < curve.minDwellSeconds {
            return .none
        }
        lastDecreaseAt = now
        recordSend(target, tempC: tempC, now: now)
        return .set(rpm: target)
    }

    private mutating func recordSend(_ rpm: Double, tempC: Double, now: Date) {
        lastSentRPM = rpm
        tempAtLastSend = tempC
        lastSendAt = now
    }

    /// Forces the runtime to forget its send history — call after the daemon
    /// reports it released (lease lapse, sleep) so the next tick re-sends.
    public mutating func resetSendState() {
        lastSentRPM = nil
        tempAtLastSend = nil
        lastDecreaseAt = nil
        lastSendAt = nil
        if phase == .released { return }
        phase = .controlling
    }
}
