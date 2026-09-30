# PR41 — Active Crossover / Speaker Integration

Status: **IMPLEMENTATION COMPLETE — FINAL COMBINED PR40 + PR41 CI GATE**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

Final feature head: `cb6aba710c526606812b64e0aa6cb48ddc160e68`.
Final direct combined-CI checkpoint: this documentation-only commit.

No product source changed after the focused-green C4 core and production routing UI checkpoints.

## Product model

**Stereo program content is not the same thing as a single physical output device.**

```text
Stereo program / content DSP
            ↓
Shared room / system processing
            ↓
Post-shared-DSP physical speaker-bus crossover
            ↓
Logical Full Range / Low / Mid / High / Sub buses
            ↓
Physical output matrix (2–8 routes, one or more devices)
```

Playback System owns crossover and physical-output routing. Content Presets remain content DSP only.

## Completed implementation

### Ownership / persistence
- transactional Playback System ownership for crossover and output-routing state;
- rollback restores engine + profile state together;
- Content Presets and PR40 Room Correction remain independent;
- transport-sensitive physical edits are idle-only.

### Routing / transport
- stable device UID + physical channel persistence;
- 2–8 physical output routes;
- Full Range / Low / Mid / High / Sub logical buses;
- same-device multichannel output;
- multi-device private Aggregate Device output;
- explicit reference clock device;
- HAL drift compensation for non-reference devices;
- interleaved/planar Core Audio buffer support;
- deterministic silence for unassigned channels;
- lock-free/allocation-free realtime route fan-out;
- archived Software PLL mode rejected as superseded.

### True physical crossover
- Mains + Sub, Bi-Amp, Tri-Amp;
- LR24 / LR48 lower crossover;
- independently selectable LR24 / LR48 upper Tri-Amp crossover;
- validated lower/upper ranges;
- Mains + Sub gain, polarity and all-pass phase alignment;
- speaker buses derived after shared EQ/Room Correction/FIR/dynamics/protection/audition processing;
- ordinary stereo remains unchanged when physical split routing is inactive;
- logical/recombined bass management is suppressed when true split routing is active;
- mandatory physical driver crossover remains active under Global Bypass for split routes.

### Production UI
- physical topology selection;
- lower/upper crossover controls;
- Sub controls;
- physical routing enable;
- Automatic / Aggregate synchronization;
- reference-device selection;
- 2–8 route editor;
- bus/device/channel assignment;
- topology-constrained bus choices;
- idle-only transport mutation safety;
- explicit Software PLL supersession notice.

## Legacy parity disposition

### PARITY / IMPROVED
- 2–8 physical output matrix;
- same-device and multi-device output;
- Full Range / Low / Mid / High / Sub sources;
- Mains + Sub / Bi-Amp / Tri-Amp;
- lower/upper crossover points;
- LR24/LR48 crossover families;
- Sub gain/polarity/phase alignment;
- persistent physical mapping;
- reference-clock selection/drift compensation;
- capability validation/recovery integration;
- Playback System persistence/rollback;
- Room Correction/audition coexistence;
- driver-safe Global Bypass behavior.

### SUPERSEDED
- legacy Software PLL → Core Audio Aggregate Device + HAL drift compensation;
- legacy no-op optimiser slope/delay controls → omitted;
- legacy unimplemented output-EQ pre-ringing blend → omitted;
- ambiguous Apply-All optimiser semantics → not reproduced.

### DELIBERATELY DEFERRED FOLLOW-UP — NOT CLAIMED AS PR41 PARITY
- arbitrary per-output parametric EQ;
- arbitrary per-output gain/polarity/delay beyond Sub controls;
- per-output limiter/metering;
- group-delay analysis/correction UI;
- measured acoustic-summation overlay;
- automatic crossover/EQ optimisation;
- broadband driver time alignment;
- automated polarity/acoustic-centre diagnosis;
- baffle-step / diaphragm-resonance recommendation tools;
- automated combined-system verification.

These belong in a later speaker-optimization milestone reusing PR40 measurement infrastructure and PR41’s stable output buses.

## Automated evidence before final gate
- C1 combined gate: green;
- C2a combined gate: green;
- C2b combined gate: green;
- C3 focused Aggregate Device gate: green;
- C4 focused Swift/XCTest + physical speaker-bus IOProc gate: green at `9a42d8c0...`;
- production routing UI focused Xcode/XCTest gate: green at `cb6aba71...`.

## Final automated acceptance gate
The final combined PR40 + PR41 tree must pass full XCTest, retained PR34–PR41 validators, realtime benchmarks, Debug and Release Performance builds, PR40 deployment/audition regressions, Content Preset independence, Global Bypass, Release app build, ad-hoc signing, sandbox validation, and DMG creation/upload.

## Combined hands-on Mac acceptance
PR40 and PR41 intentionally share one final physical acceptance session covering real Room Correction, ordinary stereo playback, available same-device/multi-device output hardware, physical crossover routing only on safely connected drivers/amplifiers, driver-safe Global Bypass, Processed/Reference/Delta, persistence, device recovery, sample-rate rebuilds, and listening for clicks/dropouts/drift/channel swaps/level jumps/unexpected latency.

PR41 remains draft/unmerged until that physical pass is complete.
