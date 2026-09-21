# Production Transport Validation

This matrix validates the first production Core Audio transport implementation before DSP is added.

The application under test is the commercial `NotchSixty` target. Processing is unity transport only.

## Acceptance principles

- selected physical output remains authoritative by stable UID
- Notch Sixty excludes itself from the process tap
- original dry system audio is suppressed while the tap is actively read
- transport remains native-rate; no hidden SRC
- callbacks perform no allocation, blocking locks, logging, UI access, file/network I/O, or async work
- normal startup primes at least one physical-output buffer before the output IOProc starts
- after permission has been granted, startup should not create persistent session underruns; steady-state underrun/overrun counters must not grow
- normal Stop/Quit tears down tap/aggregate/output in a bounded order
- force-quit/crash must not leave system audio permanently muted

## Manual matrix

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| T-01 | Launch and enumerate outputs | Physical outputs appear; no private tap/aggregate is shown as a user-selectable product output | Pending |
| T-02 | Start selected output at 48 kHz | State reaches `running`; startup prime reports ready; audible system audio is routed through Notch Sixty; tap/output rates match; session underruns remain zero after startup | Pending |
| T-03 | Self exclusion | Notch Sixty does not recursively capture its own rendered output | Pending |
| T-04 | Dry suppression | No doubled dry+processed signal while running; Stop restores normal system playback | Pending |
| T-05 | 44.1 kHz cold start | Native tap/output both report 44.1 kHz and playback is clean | Pending |
| T-06 | 96 kHz cold start | Native tap/output both report 96 kHz and playback is clean | Pending |
| T-07 | High-rate cold start | Test every rate exposed by the selected DAC through 384 kHz; no transport whitelist may reject a device-supported rate | Partial — 384 kHz transport exercised successfully; remaining exposed rates pending |
| T-08 | Live rate change | Change Audio MIDI nominal rate while running; lifecycle enters `reconfiguring`, rebuilds, and returns to `running` | Pending |
| T-09 | Selected output unplug/replug | Lifecycle enters `recoveringOutput`; no silent fallback occurs; same UID resumes automatically after replug | Pending |
| T-10 | Change macOS default output | Notch Sixty remains pinned to its explicitly selected physical output | Pending |
| T-11 | Sleep/wake | Transport tears down for sleep and returns to `running` after wake when the selected device is present | Pending |
| T-12 | Stop/Start repeatedly | Dry path restores on Stop and transport restarts cleanly with no stale buffered audio; session counters reset on an explicit new Start | Pending |
| T-13 | Normal Quit while active | Short fade prevents abrupt termination artifact; system audio restores | Pending |
| T-14 | Force Quit while active | System audio recovers without manual Core Audio reset; note any brief termination transient | Pending |
| T-15 | 30-minute soak | 0 unsupported layouts; no sustained underrun/overrun growth during active playback; no audio artifacts | Pending |
| T-16 | 2-hour soak | Stable CPU/memory and transport counters; no runaway buffer drift or lifecycle failure | Pending |
| T-17 | Permission first run | macOS system-audio capture permission flow is understandable; after granting required permission/relaunch, Start works | Pending |

## Preliminary hardware evidence

On 2026-09-20, the first production-repository hardware build was run through a Schiit Modi 5 at 384 kHz. A roughly ten-minute steady-state sample reported:

- tap rate: 384 kHz
- output rate: 384 kHz
- captured frames: 486,950,912
- delivered frames: 486,950,400
- buffered frames: 512
- overrun frames: 0
- underrun frames: 17,408, all accumulated during startup and unchanged throughout the steady-state observation
- rate rebuilds: 0
- recovery attempts: 0

The 512-frame captured/delivered difference exactly matched the reported buffered depth. This evidence motivated the startup-priming change: capture now starts first, waits for at least one physical-output buffer to be available in the realtime bridge (with a bounded control-thread timeout), then starts physical output at zero gain and fades in.

## Diagnostic evidence

For hardware tests record:

- macOS build and Mac model
- selected output name + stable UID
- nominal tap/output rates
- startup-prime status, target frames, and wait duration
- runtime
- capture/output callback counts
- session captured/delivered frames
- session underrun/overrun frames
- lifetime underrun/overrun frames
- unsupported buffer-layout count
- buffered-frame depth
- rate rebuild count
- recovery attempts/successes/failures
- last error, if any
- subjective artifact notes

## CI versus hardware validation

Xcode 27 CI is authoritative for compilation and deterministic unit tests. It cannot establish that a real DAC, TCC permission transition, sleep/wake cycle, or physical reconnect works. This document is the hardware acceptance gate for the production transport milestone.
