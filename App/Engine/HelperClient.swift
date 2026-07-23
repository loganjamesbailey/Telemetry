import Foundation
import os.log
import Security
import TelemetryShared

/// Owns the NSXPCConnection to the root daemon: connect lazily, pin the peer,
/// handshake versions, and forward fan commands. All completion handlers are
/// delivered on the main actor.
final class HelperClient {
    static let log = Logger(subsystem: HelperConstants.appBundleID, category: "helper-client")

    enum ClientError: Error, CustomStringConvertible {
        case notConnected
        case protocolMismatch(helper: Int, app: Int)
        case xpc(String)

        var description: String {
            switch self {
            case .notConnected: return "helper not connected"
            case .protocolMismatch(let h, let a): return "helper speaks v\(h), app expects v\(a)"
            case .xpc(let message): return message
            }
        }
    }

    private var connection: NSXPCConnection?
    private(set) var handshakeComplete = false

    /// Called when the connection drops so the store can reflect reality.
    var onDisconnect: (@MainActor () -> Void)?

    // MARK: - Connection lifecycle

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }

        let new = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName, options: .privileged
        )
        new.remoteObjectInterface = NSXPCInterface(with: TelemetryHelperProtocol.self)

        // Pin the daemon exactly as it pins us: right identifier, same team.
        if let team = Self.currentTeamIdentifier() {
            new.setCodeSigningRequirement(
                "anchor apple generic and identifier \"\(HelperConstants.helperBundleID)\" " +
                "and certificate leaf[subject.OU] = \"\(team)\""
            )
        } else {
            Self.log.fault("cannot read own team id; refusing to talk to helper")
        }

        new.invalidationHandler = { [weak self] in
            Self.log.error("helper connection invalidated")
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.handshakeComplete = false
                self?.onDisconnect?()
            }
        }
        new.interruptionHandler = {
            Self.log.error("helper connection interrupted")
        }

        new.resume()
        connection = new
        return new
    }

    private func proxy(_ onError: @escaping @MainActor (ClientError) -> Void) -> TelemetryHelperProtocol? {
        let proxy = ensureConnection().remoteObjectProxyWithErrorHandler { error in
            Self.log.error("xpc error: \(String(describing: error), privacy: .public)")
            Task { @MainActor in onError(.xpc("\(error.localizedDescription)")) }
        }
        return proxy as? TelemetryHelperProtocol
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
        handshakeComplete = false
    }

    // MARK: - Calls

    func handshake(completion: @escaping @MainActor (Result<String, ClientError>) -> Void) {
        guard let proxy = proxy({ completion(.failure($0)) }) else {
            Task { @MainActor in completion(.failure(.notConnected)) }
            return
        }
        proxy.handshake(clientProtocolVersion: TelemetryVersion.protocolVersion) { [weak self] version, protocolVersion in
            Task { @MainActor in
                guard protocolVersion == TelemetryVersion.protocolVersion else {
                    completion(.failure(.protocolMismatch(
                        helper: protocolVersion, app: TelemetryVersion.protocolVersion
                    )))
                    return
                }
                self?.handshakeComplete = true
                completion(.success(version))
            }
        }
    }

    func setTargetRPM(
        fan: Int, rpm: Double,
        completion: @escaping @MainActor (Result<(HelperResult, Double), ClientError>) -> Void
    ) {
        guard let proxy = proxy({ completion(.failure($0)) }) else {
            Task { @MainActor in completion(.failure(.notConnected)) }
            return
        }
        proxy.setTargetRPM(
            fanIndex: fan, rpm: rpm, leaseSeconds: HelperConstants.defaultLeaseSeconds
        ) { code, applied in
            Task { @MainActor in
                completion(.success((HelperResult(rawValue: code) ?? .smcWriteFailed, applied)))
            }
        }
    }

    func renewLease(completion: @escaping @MainActor (HelperResult) -> Void) {
        guard let proxy = proxy({ _ in completion(.smcWriteFailed) }) else {
            Task { @MainActor in completion(.smcWriteFailed) }
            return
        }
        proxy.renewLease(leaseSeconds: HelperConstants.defaultLeaseSeconds) { code in
            Task { @MainActor in completion(HelperResult(rawValue: code) ?? .smcWriteFailed) }
        }
    }

    func releaseAll(completion: @escaping @MainActor (HelperResult) -> Void) {
        guard let proxy = proxy({ _ in completion(.smcWriteFailed) }) else {
            Task { @MainActor in completion(.smcWriteFailed) }
            return
        }
        proxy.releaseAllToAuto { code in
            Task { @MainActor in completion(HelperResult(rawValue: code) ?? .smcWriteFailed) }
        }
    }

    /// Synchronous best-effort release for applicationWillTerminate, bounded
    /// so a hung daemon cannot wedge app quit. The daemon's own
    /// connection-invalidation restore is the real guarantee; this just makes
    /// the common path immediate.
    func releaseAllSynchronously(timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)
        let proxy = ensureConnection().remoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        }
        (proxy as? TelemetryHelperProtocol)?.releaseAllToAuto { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    func status(completion: @escaping @MainActor (HelperStatus?) -> Void) {
        guard let proxy = proxy({ _ in completion(nil) }) else {
            Task { @MainActor in completion(nil) }
            return
        }
        proxy.status { data in
            let status = try? JSONDecoder().decode(HelperStatus.self, from: data)
            Task { @MainActor in completion(status) }
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
