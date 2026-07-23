import Foundation
import os.log
import Security
import TelemetryShared

/// XPC listener delegate. Every connection is authenticated by code-signing
/// requirement before it is resumed — the daemon runs as root, and an
/// unauthenticated listener here is a local privilege escalation (the exact
/// bug that was CVE-2025-21606 in Stats).
final class HelperTool: NSObject, NSXPCListenerDelegate, TelemetryHelperProtocol {
    static let log = Logger(subsystem: HelperConstants.helperBundleID, category: "xpc")

    private let controller: DaemonFanController
    private let listener: NSXPCListener

    /// Connection bookkeeping happens on this queue only.
    private let stateQueue = DispatchQueue(label: "com.jamesbailey.telemetry.helper.state")
    private var connections: [NSXPCConnection] = []
    private var exitTimer: DispatchSourceTimer?

    /// Built once at startup; nil means signing info was unreadable and the
    /// daemon must refuse every connection (fail closed).
    private let codeSigningRequirement: String?

    init(controller: DaemonFanController) {
        self.controller = controller
        self.listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)

        if let team = HelperTool.currentTeamIdentifier() {
            // Peer must be our app, signed by the same team as this daemon.
            // Because SMAppService forces app and daemon to share an identity,
            // "peer team == my team" is the right invariant for a dev cert
            // today, Developer ID later, and any third party building from
            // source with their own certificate.
            codeSigningRequirement =
                "anchor apple generic and identifier \"\(HelperConstants.appBundleID)\" " +
                "and certificate leaf[subject.OU] = \"\(team)\""
            Self.log.info("codesign requirement armed for team \(team, privacy: .public)")
        } else {
            codeSigningRequirement = nil
            Self.log.fault("cannot read own team identifier — refusing all connections")
        }

        super.init()
        listener.delegate = self

        controller.onBecameIdle = { [weak self] in self?.armExitTimerIfQuiescent() }
    }

    func start() {
        listener.resume()
        Self.log.info("listening on \(HelperConstants.machServiceName, privacy: .public)")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let requirement = codeSigningRequirement else {
            Self.log.fault("rejecting connection: no signing requirement available")
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)

        newConnection.exportedInterface = NSXPCInterface(with: TelemetryHelperProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self else { return }
            self.stateQueue.async {
                if let connection = newConnection {
                    self.connections.removeAll { $0 === connection }
                }
                Self.log.info("connection invalidated; \(self.connections.count) remain")
                if self.connections.isEmpty {
                    // The app died or quit. Do not wait for the lease — hand
                    // the fans back now, then consider exiting.
                    self.controller.restoreAsync(reason: "last client disconnected")
                    self.armExitTimerIfQuiescent()
                }
            }
        }
        newConnection.interruptionHandler = {
            Self.log.error("connection interrupted")
        }

        stateQueue.async {
            self.connections.append(newConnection)
            self.exitTimer?.cancel()
            self.exitTimer = nil
        }
        newConnection.resume()
        Self.log.info("connection accepted")
        return true
    }

    // MARK: - TelemetryHelperProtocol

    func handshake(clientProtocolVersion: Int, reply: @escaping (String, Int) -> Void) {
        reply(TelemetryVersion.helperVersion, TelemetryVersion.protocolVersion)
    }

    func setTargetRPM(fanIndex: Int, rpm: Double, leaseSeconds: Int,
                      reply: @escaping (Int, Double) -> Void) {
        controller.setTargetRPM(fan: fanIndex, rpm: rpm, leaseSeconds: leaseSeconds) { code, applied in
            reply(code.rawValue, applied)
        }
    }

    func renewLease(leaseSeconds: Int, reply: @escaping (Int) -> Void) {
        controller.renewLease(seconds: leaseSeconds) { reply($0.rawValue) }
    }

    func releaseToAuto(fanIndex: Int, reply: @escaping (Int) -> Void) {
        // Single fan on the reference machine; release everything either way.
        controller.releaseToAuto { reply($0.rawValue) }
    }

    func releaseAllToAuto(reply: @escaping (Int) -> Void) {
        controller.releaseToAuto { reply($0.rawValue) }
    }

    func status(reply: @escaping (Data) -> Void) {
        controller.currentStatus { status in
            reply((try? JSONEncoder().encode(status)) ?? Data())
        }
    }

    // MARK: - Self-exit

    /// A root process should exist only while needed: exit 60 s after the last
    /// connection closes, provided the fans are back under macOS control.
    private func armExitTimerIfQuiescent() {
        stateQueue.async { [self] in
            guard connections.isEmpty else { return }
            exitTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(deadline: .now() + 60)
            timer.setEventHandler { [weak self] in
                guard let self, self.connections.isEmpty, self.controller.isIdle else { return }
                Self.log.info("quiescent for 60 s — exiting")
                exit(0)
            }
            timer.resume()
            exitTimer = timer
        }
    }

    // MARK: - Signing identity

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
