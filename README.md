# Telemetry

Free, open-source fan control and thermal monitoring for Apple Silicon Macs.
Dieter Rams meets 80s neon.

Everything Macs Fan Control Pro charges for — and several things no fan app
ships at any price — free and MIT licensed.

## Features

- **Live menu bar readout** — temperature and fan RPM, one second cadence,
  near-zero energy cost (a thermal monitor that heats your machine is
  self-defeating)
- **Multi-point fan curves** with a draggable editor: bind a curve to any
  sensor, including virtual aggregates (hottest CPU core, SOC average, system
  hottest). Unlimited named presets
- **Zero-RPM hybrid auto** — below your threshold, the curve hands control
  back to macOS so the fan can idle at true 0 RPM (physically impossible while
  holding forced control, which floors at the firmware minimum); control is
  re-acquired automatically under load
- **History charts** — temperature and RPM, 10 min / 1 h / 24 h, peak-honest
  downsampling
- **Desktop widget** — small and medium, with a 30-minute trend
- **47+ sensors** on M1-class hardware via both the SMC and the named-HID
  routes, discovered dynamically (no hard-coded key tables)

### Safe by construction

Fan forcing runs through a ~100 KB root daemon that treats the app as an
unreliable client:

- a **lease-based dead-man's switch**: if the app stops renewing (crash, hang,
  `kill -9`), fans return to macOS automatic control within seconds
- restore-to-auto on disconnect, on system sleep, and on every terminating
  signal
- an **independent thermal watchdog** while forced: ≥95 °C overrides your
  target to maximum, ≥100 °C (or losing sensor visibility) releases to
  automatic
- XPC locked by code-signing requirement in both directions; the protocol is
  fan-only — no generic command execution
- restores are **verified against the hardware**, never assumed

Sleep and reboot always return the fans to macOS. Nothing persists that could
strand the machine unmanaged.

## Install (build from source)

Building from source is the free distribution tier — your own (free) Apple
Development certificate signs the app and daemon, which also satisfies
SMAppService's same-identity requirement.

Requirements: Apple Silicon Mac, macOS 15+, Xcode 16+, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/loganjamesbailey/Telemetry.git
cd Telemetry
cp Config/Local.xcconfig.template Config/Local.xcconfig
# Set DEVELOPMENT_TEAM in Config/Local.xcconfig to your Team ID — find it with:
#   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
# (the OU= field; a free Apple ID's Personal Team works)
./Scripts/install-local.sh
open /Applications/Telemetry.app
```

First run: the app is a full read-only monitor immediately. To enable fan
control, click **Install helper…** in the popover's FAN section and approve
Telemetry in **System Settings → Login Items & Extensions** (one-time,
admin authentication).

To remove everything: **Settings → Uninstall helper**, then delete the app.
The daemon lives inside the app bundle — there are no stray files.

## The spike CLI

`smcspike` is the hardware-verification tool the app was built on, kept
in-tree as a debugging aid (and the seed of a future `telemetryctl`):

```sh
cd Packages/TelemetryCore
swift run smcspike fans     # fan telemetry (no privileges needed)
swift run smcspike temps    # all temperature sensors, SMC + HID routes
swift run smcspike watch    # live 1 Hz table
swift run smcspike list    # enumerate every SMC key — attach this to bug reports
sudo .build/debug/smcspike force 4000   # forced RPM (root; auto-restores after 15 s)
sudo .build/debug/smcspike auto         # restore automatic control
```

## Hardware notes

Development machine: MacBook Pro 13" M1 (MacBookPro17,1), macOS 26.5. Measured
behaviour that contradicts published Apple Silicon fan-control research is
documented in [docs/hardware-notes.md](docs/hardware-notes.md) — including
asynchronous fan-mode application (~150 ms), target writes being ignored in
automatic mode, and calibration sensors (`PMU tcal`) that masquerade as
live temperatures. The research dossiers the project was planned from are in
[docs/research/](docs/research/).

Other machines: sensor and fan-key discovery is fully dynamic. If something
misbehaves on your hardware, open an issue with the output of
`smcspike list` and `smcspike fans`.

## Design

The design language is documented in code:
[DesignTokens.swift](App/Design/DesignTokens.swift). The discipline that keeps
it Rams rather than vaporwave: ~90 % of pixels are neutral surfaces, ≤8 %
accent colour **only where it encodes data** (temperature is always cyan, fan
speed always magenta), ≤2 % glow — and glow is forced off entirely in light
mode, where there is no darkness to emit into.

## License

MIT — see [LICENSE](LICENSE).
