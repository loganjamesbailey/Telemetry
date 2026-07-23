import Foundation
import os.log
import SMCKit
import TelemetryShared

/// The daemon's fan state machine. Owns every SMC write and — critically —
/// owns safety. The app is treated as an unreliable client: if it crashes,
/// hangs, or simply stops renewing its lease, this class restores automatic
/// control on its own. The firmware will not save us; this code must.
final class DaemonFanController {
    static let log = Logger(subsystem: HelperConstants.helperBundleID, category: "fan")

    /// Serial queue owning all SMC access (SMCClient is not thread-safe).
    private let queue = DispatchQueue(label: "com.jamesbailey.telemetry.helper.smc")

    private var smc: SMCClient?
    private var fanControl: FanControl?

    private enum State {
        case idle
        case forced(fan: Int, targetRPM: Double, leaseDeadline: Date)
    }

    private var state: State = .idle
    private var leaseTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var watchdogTemperatureKeys: [String] = []
    private var watchdogFailureStreak = 0
    private(set) var lastError: String?
    private var watchdogHottest: Double?

    /// Called (on the SMC queue) whenever the daemon transitions to idle, so
    /// the tool can arm its self-exit timer.
    var onBecameIdle: (() -> Void)?

    // MARK: - Setup

    /// Lazily connect so launchd can start us without touching hardware until
    /// the first real command.
    private func ensureHardware() throws -> FanControl {
        if let fanControl { return fanControl }
        let client = try SMCClient()
        let control = FanControl(smc: client)
        smc = client
        fanControl = control
        return control
    }

    // MARK: - Commands (each hops to the serial queue)

    func setTargetRPM(fan: Int, rpm: Double, leaseSeconds: Int,
                      completion: @escaping (HelperResult, Double) -> Void) {
        queue.async { [self] in
            guard rpm.isFinite, rpm >= 0 else {
                completion(.rejectedNonFinite, 0)
                return
            }
            do {
                let control = try ensureHardware()
                let count = (try? control.fanCount()) ?? 0
                guard (0..<count).contains(fan) else {
                    completion(.badFanIndex, 0)
                    return
                }

                let result = try control.setTargetRPM(fan: fan, rpm: rpm) {
                    Self.log.info("smc: \($0, privacy: .public)")
                }
                armLease(fan: fan, targetRPM: Double(result.applied), seconds: leaseSeconds)
                startWatchdog()
                lastError = nil
                completion(result.clamped ? .clampedToRange : .ok, Double(result.applied))
            } catch {
                lastError = "\(error)"
                Self.log.error("setTargetRPM failed: \(String(describing: error), privacy: .public)")
                // setTargetRPM rolls back its own partial state; make sure our
                // bookkeeping agrees with the hardware.
                transitionToIdle(reason: "setTargetRPM failed", restore: false)
                completion(.smcWriteFailed, 0)
            }
        }
    }

    func renewLease(seconds: Int, completion: @escaping (HelperResult) -> Void) {
        queue.async { [self] in
            guard case .forced(let fan, let target, _) = state else {
                completion(.notForced)
                return
            }
            armLease(fan: fan, targetRPM: target, seconds: seconds)
            completion(.ok)
        }
    }

    func releaseToAuto(completion: @escaping (HelperResult) -> Void) {
        queue.async { [self] in
            completion(restoreAutomatic(reason: "client requested release") ? .ok : .smcWriteFailed)
        }
    }

    func currentStatus(completion: @escaping (HelperStatus) -> Void) {
        queue.async { [self] in
            var isForced = false
            var target: Double?
            var leaseRemaining: Double?
            if case .forced(_, let t, let deadline) = state {
                isForced = true
                target = t
                leaseRemaining = max(0, deadline.timeIntervalSinceNow)
            }
            let telemetry = try? ensureHardware().telemetry(fan: 0)
            completion(HelperStatus(
                helperVersion: TelemetryVersion.helperVersion,
                protocolVersion: TelemetryVersion.protocolVersion,
                isForced: isForced,
                targetRPM: target,
                leaseRemainingSeconds: leaseRemaining,
                fanCount: (try? ensureHardware().fanCount()) ?? 0,
                minRPM: telemetry.map { Double($0.minRPM) } ?? 0,
                maxRPM: telemetry.map { Double($0.maxRPM) } ?? 0,
                watchdogHottestC: watchdogHottest,
                lastError: lastError
            ))
        }
    }

    /// Synchronous restore for terminal paths (SIGTERM, sleep). Blocks the
    /// caller until the SMC queue has finished the handback.
    func restoreSynchronously(reason: String) {
        queue.sync { [self] in
            _ = restoreAutomatic(reason: reason)
        }
    }

    /// Async restore for connection-loss paths.
    func restoreAsync(reason: String) {
        queue.async { [self] in
            _ = restoreAutomatic(reason: reason)
        }
    }

    var isIdle: Bool {
        queue.sync {
            if case .idle = state { return true }
            return false
        }
    }

    // MARK: - Lease (the dead-man's switch)

    /// Must be called on `queue`.
    private func armLease(fan: Int, targetRPM: Double, seconds: Int) {
        let capped = min(max(seconds, 1), HelperConstants.maxLeaseSeconds)
        let deadline = Date().addingTimeInterval(TimeInterval(capped))
        state = .forced(fan: fan, targetRPM: targetRPM, leaseDeadline: deadline)

        leaseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(capped))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Self.log.error("lease expired — restoring automatic control")
            self.lastError = "lease expired; automatic control restored"
            _ = self.restoreAutomatic(reason: "lease expired")
        }
        timer.resume()
        leaseTimer = timer
    }

    /// Must be called on `queue`. Returns true when macOS verifiably owns the
    /// fans again.
    @discardableResult
    private func restoreAutomatic(reason: String, restore: Bool = true) -> Bool {
        Self.log.info("restore requested: \(reason, privacy: .public)")
        var ok = true
        if restore, let control = fanControl {
            do {
                try control.restoreAutomatic { Self.log.info("smc: \($0, privacy: .public)") }
            } catch {
                ok = false
                lastError = "restore failed: \(error)"
                Self.log.fault("RESTORE FAILED: \(String(describing: error), privacy: .public)")
            }
            let stuck = control.fansStillForced()
            if !stuck.isEmpty {
                ok = false
                lastError = "fans still forced after restore: \(stuck)"
                Self.log.fault("fans still forced after restore: \(stuck, privacy: .public)")
            }
        }
        transitionToIdle(reason: reason, restore: false)
        return ok
    }

    /// Must be called on `queue`.
    private func transitionToIdle(reason: String, restore: Bool) {
        if restore { _ = restoreAutomatic(reason: reason) ; return }
        state = .idle
        leaseTimer?.cancel()
        leaseTimer = nil
        stopWatchdog()
        onBecameIdle?()
    }

    // MARK: - Watchdog (independent of the app AND of the lease)

    /// While forced, sample die temperatures every 2 s. The key set is
    /// discovered, not hard-coded: this machine's per-core keys (Tp2a family)
    /// differ from the ones documented for other M1 variants.
    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        if watchdogTemperatureKeys.isEmpty, let smc {
            let keys = (try? smc.allKeys()) ?? []
            watchdogTemperatureKeys = keys.filter { key in
                guard key.hasPrefix("T"), let (type, bytes) = try? smc.readBytes(key) else { return false }
                let value: Float?
                switch type {
                case SMCDataType.flt: value = SMCDecode.float(bytes)
                case SMCDataType.sp78: value = SMCDecode.sp78(bytes)
                default: value = nil
                }
                guard let v = value else { return false }
                return v > 0 && v < 110
            }
            Self.log.info("watchdog tracking \(self.watchdogTemperatureKeys.count) temperature keys")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        watchdogHottest = nil
        watchdogFailureStreak = 0
    }

    /// Must be called on `queue`.
    private func watchdogTick() {
        guard case .forced(let fan, let target, _) = state, let smc, let fanControl else { return }

        var hottest: Float = -1
        for key in watchdogTemperatureKeys {
            guard let (type, bytes) = try? smc.readBytes(key) else { continue }
            let value: Float?
            switch type {
            case SMCDataType.flt: value = SMCDecode.float(bytes)
            case SMCDataType.sp78: value = SMCDecode.sp78(bytes)
            default: value = nil
            }
            if let v = value, v < 120 { hottest = max(hottest, v) }
        }

        guard hottest > 0 else {
            watchdogFailureStreak += 1
            // Forced fan with no thermal visibility is exactly what the
            // watchdog exists to prevent — three blind ticks and we let go.
            if watchdogFailureStreak >= 3 {
                lastError = "watchdog blind (no readable temperatures); released to automatic"
                Self.log.fault("watchdog blind for 3 ticks — releasing")
                _ = restoreAutomatic(reason: "watchdog blind")
            }
            return
        }
        watchdogFailureStreak = 0
        watchdogHottest = Double(hottest)

        if hottest >= 100 {
            lastError = "watchdog: \(hottest) °C — released to automatic"
            Self.log.fault("watchdog: \(hottest) °C >= 100, releasing to automatic")
            _ = restoreAutomatic(reason: "watchdog critical temperature")
        } else if hottest >= 95 {
            // Hot but not critical: pin the fan to max while keeping the
            // lease. The client sees the override via status.
            if let maxRPM = try? fanControl.telemetry(fan: fan).maxRPM, Float(target) < maxRPM {
                Self.log.error("watchdog: \(hottest) °C >= 95, overriding target to max")
                lastError = "watchdog: \(hottest) °C — target overridden to max"
                if let result = try? fanControl.setTargetRPM(fan: fan, rpm: Double(maxRPM)) {
                    if case .forced(_, _, let deadline) = state {
                        state = .forced(fan: fan, targetRPM: Double(result.applied), leaseDeadline: deadline)
                    }
                }
            }
        }
    }
}
