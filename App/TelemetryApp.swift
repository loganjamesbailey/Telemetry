import SwiftUI

@main
struct TelemetryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SensorStore()
    @State private var fanControl = FanControlStore()
    @State private var presets = PresetStore()

    var body: some Scene {
        // .window style is mandatory for live content: the .menu style blocks
        // the run loop while open, so readouts would freeze mid-poll.
        MenuBarExtra {
            PopoverView()
                .environment(store)
                .environment(fanControl)
                .environment(presets)
                .onAppear { store.setCadence(.active) }
                .onDisappear { store.setCadence(.background) }
        } label: {
            // Only Text and Image render in a MenuBarExtra label, and font
            // sizing is OS-controlled — so this is deliberately plain text.
            Text(store.menuBarText)
        }
        .menuBarExtraStyle(.window)

        Window("Telemetry", id: DashboardWindow.id) {
            DashboardWindow()
                .environment(store)
                .environment(fanControl)
                .environment(presets)
                .onAppear {
                    store.setCadence(.active)
                    // An accessory app cannot bring a window properly forward;
                    // become a regular app while the dashboard is open.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    store.setCadence(.background)
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 760, height: 560)
    }

    init() {
        store.start()
        // The curve engine reads temperatures through this seam so the two
        // stores stay decoupled (and the engine is testable without a UI).
        let sensors = store
        fanControl.temperatureProvider = { id in
            sensors.snapshot.reading(id)?.celsius
        }
        fanControl.unitProvider = { sensors.unit }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only until the dashboard is opened.
        NSApp.setActivationPolicy(.accessory)

        // Dev affordance: check both appearances without changing the system
        // setting. TELEMETRY_APPEARANCE=dark|light overrides this app only.
        switch ProcessInfo.processInfo.environment["TELEMETRY_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort immediate release; the daemon's connection-invalidation
        // restore is the guarantee if this never runs (kill -9, crash).
        FanControlStore.shared?.releaseOnQuit()
    }
}
