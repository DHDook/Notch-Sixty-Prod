# Production Transport Validation

This matrix validates the production Core Audio transport implementation before DSP is added.

The application under test is the commercial `NotchSixty` target. Processing is unity transport only.

## Acceptance principles

- selected physical output remains authoritative by stable UID
- Notch Sixty excludes itself from the process tap
- original dry system audio is suppressed while the tap is actively read
- transport remains native-rate; no hidden SRC
- callbacks perform no allocation, blocking locks, logging, UI access, file/network I/O, or async work
- startup may remain armed indefinitely while the source is silent; silence is not a transport failure
- the realtime output callback opens the startup gate when enough captured audio arrives and applies a short fade-in
- steady-state underrun/overrun counters must not grow
- output recovery never silently falls back and does not fail merely because the source is paused
- normal Stop/Quit and sleep teardown use bounded fade-out before stopping output
- force-quit/crash must not leave system audio permanently muted

## Manual matrix

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| T-01 | Launch and enumerate outputs | Physical outputs appear; no private tap/aggregate is shown as a user-selectable product output | Passed |
| T-02 | Start selected output with active audio | State reaches `running`; gate opens automatically; tap/output rates match; session underruns remain zero | Passed at 384 kHz |
| T-03 | Self exclusion | Notch Sixty does not recursively capture its own rendered output | Passed |
| T-04 | Dry suppression | No doubled dry+processed signal while running; Stop restores normal system playback | Passed |
| T-05 | Start selected output while source is silent | State reaches `running`; gate remains `armed`; no fatal timeout; first later audio opens the gate and fades in | Pending PR #11 validation |
| T-06 | 44.1/48/96/384 kHz cold start | Native tap/output rates match and playback is clean | Partial |
| T-07 | High-rate steady state | Device-supported rates through 384 kHz are accepted without a transport whitelist | 384 kHz passed |
| T-08 | Live rate change | Rebuilds automatically and returns to `running`; no underrun/overrun growth | Passed — five live rebuilds |
| T-09 | Selected output unplug/replug while source paused | State remains recoverable; same UID resumes automatically; no fallback; playback resumes when source restarts | Pending PR #11 validation |
| T-10 | Change macOS default output | Notch Sixty remains pinned to its explicitly selected physical output | Pending |
| T-11 | Sleep/wake with paused source | Graceful fade on sleep; transport resumes/arms after wake; later playback resumes through app | Pending PR #11 validation |
| T-12 | Stop/Start repeatedly, including while silent | Restarts cleanly; session counters reset only on explicit new Start | Pending PR #11 validation |
| T-13 | Normal Quit while active | Short fade prevents abrupt termination artifact; system audio restores | Pending |
| T-14 | Force Quit while active | System audio recovers without manual Core Audio reset; note any brief termination transient | Pending |
| T-15 | 30-minute soak | No sustained underrun/overrun growth; no audio artifacts | Pending |
| T-16 | 2-hour soak | Stable CPU/memory and transport counters; no runaway bridge drift | Pending |
| T-17 | Permission first run | macOS system-audio capture permission flow is understandable; after required permission/relaunch, Start works | Passed |

## Hardware evidence to date

At 384 kHz on a Schiit Modi 5 with a 512-frame physical buffer:

- startup gate activation threshold: 1,024 frames
- steady bridge queue: typically 512–1,024 frames (about 1.33–2.67 ms)
- steady-state underruns: 0
- steady-state overruns: 0
- five live sample-rate rebuilds completed with audio recovering in under one second each
- an unplug/replug test exposed that the prior startup gate incorrectly required active source audio; recovery attempts failed while the source was paused, then the same build started normally as soon as audio playback resumed
- sleep/wake preserved transport functionality, but a brief sleep-entry transient was observed; PR #11 changes sleep teardown to use the normal fade-out path

The idle-source finding changes the intended startup model: transport creation succeeds independently of program material. The gate remains armed for as long as necessary and opens asynchronously on the first captured audio.

## Diagnostic evidence

For hardware tests record:

- macOS build and Mac model
- selected output name + stable UID
- tap/output rates
- startup-gate state (`armed` or `open`), target frames, activation frames
- runtime
- capture/output callback counts
- gated output callbacks/frames
- session captured/delivered frames
- session underrun/overrun frames
- lifetime underrun/overrun frames
- buffered-frame depth / bridge queue milliseconds
- rate rebuild count
- recovery attempts/successes/retry errors
- last error, if any
- subjective artifact notes

## CI versus hardware validation

Xcode 27 CI is authoritative for compilation and deterministic unit tests. It cannot establish that a real DAC, TCC permission transition, sleep/wake cycle, or physical reconnect works. This document is the hardware acceptance gate for the production transport milestone.
