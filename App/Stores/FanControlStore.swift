import AppKit
import Foundation
import Observation
import TelemetryShared

/// UI-facing fan control state. Drives the helper via HelperClient, owns the
/// keepalive loop, and mirrors the daemon's install/connection state.
///
/// Safety division of labour: this store is allowed to be wrong — the daemon's
/// lease, invalidation restore, and watchdog are the guarantees. What this
/// store must do is (a) renew the lease while the user wants control held,
/// (b) release before sleep and re-apply after wake, and (c) release on quit.
@MainActor
@Observable
final class FanControlStore {
    /// Terminal-path access for AppDelegate.applicationWillTerminate.
    static private(set) weak var shared: FanControlStore?

    enum Mode: Equatable {
        case systemAuto
        case constant(Double)
        case curve(FanCurve)
        case max
    }

    enum HelperReadiness: Equatable {
        case unknown
        case notInstalled
        case awaitingApproval
        case ready(version: String)
        case failed(String)
    }

    private(set) var mode: Mode = .systemAuto
    private(set) var readiness: HelperReadiness = .unknown
    private(set) var lastResult: String?
    /// The RPM the daemon reports it actually applied (post-clamp).
    private(set) var appliedRPM: Double?

    /// Slider position, kept even while in auto so the user's chosen value
    /// survives mode flips.
    var desiredRPM: Double = 3000

    private let client = HelperClient()
    private var keepaliveTimer: Timer?
    private var approvalPollTimer: Timer?

    // MARK: Curve engine state

    /// Supplies the current temperature for a sensor; wired to SensorStore at
    /// app startup so the two stores stay decoupled.
    var temperatureProvider: (SensorID) -> Double? = { _ in nil }

    private var curveRuntime: CurveRuntime?
    private var curveTimer: Timer?
    private var missedSensorReads = 0
    /// UI copy describing what the curve is doing right now.
    private(set) var curveActivity: String?
    /// True while hybrid-auto has handed the fan to macOS (mode stays .curve).
    private(set) var hybridReleased = false

    var isReady: Bool {
        if case .ready = readiness { return true }
        return false
    }

    init() {
        Self.shared = self
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            // The daemon restores automatic control itself on disconnect; make
            // the UI agree with the hardware.
            if self.mode != .systemAuto {
                self.mode = .systemAuto
                self.lastResult = "Helper connection lost — fans returned to automatic"
            }
            self.stopKeepalive()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )

        refreshReadiness()
    }

    // MARK: - Install flow

    func refreshReadiness() {
        switch HelperInstaller.state {
        case .enabled:
            HelperInstaller.reassertRegistrationIfEnabled()
            connectAndHandshake()
        case .requiresApproval:
            readiness = .awaitingApproval
            pollForApproval()
        case .notRegistered, .notFound:
            readiness = .notInstalled
        case .failed(let why):
            readiness = .failed(why)
        }
    }

    func installHelper() {
        switch HelperInstaller.register() {
        case .enabled:
            connectAndHandshake()
        case .requiresApproval:
            readiness = .awaitingApproval
            HelperInstaller.openLoginItemsSettings()
            pollForApproval()
        case .failed(let why):
            readiness = .failed(why)
        case .notRegistered, .notFound:
            readiness = .notInstalled
        }
    }

    private func pollForApproval() {
        approvalPollTimer?.invalidate()
        approvalPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if HelperInstaller.state == .enabled {
                    self.approvalPollTimer?.invalidate()
                    self.approvalPollTimer = nil
                    self.connectAndHandshake()
                }
            }
        }
    }

    private func connectAndHandshake() {
        client.handshake { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let version):
                self.readiness = .ready(version: version)
            case .failure(.protocolMismatch):
                // Bounce launchd onto the binary inside the current bundle,
                // then retry once.
                _ = HelperInstaller.reregister()
                self.client.disconnect()
                self.client.handshake { retry in
                    switch retry {
                    case .success(let version): self.readiness = .ready(version: version)
                    case .failure(let error): self.readiness = .failed("\(error)")
                    }
                }
            case .failure(let error):
                self.readiness = .failed("\(error)")
            }
        }
    }

    // MARK: - Mode changes

    /// Remembered so wake re-application of `.max` uses the fan's real
    /// ceiling, not whatever the slider happened to hold.
    private var lastKnownMaxRPM: Double = 7199

    func apply(_ newMode: Mode, maxRPM: Double) {
        guard isReady else { return }
        lastKnownMaxRPM = maxRPM
        stopCurveEngine()
        switch newMode {
        case .systemAuto:
            client.releaseAll { [weak self] result in
                guard let self else { return }
                self.mode = .systemAuto
                self.appliedRPM = nil
                self.stopKeepalive()
                self.lastResult = result.isSuccess || result == .notForced
                    ? nil
                    : "Release failed: \(result.description)"
            }
        case .constant(let rpm):
            sendTarget(rpm, as: .constant(rpm))
        case .curve(let curve):
            startCurveEngine(curve.sanitized(minRPM: 0, maxRPM: maxRPM))
        case .max:
            sendTarget(maxRPM, as: .max)
        }
    }

    // MARK: - Curve engine

    private func startCurveEngine(_ curve: FanCurve) {
        mode = .curve(curve)
        hybridReleased = false
        curveActivity = "Starting…"
        curveRuntime = CurveRuntime(curve: curve)
        missedSensorReads = 0

        curveTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.curveTick() }
        }
        // Common modes: the popover holds the run loop in eventTracking.
        RunLoop.main.add(timer, forMode: .common)
        curveTimer = timer
        curveTick()
    }

    private func stopCurveEngine() {
        curveTimer?.invalidate()
        curveTimer = nil
        curveRuntime = nil
        curveActivity = nil
        hybridReleased = false
    }

    private func curveTick() {
        guard case .curve(let curve) = mode, curveRuntime != nil else { return }

        guard let temp = temperatureProvider(curve.input) else {
            missedSensorReads += 1
            // Driving a forced fan blind is the one unforgivable state: after
            // three blind ticks (~6 s), hand the fan back. The daemon's own
            // watchdog would also catch this, later and independently.
            if missedSensorReads >= 3 && !hybridReleased {
                lastResult = "Curve input unreadable — fan returned to automatic"
                apply(.systemAuto, maxRPM: lastKnownMaxRPM)
            }
            return
        }
        missedSensorReads = 0

        // App-side safety: this belt exists even though the daemon wears the
        // suspenders (its own watchdog trips at 95/100 °C from its own reads).
        if let hottest = temperatureProvider(VirtualSensors.systemHottest), hottest >= 100 {
            lastResult = String(format: "%.0f °C — safety released to automatic", hottest)
            apply(.systemAuto, maxRPM: lastKnownMaxRPM)
            return
        }

        guard var runtime = curveRuntime else { return }
        let action = runtime.step(tempC: temp, now: Date())
        curveRuntime = runtime

        switch action {
        case .none:
            if hybridReleased {
                curveActivity = String(format: "AUTO · below curve (%.0f°)", temp)
            } else if let applied = appliedRPM {
                curveActivity = String(format: "%.0f° → %d RPM", temp, Int(applied))
            }

        case .release:
            hybridReleased = true
            stopKeepalive()
            client.releaseAll { [weak self] _ in
                self?.curveActivity = "AUTO · below curve"
                self?.appliedRPM = nil
            }

        case .set(let rpm):
            let wasReleased = hybridReleased
            hybridReleased = false
            client.setTargetRPM(fan: 0, rpm: rpm) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let (code, applied)) where code.isSuccess:
                    self.appliedRPM = applied
                    self.curveActivity = String(
                        format: "%@%.0f° → %d RPM", wasReleased ? "reacquired · " : "", temp, Int(applied)
                    )
                    self.startKeepalive()
                case .success(let (code, _)):
                    self.curveFault("Curve write failed: \(code.description)")
                case .failure(let error):
                    self.curveFault("Curve write failed: \(error)")
                }
            }
        }
    }

    private func curveFault(_ message: String) {
        lastResult = message
        // Tell the runtime to re-send on the next tick rather than believing a
        // target the daemon never applied.
        curveRuntime?.resetSendState()
    }

    private func sendTarget(_ rpm: Double, as newMode: Mode) {
        client.setTargetRPM(fan: 0, rpm: rpm) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (code, applied)) where code.isSuccess:
                self.mode = newMode
                self.appliedRPM = applied
                self.lastResult = code == .clampedToRange
                    ? "Clamped to \(Int(applied)) RPM (fan range)"
                    : nil
                self.startKeepalive()
            case .success(let (code, _)):
                self.mode = .systemAuto
                self.lastResult = "Failed: \(code.description)"
                self.stopKeepalive()
            case .failure(let error):
                self.mode = .systemAuto
                self.lastResult = "Failed: \(error)"
                self.stopKeepalive()
            }
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        stopKeepalive()
        keepaliveTimer = Timer.scheduledTimer(
            withTimeInterval: HelperConstants.keepaliveInterval, repeats: true
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.mode != .systemAuto else { return }
                self.client.renewLease { result in
                    if result == .notForced {
                        // Daemon let go (lease lapse, watchdog, sleep) —
                        // resync the UI with reality rather than fighting it.
                        self.client.status { status in
                            self.stopCurveEngine()
                            self.mode = .systemAuto
                            self.appliedRPM = nil
                            self.stopKeepalive()
                            self.lastResult = status?.lastError ?? "Fan returned to automatic"
                        }
                    }
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }

    // MARK: - Sleep / wake / quit

    @objc private func willSleep() {
        guard mode != .systemAuto else { return }
        // Remember what to re-apply; the daemon independently restores auto on
        // its own willSleep notification. The curve timer must stop too, or a
        // stray tick between wake and re-apply could force the fan mid-restore.
        modeToReapplyAfterWake = mode
        stopCurveEngine()
        client.releaseAll { _ in }
        stopKeepalive()
    }

    @objc private func didWake() {
        guard let toReapply = modeToReapplyAfterWake else { return }
        modeToReapplyAfterWake = nil
        // Firmware needs ~3 s after wake before it will accept forced mode.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard self.isReady else { return }
            self.apply(toReapply, maxRPM: self.lastKnownMaxRPM)
        }
    }

    private var modeToReapplyAfterWake: Mode?

    /// Called from applicationWillTerminate. Bounded; the daemon's
    /// invalidation restore is the true backstop.
    func releaseOnQuit() {
        guard mode != .systemAuto else { return }
        client.releaseAllSynchronously()
    }
}
