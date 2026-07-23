# Hardware notes

Empirical findings from real machines. These take precedence over the research
dossiers in `docs/research/`, which are compiled from other people's hardware.

## MacBookPro17,1 — MacBook Pro 13" M1, macOS 26.5.2 (reference machine)

### Fan

| Key    | Type   | Value / meaning                      |
| ------ | ------ | ------------------------------------ |
| `FNum` | `ui8`  | 1 (single fan)                       |
| `F0Mn` | `flt ` | 1199 RPM (minimum under forced mode) |
| `F0Mx` | `flt ` | 7199 RPM                             |
| `F0Md` | `ui8`  | mode — 0 automatic, 1 forced         |
| `F0Tg` | `flt ` | target RPM                           |
| `F0Ac` | `flt ` | actual RPM                           |
| `FOff` | `ui8`  | 1 while the fan is idle at 0 RPM     |
| `F0St` | `ui8`  | 3 (observed constant)                |

The mode key is **uppercase `F0Md`**. Lowercase `F0md` does not exist here.

### Findings that contradict the published research

The widely-cited Apple Silicon fan-control research (agoodkind/macos-smc-fan)
was tested on a MacBookPro18,1 (M1 Pro). Three of its conclusions do not hold on
this machine:

1. **There is no `Ftst` key.** The documented "diagnostic mode unlock" is simply
   unavailable. Code must handle its absence rather than assuming a fallback.

2. **Mode changes are asynchronous (~150 ms).** Writing `F0Md=1` returns SMC
   result `0x00` and an *immediate* read-back still reports `0` (automatic).
   Roughly 150–250 ms later the same read reports `1`. This is indistinguishable
   from a silent firmware rejection unless you wait before verifying — it is
   what made the first control attempt look like a hard failure.

3. **`F0Tg` writes are ignored in automatic mode.** Writing a target of 3000 RPM
   while `F0Md=0` leaves `F0Tg` at `0.00`. The firmware owns the target until
   control is handed over, so the target *cannot* be staged before the mode
   switch. Mode and target must be written as a pair, then verified together.

Consequently `restoreAutomatic` must also wait and re-verify: writing `F0Md=0`
and immediately reading it back reports `1` and looks like a failed handback
when the handback in fact succeeded.

### Temperature sensors

111 SMC `T*` keys and 55 named HID sensors are readable without privileges.

- This machine exposes `Tp2a`/`Tp3a`/`Tp4a`-family per-core keys, **not** the
  `Tp01`/`Tp05` family documented for other M1 models. Sensor discovery must be
  dynamic; hard-coded key tables will silently miss cores.
- **`PMU tcal` and `PMU2 tcal` are calibration constants**, pinned at 51.9 °C
  regardless of load. A naive `max()` across all sensors always picks them and
  reports the machine as permanently ~52 °C. Excluded via
  `HIDSensorReading.isLiveTemperature`.
- `gas gauge battery` appears six times with different values (battery pack
  cells, not silicon) — also excluded from thermal aggregates.
- Useful live sensors: `pACC MTR Temp Sensor*` (P-cores, the hottest under
  load), `eACC MTR Temp Sensor*` (E-cores), `SOC MTR Temp Sensor*`,
  `GPU MTR Temp Sensor*`, `PMU tdie*`.

### Thermal behaviour

The fan idles at **0 RPM** under macOS automatic control on a cool machine
(`FOff=1`). Eight concurrent `yes` processes only bring P-cores to ~53 °C, which
is not enough to start the fan — this Mac is genuinely fanless in light use.
That 0 RPM idle is unreachable under forced control (floor is `F0Mn` = 1199),
which is exactly why the hybrid-auto feature has to hand control back rather
than setting a low target.
