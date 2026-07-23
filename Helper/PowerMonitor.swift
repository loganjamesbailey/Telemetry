import Foundation
import IOKit
import IOKit.pwr_mgt
import os.log

// IOKit's message macros are not imported into Swift; values are
// sys_iokit | sub_iokit_common | code.
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

/// Watches system power transitions so the daemon never holds a forced fan
/// into sleep — the firmware drops forced state during sleep anyway, and a
/// stale bookkeeping entry on wake would mean a lease timer "restoring" state
/// that no longer matches the hardware. The app re-applies its mode after wake.
final class PowerMonitor {
    static let log = Logger(subsystem: "com.jamesbailey.telemetry.helper", category: "power")

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    var onWillSleep: (() -> Void)?

    func start() {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refCon, &notifyPort, powerCallback, &notifier)
        guard rootPort != 0, let notifyPort else {
            Self.log.error("IORegisterForSystemPower failed; sleep handling disabled")
            return
        }
        IONotificationPortSetDispatchQueue(
            notifyPort, DispatchQueue(label: "com.jamesbailey.telemetry.helper.power")
        )
        Self.log.info("power notifications armed")
    }

    fileprivate func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case kMsgSystemWillSleep:
            Self.log.info("system will sleep — restoring automatic control")
            onWillSleep?()
            // Never veto or stall sleep; a fan app that blocks sleep was a
            // real shipped bug in Macs Fan Control.
            IOAllowPowerChange(rootPort, notificationID)
        case kMsgCanSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case kMsgSystemHasPoweredOn:
            Self.log.info("system woke")
        default:
            break
        }
    }
}

private func powerCallback(
    refCon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refCon else { return }
    let monitor = Unmanaged<PowerMonitor>.fromOpaque(refCon).takeUnretainedValue()
    monitor.handle(messageType: messageType, argument: messageArgument)
}
