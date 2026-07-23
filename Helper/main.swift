import Foundation
import os.log
import TelemetryShared

// TelemetryHelper — Telemetry's root daemon.
//
// Launched on demand by launchd when the app connects to the Mach service;
// exits on its own once quiescent. Runs exactly one job: fan control, with the
// safety obligations that come with it. No GUI frameworks are linked here and
// none may ever be (root process).

let bootLog = Logger(subsystem: HelperConstants.helperBundleID, category: "boot")

// "First light": if this line never appears, the failure is launchd
// configuration (status 78 = the five strings disagree), not code.
bootLog.info("TelemetryHelper \(TelemetryVersion.helperVersion, privacy: .public) starting (uid \(getuid()))")

let controller = DaemonFanController()
let tool = HelperTool(controller: controller)

// Restore automatic control on any terminating signal. SIGKILL is uncatchable —
// that case is covered by the lease timer while we live, and by sleep/reboot
// as the physical backstop.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        bootLog.info("signal \(sig) — restoring automatic control before exit")
        controller.restoreSynchronously(reason: "terminating signal \(sig)")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let powerMonitor = PowerMonitor()
powerMonitor.onWillSleep = {
    controller.restoreSynchronously(reason: "system sleep")
}
powerMonitor.start()

tool.start()
dispatchMain()
