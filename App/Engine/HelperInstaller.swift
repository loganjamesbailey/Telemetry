import Foundation
import os.log
import ServiceManagement
import TelemetryShared

/// Wraps the SMAppService state machine for the bundled LaunchDaemon.
///
/// The counter-intuitive parts, verified against Apple's docs and DTS posts:
/// - `register()` throwing "Operation not permitted" is the SUCCESS path on
///   first install — it means approval is pending in System Settings.
/// - Status must always be read live; users can toggle the daemon off in
///   Login Items at any time, so caching it lies.
/// - After an app update changes the helper, unregister()+register() bounces
///   launchd onto the new binary (no re-approval needed once approved).
enum HelperInstaller {
    static let log = Logger(subsystem: HelperConstants.appBundleID, category: "installer")

    enum InstallState: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
        case failed(String)

        var userDescription: String {
            switch self {
            case .notRegistered: return "Helper not installed"
            case .requiresApproval: return "Waiting for approval in System Settings"
            case .enabled: return "Helper enabled"
            case .notFound: return "Helper not found — reinstall the app"
            case .failed(let why): return why
            }
        }
    }

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.plistName)
    }

    static var state: InstallState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .failed("Unknown SMAppService status")
        }
    }

    /// Kicks off registration. Returns the resulting state; "Operation not
    /// permitted" is folded into `.requiresApproval` because that is what it
    /// means on first install.
    static func register() -> InstallState {
        do {
            try service.register()
            log.info("register() succeeded")
        } catch {
            let ns = error as NSError
            log.info("register() threw \(ns.domain, privacy: .public) \(ns.code): \(ns.localizedDescription, privacy: .public)")
            // kSMErrorLaunchDeniedByUser / "Operation not permitted" both mean
            // the system wants the user to flip the switch in Login Items.
            if state == .requiresApproval || ns.code == 1 {
                return .requiresApproval
            }
            return .failed(ns.localizedDescription)
        }
        return state
    }

    static func unregister() {
        do {
            try service.unregister()
        } catch {
            log.error("unregister() failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Bounce for helper updates: safe once approved, no re-auth prompt.
    static func reregister() -> InstallState {
        unregister()
        return register()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
