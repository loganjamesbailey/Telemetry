import Foundation

/// The XPC contract between Telemetry.app and the root helper daemon.
///
/// Deliberately tiny and fan-only: no generic command execution, no paths, no
/// shell strings. CVE-2025-21606 (Stats) turned an over-broad helper protocol
/// plus a missing peer check into local root — this protocol is the lesson
/// applied. All parameters are primitives or `Data` so there are no
/// NSSecureCoding class-allowlist pitfalls.
@objc public protocol TelemetryHelperProtocol {
    /// Must be the first call on every new connection. The app compares the
    /// reply against its bundled constants and bounces the daemon
    /// (unregister/register) on mismatch so launchd never keeps running a
    /// stale binary after an app update.
    func handshake(clientProtocolVersion: Int,
                   reply: @escaping (_ helperVersion: String, _ protocolVersion: Int) -> Void)

    /// Forced-RPM command, lease-scoped. The daemon clamps to the fan's real
    /// [min, max] and reports what it actually applied; `leaseSeconds` is
    /// capped at `HelperConstants.maxLeaseSeconds`. When the lease expires
    /// without renewal the daemon restores automatic control on its own.
    func setTargetRPM(fanIndex: Int, rpm: Double, leaseSeconds: Int,
                      reply: @escaping (_ code: Int, _ appliedRPM: Double) -> Void)

    /// Extends the current lease without changing the target.
    func renewLease(leaseSeconds: Int, reply: @escaping (_ code: Int) -> Void)

    /// Hands one fan / all fans back to macOS automatic control.
    func releaseToAuto(fanIndex: Int, reply: @escaping (_ code: Int) -> Void)
    func releaseAllToAuto(reply: @escaping (_ code: Int) -> Void)

    /// JSON-encoded `HelperStatus`.
    func status(reply: @escaping (_ json: Data) -> Void)
}

public enum HelperResult: Int, Sendable {
    case ok = 0
    case clampedToRange = 1
    case badFanIndex = 2
    case smcWriteFailed = 3
    case unlockFailed = 4
    case protocolMismatch = 5
    case rejectedNonFinite = 6
    case notForced = 7

    public var isSuccess: Bool { self == .ok || self == .clampedToRange }

    public var description: String {
        switch self {
        case .ok: return "ok"
        case .clampedToRange: return "clamped to fan range"
        case .badFanIndex: return "no such fan"
        case .smcWriteFailed: return "SMC write failed"
        case .unlockFailed: return "could not take fan control"
        case .protocolMismatch: return "app/helper version mismatch"
        case .rejectedNonFinite: return "invalid RPM value"
        case .notForced: return "fan is not under manual control"
        }
    }
}

/// Snapshot of the daemon's state, serialized as JSON over XPC.
public struct HelperStatus: Codable, Sendable {
    public var helperVersion: String
    public var protocolVersion: Int
    public var isForced: Bool
    public var targetRPM: Double?
    public var leaseRemainingSeconds: Double?
    public var fanCount: Int
    public var minRPM: Double
    public var maxRPM: Double
    public var watchdogHottestC: Double?
    public var lastError: String?

    public init(
        helperVersion: String, protocolVersion: Int, isForced: Bool,
        targetRPM: Double?, leaseRemainingSeconds: Double?, fanCount: Int,
        minRPM: Double, maxRPM: Double, watchdogHottestC: Double?, lastError: String?
    ) {
        self.helperVersion = helperVersion
        self.protocolVersion = protocolVersion
        self.isForced = isForced
        self.targetRPM = targetRPM
        self.leaseRemainingSeconds = leaseRemainingSeconds
        self.fanCount = fanCount
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.watchdogHottestC = watchdogHottestC
        self.lastError = lastError
    }
}

/// The five strings that must stay mutually consistent (label, plist filename,
/// Mach service, bundle ids) live here and in the launchd plist — and nowhere
/// else. A mismatch means launchd status 78 or XPC calls that hang forever.
public enum HelperConstants {
    public static let appBundleID = "com.jamesbailey.telemetry"
    public static let helperBundleID = "com.jamesbailey.telemetry.helper"
    public static let machServiceName = "com.jamesbailey.telemetry.helper.xpc"
    public static let plistName = "com.jamesbailey.telemetry.helper.plist"

    public static let defaultLeaseSeconds = 30
    public static let maxLeaseSeconds = 60
    /// The app renews at a third of the default lease so two consecutive
    /// missed keepalives still leave margin before the daemon lets go.
    public static let keepaliveInterval: TimeInterval = 10
}
