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
        case .max:
            sendTarget(maxRPM, as: .max)
        }
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
        // its own willSleep notification.
        modeToReapplyAfterWake = mode
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
