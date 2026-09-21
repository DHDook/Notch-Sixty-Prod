# Production Transport Validation

This matrix validates the first production Core Audio transport implementation before DSP is added.

The application under test is the commercial `NotchSixty` target. Processing is unity transport only.

## Acceptance principles

- selected physical output remains authoritative by stable UID
- Notch Sixty excludes itself from the process tap
- original dry system audio is suppressed while the tap is actively read
- transport remains native-rate; no hidden SRC
- callbacks perform no allocation, blocking locks, logging, UI access, file/network I/O, or async work
- physical output starts with a realtime gate closed and emits silence without counting underruns
- the gate opens only when enough captured audio exists to consume one hardware buffer while retaining one hardware buffer queued
- after permission has been granted, startup should produce zero session underruns/overruns and settle near one hardware buffer of bridge depth
- normal Stop/Quit tears down tap/aggregate/output in a bounded order
- force-quit/crash must not leave system audio permanently muted

## Manual matrix

| ID | Scenario | Expected result | Status |
|---|---|---|---|
| T-01 | Launch and enumerate outputs | Physical outputs appear; no private tap/aggregate is shown as a user-selectable product output | Pending |
| T-02 | Start selected output at 48 kHz | State reaches `running`; startup gate reports open; audible system audio is routed through Notch Sixty; tap/output rates match; session underruns/overruns remain zero | Pending |
| T-03 | Self exclusion | Notch Sixty does not recursively capture its own rendered output | Pending |
| T-04 | Dry suppression | No doubled dry+processed signal while running; Stop restores normal system playback | Pending |
| T-05 | 44.1 kHz cold start | Native tap/output both report 44.1 kHz and playback is clean | Pending |
| T-06 | 96 kHz cold start | Native tap/output both report 96 kHz and playback is clean | Pending |
| T-07 | High-rate cold start | Test every rate exposed by the selected DAC through 384 kHz; no transport whitelist may reject a device-supported rate | Partial — 384 kHz transport exercised successfully; low-latency gate validation pending |
| T-08 | Live rate change | Change Audio MIDI nominal rate while running; lifecycle enters `reconfiguring`, rebuilds, and returns to `running` | Pending |
| T-09 | Selected output unplug/replug | Lifecycle enters `recoveringOutput`; no silent fallback occurs; same UID resumes automatically after replug | Pending |
| T-10 | Change macOS default output | Notch Sixty remains pinned to its explicitly selected physical output | Pending |
| T-11 | Sleep/wake | Transport tears down for sleep and returns to `running` after wake when the selected device is present | Pending |
| T-12 | Stop/Start repeatedly | Dry path restores on Stop and transport restarts cleanly with no stale buffered audio; session counters reset on an explicit new Start | Pending |
| T-13 | Normal Quit while active | Short fade prevents abrupt termination artifact; system audio restores | Pending |
| T-14 | Force Quit while active | System audio recovers without manual Core Audio reset; note any brief termination transient | Pending |
| T-15 | 30-minute soak | 0 unsupported layouts; no sustained underrun/overrun growth during active playback; bridge depth remains bounded near the hardware-buffer target | Pending |
| T-16 | 2-hour soak | Stable CPU/memory and transport counters; no runaway buffer drift or lifecycle failure | Pending |
| T-17 | Permission first run | macOS system-audio capture permission flow is understandable; after granting required permission/relaunch, Start works | Pending |

## Preliminary hardware evidence

### Initial output-first startup

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

The 512-frame captured/delivered difference exactly matched the reported buffered depth. This established that steady-state transport was stable but startup ordering caused a brief underrun burst.

### Capture-first priming experiment

The next build started capture first and waited for one 512-frame buffer before starting physical output. It eliminated underruns and overruns, but exposed a fixed startup backlog:

- startup prime: ready / 512 frames / 8.25 ms
- session underruns: 0
- session overruns: 0
- buffered frames after startup: approximately 47,616–48,128
- at 384 kHz that queue represented approximately 124–125 ms of bridge latency
- captured minus delivered exactly matched the buffered-frame count
- the backlog remained approximately stable over several minutes rather than growing continuously

This showed that the physical output device took time to begin callbacks while capture was already accumulating audio. The final startup design therefore starts the physical output callback first behind a realtime gate. While gated, output emits silence and does not count underruns. Capture then starts. The output callback opens the gate only after two hardware buffers are queued, consumes one immediately, and should therefore retain approximately one hardware buffer in the bridge.

For a 512-frame Modi 5 buffer at 384 kHz, the target bridge queue is approximately 512 frames / 1.33 ms.

## Diagnostic evidence

For hardware tests record:

- macOS build and Mac model
- selected output name + stable UID
- nominal tap/output rates
- startup-gate state, steady-state target, activation threshold, and wait duration
- gated output callback/frame counts during startup
- runtime
- capture/output callback counts
- session captured/delivered frames
- session underrun/overrun frames
- lifetime underrun/overrun frames
- unsupported buffer-layout count
- buffered-frame depth and computed bridge-queue latency
- rate rebuild count
- recovery attempts/successes/failures
- last error, if any
- subjective artifact notes

## CI versus hardware validation

Xcode 27 CI is authoritative for compilation and deterministic unit tests. It cannot establish that a real DAC, TCC permission transition, sleep/wake cycle, or physical reconnect works. This document is the hardware acceptance gate for the production transport milestone.
