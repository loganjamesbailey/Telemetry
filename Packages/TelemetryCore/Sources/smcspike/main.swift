import Foundation
import HIDSensors
import SMCKit

// smcspike — milestone 1–2 hardware spike for Telemetry.
// Reads need no privileges; force/auto need root (sudo).

let usage = """
smcspike — Telemetry hardware spike (Apple Silicon SMC)

USAGE:
  smcspike fans              Fan telemetry: count, actual/min/max/target RPM, mode
  smcspike temps             All temperature sensors (SMC T-keys + named HID sensors)
  smcspike watch [seconds]   Live 1 Hz table (default until Ctrl-C; optional duration)
  smcspike list              Enumerate every SMC key with type and decoded value
  smcspike mode              Show fan mode key name and current mode
  sudo smcspike force <rpm> [--fan N] [--hold] [--seconds N]
                             Force fan to RPM (clamped to [min,max]); restores
                             automatic control when done unless --hold
  sudo smcspike auto         Restore automatic fan control (always safe)
  sudo smcspike diag         Try each fan-control strategy, report what works
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func makeSMC() -> SMCClient {
    do { return try SMCClient() } catch { fail("SMC connection failed: \(error)") }
}

func rpmString(_ value: Float) -> String {
    String(format: "%5.0f", value)
}

/// `String(format:)` silently ignores field widths on `%@` (CFString honours
/// them for %s/%d/%f but not for objects), so columns must be padded here.
func col(_ s: String, _ width: Int) -> String {
    s.count >= width
        ? String(s.prefix(width))
        : s.padding(toLength: width, withPad: " ", startingAt: 0)
}

/// Above this, holding a manual fan target is never worth the risk.
let thermalLimitC = 95.0

func printFans(_ fanControl: FanControl) {
    do {
        let fans = try fanControl.allFans()
        print("FNum = \(fans.count)")
        for fan in fans {
            let mode = fan.mode.map(String.init(describing:)) ?? "unknown(\(fan.modeRaw.map(String.init) ?? "-"))"
            print(
                "Fan \(fan.id): actual \(rpmString(fan.actualRPM)) RPM   " +
                "min \(rpmString(fan.minRPM))   max \(rpmString(fan.maxRPM))   " +
                "target \(rpmString(fan.targetRPM))   mode \(mode) [key \(fanControl.modeKey(fan: fan.id))]"
            )
        }
    } catch {
        fail("Fan read failed: \(error)")
    }
}

func smcTemps(_ smc: SMCClient) -> [(key: String, name: String, celsius: Float)] {
    guard let keys = try? smc.allKeys() else { return [] }
    var result: [(String, String, Float)] = []
    for key in keys where key.hasPrefix("T") {
        guard let (type, bytes) = try? smc.readBytes(key) else { continue }
        let celsius: Float?
        switch type {
        case SMCDataType.flt: celsius = SMCDecode.float(bytes)
        case SMCDataType.sp78: celsius = SMCDecode.sp78(bytes)
        default: celsius = nil
        }
        if let c = celsius, c > 0, c < 110 {
            result.append((key, M1SensorNames.name(for: key), c))
        }
    }
    return result.sorted { $0.0 < $1.0 }
}

func printTemps(_ smc: SMCClient) {
    let smcReadings = smcTemps(smc)
    print("── SMC temperature keys (\(smcReadings.count)) ──")
    for r in smcReadings {
        print(String(format: "  %@  %@ %6.1f °C", r.key, col(r.name, 16), r.celsius))
    }

    let hidReadings = HIDSensorReader()?.readAll() ?? []
    print("\n── HID named sensors (\(hidReadings.count)) ──")
    for r in hidReadings {
        print(String(format: "  %@ %6.1f °C", col(r.name, 28), r.celsius))
    }
    if hidReadings.isEmpty {
        print("  (none — HID route unavailable?)")
    }
}

func hottest(_ smc: SMCClient) -> (name: String, celsius: Double)? {
    // Calibration sensors (PMU tcal) hold a constant value and would otherwise
    // always win a naive max().
    let hid = (HIDSensorReader()?.readAll() ?? []).filter(\.isLiveTemperature)
    if let top = hid.max(by: { $0.celsius < $1.celsius }) {
        return (top.name, top.celsius)
    }
    let fromSMC = smcTemps(smc)
    return fromSMC.max { $0.celsius < $1.celsius }.map { ($0.name, Double($0.celsius)) }
}

func watch(_ smc: SMCClient, _ fanControl: FanControl, seconds: Int?) {
    print("time      hottest sensor                    temp     fan RPM  target  mode")
    var elapsed = 0
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    while seconds == nil || elapsed < seconds! {
        let hot = hottest(smc)
        let fan = try? fanControl.telemetry(fan: 0)
        let modeStr = fan?.mode.map(String.init(describing:)) ?? "?"
        print(String(
            format: "%@  %@ %6.1f °C  %6.0f  %6.0f  %@",
            formatter.string(from: Date()),
            col(hot?.name ?? "-", 30),
            hot?.celsius ?? 0,
            fan?.actualRPM ?? 0,
            fan?.targetRPM ?? 0,
            modeStr
        ))
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1.0)
        elapsed += 1
    }
}

func listKeys(_ smc: SMCClient) {
    do {
        let keys = try smc.allKeys()
        print("#KEY = \(keys.count)")
        for key in keys {
            guard let (type, bytes) = try? smc.readBytes(key) else {
                print("  \(key)  <unreadable>")
                continue
            }
            let decoded = SMCDecode.describe(type: type, bytes: bytes)
            print("  \(key)  [\(type)]  \(decoded)")
        }
    } catch {
        fail("Key enumeration failed: \(error)")
    }
}

// MARK: - Safety helpers

/// Another fan app holding forced mode will fight us over F0Tg — and its
/// forced state also makes our unlock path look like a no-op. Warn loudly.
func warnAboutCompetingFanApps() {
    let suspects = ["Macs Fan Control", "TG Pro", "smcFanControl", "Stats", "ThermalForge"]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-Axo", "comm"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let processes = String(decoding: data, as: UTF8.self)

    let running = suspects.filter { processes.contains($0) }
    guard !running.isEmpty else { return }
    print("""
    ⚠️  WARNING: \(running.joined(separator: ", ")) appears to be running.
        It may already hold the fan in forced mode and will keep rewriting the
        target, fighting this tool. Quit it before trusting these results.

    """)
}

/// Set when a terminating signal arrives. The main loop polls this and performs
/// the restore itself — SMCClient is not thread-safe, so the signal source must
/// never touch it directly.
let interrupted = ManagedAtomicFlag()

final class ManagedAtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Signal sources must outlive the function that creates them.
var signalSources: [DispatchSourceSignal] = []

/// Arms interrupt handling so an interrupted force run still hands the fan back
/// to macOS. Runs on a background queue because the main thread is busy in the
/// sample loop and would never drain the main queue.
/// SIGHUP and SIGQUIT are covered too: without them, closing the terminal or
/// pressing Ctrl-\ would kill the process outright with the fan still forced.
/// (SIGKILL remains uncatchable — that is why the shipping daemon gets a lease
/// timer rather than relying on signal handling.)
func installRestoreOnSignal() {
    let queue = DispatchQueue(label: "smcspike.signals")
    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler {
            interrupted.set()
            // The handler runs on a dispatch queue, not in async-signal
            // context, so printing here is legal — and the operator needs to
            // see that the interrupt landed rather than assume a hang.
            print("\ninterrupt received — finishing the current SMC step, then restoring automatic control...")
            fflush(stdout)
        }
        source.resume()
        signalSources.append(source)
    }
}

/// Returns a reason string when the machine is too hot to hold a manual target.
/// Missing sensors count as unsafe: a forced fan with no thermal visibility is
/// exactly the state a kill-switch exists to prevent.
func thermalAbortReason(_ smc: SMCClient) -> String? {
    guard let hot = hottest(smc) else {
        return "no temperature sensors readable"
    }
    if hot.celsius >= thermalLimitC {
        return String(format: "%@ at %.1f °C (limit %.0f °C)", hot.name, hot.celsius, thermalLimitC)
    }
    return nil
}

/// Hands the fans back and confirms it actually took, reporting any that are
/// still stuck forced. Returns true if macOS is back in control.
@discardableResult
func restoreAndVerify(_ fanControl: FanControl) -> Bool {
    do {
        try fanControl.restoreAutomatic { print("  \($0)") }
    } catch {
        FileHandle.standardError.write(Data("  restore write failed: \(error)\n".utf8))
    }
    let stuck = fanControl.fansStillForced()
    if stuck.isEmpty {
        print("verified: macOS has fan control back")
        return true
    }
    FileHandle.standardError.write(Data("""
    ⚠️  FAN(S) STILL FORCED: \(stuck.map(String.init).joined(separator: ", "))
        The machine is not under automatic thermal management.
        Retry `sudo smcspike auto`; if that fails, sleep or reboot restores it.

    """.utf8))
    return false
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}

let smc = makeSMC()
let fanControl = FanControl(smc: smc)

switch command {
case "fans":
    printFans(fanControl)

case "temps":
    printTemps(smc)

case "watch":
    let seconds = args.count > 1 ? Int(args[1]) : nil
    watch(smc, fanControl, seconds: seconds)

case "list":
    listKeys(smc)

case "mode":
    let key = fanControl.modeKey(fan: 0)
    let mode = (try? fanControl.currentMode(fan: 0)).flatMap { $0 }
    print("mode key: \(key)   current mode: \(mode.map(String.init(describing:)) ?? "unknown")")

case "force":
    guard args.count > 1, let rpm = Double(args[1]) else {
        fail("usage: sudo smcspike force <rpm> [--fan N] [--hold] [--seconds N]")
    }
    var fan = 0
    if let flagIndex = args.firstIndex(of: "--fan"), args.count > flagIndex + 1,
       let n = Int(args[flagIndex + 1]) {
        fan = n
    }
    let hold = args.contains("--hold")
    var duration = 15
    if let flagIndex = args.firstIndex(of: "--seconds"), args.count > flagIndex + 1,
       let n = Int(args[flagIndex + 1]) {
        duration = max(1, n)
    }

    warnAboutCompetingFanApps()

    // Interrupting a forced fan must never strand the machine without thermal
    // management. The loop below polls `interrupted` and restores before exit.
    installRestoreOnSignal()

    // Never pin the fan to a manual target on an already-hot machine.
    if let reason = thermalAbortReason(smc) {
        fail("refusing to force: \(reason)")
    }

    do {
        let before = try fanControl.telemetry(fan: fan)
        print("before: actual \(rpmString(before.actualRPM)) target \(rpmString(before.targetRPM)) mode \(before.mode?.description ?? "?")")

        let result = try fanControl.setTargetRPM(
            fan: fan,
            rpm: rpm,
            isCancelled: { interrupted.isSet }
        ) { print("  [unlock] \($0)") }

        print("forced fan \(fan) to \(rpmString(result.applied)) RPM" +
              (result.clamped ? " (clamped from \(Int(rpm)))" : "") +
              " via \(result.unlockPath)")
        print("watching for \(duration) s (Ctrl-C restores auto) — you should hear the fan...")
        print("  \(col("hottest sensor", 30)) temp     actual  target  mode")

        var abortReason: String?
        for _ in 0..<duration {
            Thread.sleep(forTimeInterval: 1.0)
            if interrupted.isSet {
                abortReason = "interrupted"
                break
            }
            let t = try fanControl.telemetry(fan: fan)
            let hot = hottest(smc)
            print(String(
                format: "  %@ %6.1f °C  %6.0f  %6.0f  %@",
                col(hot?.name ?? "-", 30),
                hot?.celsius ?? 0,
                t.actualRPM,
                t.targetRPM,
                t.mode?.description ?? "?"
            ))
            // Thermal kill-switch overrides --hold: holding a manual target
            // through a thermal event is the one thing this must never do.
            if let reason = thermalAbortReason(smc) {
                abortReason = "THERMAL LIMIT — \(reason)"
                break
            }
        }

        if let reason = abortReason {
            print("\n\(reason); restoring automatic control...")
            exit(restoreAndVerify(fanControl) ? 0 : 2)
        } else if hold {
            print("\n--hold given: fan REMAINS FORCED. Run `sudo smcspike auto` to restore automatic control.")
        } else {
            print("\nrestoring automatic control...")
            exit(restoreAndVerify(fanControl) ? 0 : 2)
        }
    } catch SMCError.notPrivileged {
        // setTargetRPM rolls back its own partial state, but the fan may have
        // been forced by something else — verify before claiming safety.
        FileHandle.standardError.write(Data("SMC writes require root: rerun with sudo\n".utf8))
        exit(restoreAndVerify(fanControl) ? 1 : 2)
    } catch {
        // Never leave the fan forced because of an error partway through.
        FileHandle.standardError.write(Data("force failed: \(error)\n".utf8))
        print("restoring automatic control as a precaution...")
        exit(restoreAndVerify(fanControl) ? 1 : 2)
    }

case "auto":
    if geteuid() != 0 {
        fail("SMC writes require root: rerun with sudo")
    }
    exit(restoreAndVerify(fanControl) ? 0 : 2)

case "diag":
    // Tries each known strategy for taking fan control on this hardware and
    // reports which one works, so an unknown machine costs one sudo run
    // instead of a guessing game. Always restores automatic control.
    if geteuid() != 0 {
        fail("SMC writes require root: rerun with sudo")
    }
    warnAboutCompetingFanApps()
    if let reason = thermalAbortReason(smc) {
        fail("refusing to run diagnostics: \(reason)")
    }
    installRestoreOnSignal()

    let probeRPM: Float = 3000
    let fKeys = ["F0Md", "F0Tg", "F0Ac", "F0St", "FOff", "FOFC", "FRmp", "F0Sf", "F0Dc"]

    func dumpState(_ label: String) {
        let parts = fKeys.compactMap { key -> String? in
            guard let (type, bytes) = try? smc.readBytes(key) else { return nil }
            return "\(key)=\(SMCDecode.describe(type: type, bytes: bytes))"
        }
        print("  [\(label)] \(parts.joined(separator: "  "))")
    }

    func modeStuck() -> Bool {
        (try? fanControl.currentMode(fan: 0)) == .forced
    }

    print("── baseline ──")
    dumpState("start")

    var winner: String?

    // Strategy A: stage the target first, then switch mode. Firmware may
    // refuse forced mode while the target reads 0.
    print("\n── strategy A: target-then-mode ──")
    do {
        try smc.writeFloat("F0Tg", probeRPM)
        dumpState("after F0Tg")
        try smc.writeUInt8("F0Md", 1)
        usleep(300_000)
        dumpState("after F0Md=1")
        if modeStuck() { winner = "A: target-then-mode" }
    } catch {
        print("  failed: \(error)")
    }

    // Strategy B: clear the fan-off latch first. FOff=1 on this machine while
    // the fan idles at 0 RPM, which may be what blocks the mode change.
    if winner == nil, smc.keyExists("FOff") {
        print("\n── strategy B: FOff=0, then target, then mode ──")
        do {
            try smc.writeUInt8("FOff", 0)
            usleep(200_000)
            dumpState("after FOff=0")
            try smc.writeFloat("F0Tg", probeRPM)
            try smc.writeUInt8("F0Md", 1)
            usleep(300_000)
            dumpState("after F0Md=1")
            if modeStuck() { winner = "B: FOff=0 first" }
        } catch {
            print("  failed: \(error)")
        }
    }

    // Strategy C: hold the mode write down — some firmware reverts once and
    // then accepts a persistent re-assertion.
    if winner == nil {
        print("\n── strategy C: repeated mode assertion (3 s) ──")
        do {
            try smc.writeFloat("F0Tg", probeRPM)
            for _ in 0..<30 where !modeStuck() {
                try? smc.writeUInt8("F0Md", 1, attempts: 1)
                usleep(100_000)
            }
            dumpState("after repeat")
            if modeStuck() { winner = "C: repeated assertion" }
        } catch {
            print("  failed: \(error)")
        }
    }

    if let winner {
        print("\n✅ WORKING STRATEGY — \(winner)")
        print("   observing the fan for 8 s...")
        for _ in 0..<8 where !interrupted.isSet {
            Thread.sleep(forTimeInterval: 1.0)
            if let t = try? fanControl.telemetry(fan: 0) {
                print("   actual \(rpmString(t.actualRPM)) RPM   target \(rpmString(t.targetRPM))   mode \(t.mode?.description ?? "?")")
            }
        }
    } else {
        print("\n❌ no strategy worked — F0Md will not hold on this machine")
    }

    print("\n── restoring ──")
    if smc.keyExists("FOff") { try? smc.writeUInt8("FOff", 1) }
    let ok = restoreAndVerify(fanControl)
    dumpState("final")
    exit(ok ? 0 : 2)

default:
    print(usage)
    exit(1)
}
