# PR98 — Remote software closure / physical ANC remains gated

## Status

- **Roadmap PR98:** software-complete, tested, **no live ANC**.
- GitHub PR #99 is stacked on roadmap PR97 (GitHub PR #98), itself stacked on PR96. Do not merge into main out of order.
- All seven software slices passed Apple Silicon CI at their recorded commit heads. The final closure commit must also pass CI before final software verification.
- The new source-level closure guard scans all production Swift/C/ObjC files for unexpected references to the native PR98 scheduler, guarded sessions, or offline echo analyzers. It cannot replace independent physical isolation testing.

## Software boundary audit

| Topic | Result | Scope / remaining risk |
|---|---|---|
| Native FIR / deadline | Control-plane metadata | FIR outputs are discarded; no PCM port |
| Audio callback allocation | Preallocated native C SPSC | Not connected to Core Audio; Swift owner is not realtime-safe |
| Producer / consumer lifetime | Explicit single-producer/single-consumer | Stop and destroy only after both cease; concurrent destroy unsupported |
| Output timing | Conservative hypothetical deadline slack | Requires externally cross-calibrated common host seconds |
| Input HAL clock | Rolling qualified sample-clock fit | Does not independently measure physical ADC offset |
| Reference leakage | Independent left/right L1 uncertainty bound | Room, microphone and nonlinear changes can invalidate model |
| Echo decontamination | Held-out offline source-isolated checks | No live echo canceller or adaptive coefficients |
| Output headroom | Individual and combined stereo caps | Diagnostic only, not installed speaker protection |
| Fault shutdown | Terminal stop and revoked metadata | 128-frame fade is a counter, NOT a speaker mute |
| Acceptance | Runbook, OFF/TEST/OFF and fault witnesses | Typed measurements are unverified; no actual seat attenuation |
| Live speaker ANC | Absent | Requires separate hardware-reviewed integration |

## Exit criteria

PR98 is software-complete only after its exact-head portable validators, output-disconnection audit, arm64 macOS application build, targeted XCTest and full regression all pass. This status does NOT satisfy physical commissioning or authorize live ANC.

## PR99 handoff

Roadmap PR99 is **physical ANC verification**. The remotely implementable portion may include analysis of independent multi-position acoustic campaigns and session consistency, reproducibility reports and evidence review. Genuine instrument-calibrated input/output clocks, speaker delay, acoustic attenuation, safe mute/fade and room stability are still hardware-dependent. PR99 must preserve all PR98 speaker-disconnected and false-authorization invariants.
