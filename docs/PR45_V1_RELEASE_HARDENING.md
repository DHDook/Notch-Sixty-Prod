# PR45 — v1 Release Hardening

Status: **IMPLEMENTED — EXACT-HEAD SOFTWARE VALIDATION REQUIRED**

PR45 is intentionally a release-hardening slice, not another DSP expansion. It is stacked on PR44 and preserves the PR40–PR44 audio/DSP behavior while removing internal development surfaces from Release builds and tightening the product shell for a v1.0 release candidate.

## Scope

### 1. Engineering UI is DEBUG-only

The retained PR27/PR28/PR30/PR31 engineering validation views remain useful for development and hardware acceptance, but they are not part of the customer-facing product.

PR45 therefore:

- compiles `ContentView.swift` only under `#if DEBUG`;
- compiles the retained engineering validation views only under `#if DEBUG`;
- removes the Engineering Validation toolbar entry point from Release builds;
- removes the Engineering Validation scene from Release builds.

Debug builds retain all of those surfaces for future regression work.

### 2. Launch at Login

The app Settings / preferences UI—the same surface that contains **Appearance** and **App Presence (Dock / Menu Bar / Both)**—exposes **Launch at Login** using Apple's `SMAppService.mainApp` API. The compact tray dropdown intentionally does not duplicate this preference.

Contract:

- default behavior remains opt-in/off unless the user explicitly enables it;
- the app reports whether login-item registration is enabled, requires System Settings approval, is off, or is unavailable;
- launch-at-login does **not** automatically start audio processing;
- v1.0 keeps Start Processing as an explicit user action.

This is deliberately narrower than an automatic-processing-on-login feature so startup cannot unexpectedly claim an audio path or begin processing before the user has validated the selected Playback System.

### 3. Permissions guidance

The existing privacy usage strings and Room Correction microphone permission flow remain authoritative. PR45 adds concise Settings guidance distinguishing:

- macOS system-audio capture permission used for normal processing; and
- microphone permission requested only when Room Correction measurement is intentionally started.

The system-audio guidance also describes the denied/no-signal recovery path: grant access under Privacy & Security and relaunch the app when macOS requires it.

### 4. Copy Diagnostics

Settings provides **Copy Diagnostics** for support and first-release troubleshooting.

The report includes product/runtime metadata such as:

- app version and build;
- macOS version and architecture;
- audio lifecycle state;
- selected output name, stable UID, and nominal sample rate;
- selected Content Preset and Playback System;
- Global Bypass and EQ phase state;
- enabled EQ-band count;
- bass-management and Room Correction state;
- current compiled DSP latency when available.

The report does **not** contain captured system audio, microphone audio, room-measurement samples, or user media.

### 5. Repository/release metadata

The repository status describes v1.0 release-candidate hardening rather than the old bootstrap phase. The product boundary is updated to match the current architecture: source/program material remains stereo while the speaker-integration layer may fan out to 2–8 physical outputs for mains/sub and active bi-/tri-amp systems.

The manually-triggered `Release DMG (Manual)` workflow is carried into the stacked PR45 tree so the final release candidate can be built from the exact cumulative revision. It records version/build/revision, validates the arm64 sandboxed Release app, produces a versioned DMG, computes SHA-256, and uploads both DMG and checksum. Production Developer-ID/App-Store signing/notarization remains a separate release credential step.

## v1 feature boundary

PR45 adds no new DSP algorithm. The only new daily-use convenience is Launch at Login, plus the support-oriented diagnostics action.

The following remain intentionally post-1.0 unless independently justified and validated:

- automatic processing at login;
- global keyboard shortcuts beyond existing volume-key integration;
- rules/automation for preset switching;
- headphone profiles, AutoEQ/headphone targets, crossfeed/HRTF/spatial-headphone processing;
- surround/Atmos/object-audio semantic program mixing;
- broader arbitrary multichannel program material;
- in-app updater for the App Store build.

## Remaining physical/manual acceptance

Before a v1.0 release candidate is promoted, perform the combined PR40–PR45 real-Mac acceptance plus the following release-specific checks:

1. clean-account / clean-machine first launch;
2. system-audio capture permission allow, deny, no-signal, Settings recovery, and OS-required relaunch;
3. Room Correction microphone allow/deny and Settings recovery;
4. corrupted/truncated profile archive recovery;
5. stale/missing output UID and disconnected Playback System recovery;
6. missing/corrupted Room Correction project-sidecar recovery without damaging deployed correction state;
7. Dock / Menu Bar / Both appearance modes across relaunch;
8. Launch at Login enable/disable and any System Settings approval flow from the app Settings / preferences UI;
9. verify login launch does not begin processing automatically;
10. Copy Diagnostics accuracy and privacy boundary;
11. VoiceOver labels, keyboard traversal, control focus, light/dark appearance, and reduced-motion sanity;
12. normal Cmd-Q and menu-bar Quit teardown;
13. Stop/Start loops, sample-rate changes, sleep/wake, output unplug/replug, and recovery;
14. final factory-preset listening smoke and PR40–PR43 hardware/acoustic acceptance;
15. final app-icon appearance in Finder, Dock, Settings/sidebar, and packaged DMG;
16. final signing/notarization or Mac App Store archive/TestFlight/App Review flow when release credentials are introduced.

## Release-candidate discipline

For each RC:

- increment `CURRENT_PROJECT_VERSION`;
- build from a frozen commit SHA;
- retain the exact SHA and DMG SHA-256;
- retain crash-symbol/debug artifacts needed to diagnose a release;
- do not tag `v1.0.0` until the exact candidate passes the acceptance matrix above.

The expected stacked merge order is PR40 → PR41 → PR42 → PR43 → PR44 → PR45.
