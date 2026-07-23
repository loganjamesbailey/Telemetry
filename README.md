# Telemetry

Free, open-source fan control and thermal monitoring for Apple Silicon Macs.
Dieter Rams meets 80s neon.

**Status: pre-release, under construction.** Currently at the hardware-spike stage
(`smcspike` CLI). The app, root helper daemon, and widget land in later milestones —
see `docs/` and the research dossiers in `docs/research/`.

## What it will do

- Live temperature + fan telemetry in the menu bar (all SMC and HID sensors, merged)
- User-editable multi-point fan curves driven by any sensor, including virtual
  aggregates (hottest CPU core, SOC average, max of CPU/GPU) — free, unlimited presets
- Zero-RPM **hybrid auto**: below your threshold, control is handed back to macOS so
  the fan can idle silently at 0 RPM; re-acquired automatically under load
- Temperature/RPM history charts
- Safe by construction: a lease-based dead-man's switch in the root helper returns
  fans to Apple-automatic within seconds if anything crashes, plus an independent
  95–100 °C watchdog

## smcspike (milestones 1–2)

A tiny CLI proving hardware access before any app code:

```sh
cd Packages/TelemetryCore
swift run smcspike fans     # fan telemetry (no privileges needed)
swift run smcspike temps    # all temperature sensors, SMC + HID routes
swift run smcspike watch    # live 1 Hz table
swift run smcspike list     # enumerate every SMC key
sudo .build/debug/smcspike force 4000   # forced RPM (root required)
sudo .build/debug/smcspike auto         # restore automatic control
```

## Reference hardware (development machine)

MacBook Pro 13" M1, MacBookPro17,1 — one fan (`FNum=1`), **F0Mn = 1199 RPM,
F0Mx = 7199 RPM**, fan keys `F0Ac/F0Mn/F0Mx/F0Tg` type `flt `, mode key `F0Md`
(uppercase). 111 SMC temperature keys + 55 HID named sensors observed on
macOS 26.5. Note: this machine exposes `Tp2a`-family per-core keys, not the
`Tp01`-family documented for other M1 models — sensor discovery is dynamic for
exactly this reason.

## Requirements

- Apple Silicon Mac, macOS 15+
- Xcode 26+ (`xcodegen` for the app project, later milestones)

## License

MIT — see [LICENSE](LICENSE).
