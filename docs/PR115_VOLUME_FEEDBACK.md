# PR115 — Volume Feedback & Preferences

Base: PR114 Commercial Release Candidate at exact commit `3082e184dab152fffec81c686e22742fc5480092`.

## UX contract

**Preferences & Reference → General → Volume & Feedback** retains the existing software volume-key step choices of 1/16, 1/32, and 1/64. It now has two independent toggles:

- **Show volume in menu bar** (default ON) — adds a dynamic percentage or "Muted" label beside the existing tray icon. Only applicable when App Presence is Menu Bar or Both.
- **Show volume popup** (default OFF) — briefly presents a passive, nonactivating floating indicator after an observed master-volume change. The panel is click-through, does not steal keyboard focus, and dismisses itself after 1.4 seconds or immediately when disabled.

Both derive from the exact existing `AudioIOEngine.masterVolumeConfiguration` observable state, so app volume edits, software volume keys, mute, and monitored hardware-level changes stay in sync. Percent values are clamped, rounded, and shown as a percentage of the master-volume setting; they are **not** SPL or a measurement of a physical amp's knob. Muted remains distinct from 0%.

### macOS and safety boundary

The existing system-defined volume-key monitor uses a **listen-only** public Core Graphics event tap. This enhancement does not replace that monitor, consume hardware events, suppress the macOS volume HUD, synthesize keystrokes, inject Accessibility events, or install any driver/helper/extension. macOS's built-in indicator can still appear, even when blank; the popup preference explicitly discloses this.

The display controller runs on the main actor; no render callback, EQ graph, transport or DSP state is modified by display code. No new permissions or external dependencies. HUD can be enabled with Dock-only presence; the menu-bar toggle retains its saved value but is disabled in Dock-only preferences.

### Persistence

Both settings are saved in UserDefaults and optionally included in the existing schema-1 portable backup preferences. Optional JSON fields preserve decoding and validation of pre-PR115 backup files; missing fields do not override local defaults on restore.

### Evidence and acceptance

Deterministic tests cover boundary rounding, mute semantics, and old backup decoding/new backup round-trip. PR115 CI includes inherited PR114 fail-closed checks, arm64 Debug/Release builds, targeted Product UI tests, and an unsigned build path.

Still requires real Mac verification: live tray readability across light/dark, menu bar crowding, menu panel activation, popup stacking/full-screen positioning, no focus theft, mute state, key repeat at boundaries, keyboard/hardware and UI synchronization, Dock-only behavior and preference persistence. Apple App Store release signing/review and PR112 H01–H08 remain separate and unfulfilled. This does not upgrade RC or physical evidence.

Keep PR115 and PR114 and all ancestors **OPEN / DRAFT / UNMERGED**; do not mutate `main`.

## Hardware-testing installer (PR115)

The PR115 workflow packages its own `Notch-Sixty-1.0.0-build-1-PR115-hardware-test-arm64.dmg` only after unsigned Release compilation and complete cumulative XCTest. The published GitHub Actions artifact also contains a SHA-256 checksum, verified effective sandbox entitlements, and an exact-head manifest.

**System requirements:** Apple Silicon and **macOS 27.0 or later**. If the test machine is on macOS 26, do not attempt to force the installer to run; the deployment target must be deliberately revisited and compatibility tested first.

This is an ad-hoc-signed, nonnotarized **owner-only test build**. It is neither an App Store nor an Apple Developer-ID public release. Download the artifact ZIP from the successful workflow run, unpack the DMG, mount it, and drag the app to Applications. Gatekeeper may reject a nonnotarized downloaded build; prefer a proper signed/notarized test channel when available, and only use macOS's explicit *Open Anyway* UI for a build whose repo/commit and SHA-256 you have independently verified. Do not disable Gatekeeper systemwide.

Do not run external speaker-connected feed-forward ANC tests or infer hardware pass from a successfully installing build. Record PR112 H01–H08 physical evidence independently.
