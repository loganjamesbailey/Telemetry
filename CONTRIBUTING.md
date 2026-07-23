# Contributing

## Build

See the README's install section. `xcodegen generate` after any `project.yml`
change; the `.xcodeproj` is generated and gitignored.

`Scripts/verify-consistency.sh` must pass — it asserts the five strings that
launchd requires to agree (daemon label, plist filename, Mach service name,
BundleProgram path, and the constants in `TelemetryShared/HelperProtocol.swift`).
A mismatch fails as launchd status 78 with no useful diagnostics, which is why
it is checked mechanically.

## Tests

```sh
cd Packages/TelemetryCore && swift test
```

The curve engine (`CurveRuntime`) is deliberately pure — time is an argument,
effects are return values — so every control-loop change must come with tests.
If you change spin-up/spin-down behaviour, add a case to `CurveTests`.

## Safety rules (non-negotiable)

The daemon runs as root and commands cooling hardware. Any PR touching
`Helper/` or `SMCKit` must preserve these invariants:

1. **Every failure path restores.** If a function takes fan control and then
   throws, it must undo what it did before rethrowing. `Ftst`/forced-mode may
   never leak.
2. **The daemon never trusts the client.** RPM clamping happens daemon-side;
   XPC peers are validated by code-signing requirement; the protocol stays
   fan-only — no generic execution, no paths, no shell strings
   (CVE-2025-21606 in Stats is the cautionary tale).
3. **Writes are verified, not assumed.** The SMC returns success for writes
   the firmware silently dropped (check the result byte), and mode changes
   apply asynchronously (~150 ms) — read back after a settle delay.
4. **Restores are verified too** (`fansStillForced()`), and reported honestly
   when they fail.

## Design rules

The aesthetic is "Dieter Rams meets 80s neon", and it is enforced by ratio,
not vibes. PR checklist for any UI change:

- [ ] ~90 % of pixels are neutral surfaces/text; accent colour appears
      **only where it encodes data or state** (≤8 %); glow ≤2 %
- [ ] Temperature is cyan, fan speed is magenta — everywhere, no exceptions
- [ ] No raw hex in views: every colour comes from `Palette`, every font from
      `Typo`, every dimension from `Metrics`
- [ ] Glow only via `neonGlow()` (which self-disables in light mode), and only
      on live readouts, the active chart series, or a state-change pulse —
      never chrome, labels, or resting buttons
- [ ] Numerals are monospaced (`SF Mono` / `.monospacedDigit()`) so values
      don't jitter as they tick
- [ ] Charts: fixed axis domains, `.monotone` interpolation (no overshoot),
      max 4–5 hairline gridlines
- [ ] If a screenshot of your change "looks synthwave" at a glance, the accent
      budget is blown — the ambiance should live in the readouts only

## Hardware variance

Never hard-code sensor keys or fan limits. The reference machine
(MacBookPro17,1) exposes different per-core keys than other M1 variants, has
no `Ftst` key, and enforces none of the documented RPM floors in firmware —
see `docs/hardware-notes.md`. Discovery is dynamic; keep it that way.
