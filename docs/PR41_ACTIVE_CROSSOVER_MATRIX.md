# PR41 — Active Crossover / Speaker Integration

Status: **IMPLEMENTATION COMPLETE — FINAL COMBINED PR40 + PR41 CI RUNNING**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.
Final feature head: `cb6aba710c526606812b64e0aa6cb48ddc160e68`.

This documentation-only checkpoint triggers the repository's ordinary `main`-targeted workflows against the complete combined PR40 + PR41 source tree. PR41 will be retargeted back to `pr40-room-correction-production-workflow` after the exact-head Hardware/macOS lanes finish.

## Completed implementation

- transactional Playback System crossover + routing ownership with rollback;
- 2–8 persistent physical output routes;
- Full Range / Low / Mid / High / Sub logical buses;
- same-device multichannel output;
- private multi-device Core Audio Aggregate Device transport;
- explicit reference clock device + HAL drift compensation;
- Mains + Sub / Bi-Amp / Tri-Amp physical crossover;
- LR24/LR48 lower and Tri-Amp upper crossover choices;
- Sub gain/polarity/all-pass phase alignment;
- speaker-bus derivation after shared EQ / Room Correction / FIR / dynamics / protection / audition processing;
- driver-safe mandatory physical crossover under Global Bypass;
- production physical topology / routing / device / channel / synchronization UI;
- Content Preset and PR40 Room Correction independence.

## Legacy parity disposition

**Parity / improved:** multi-output matrix, same-device + multi-device output, Full Range/Low/Mid/High/Sub buses, Mains+Sub/Bi-Amp/Tri-Amp, lower/upper crossover points, LR24/LR48, Sub controls, persistence, reference-clock/drift compensation, recovery integration, PR40/audition coexistence.

**Superseded:** legacy Software PLL by Core Audio Aggregate Device + HAL drift compensation; known legacy no-op/unfinished optimizer controls are not reproduced.

**Deferred follow-up, not claimed as PR41 parity:** arbitrary per-output EQ/gain/delay/limiting/metering and the larger measurement-assisted optimizer/diagnostic suite. Those should reuse PR40 measurement infrastructure plus PR41's stable physical buses in a dedicated speaker-optimization milestone.

## Automated evidence before this final gate

- C1 combined gate: green;
- C2a combined gate: green;
- C2b combined gate: green;
- C3 focused Aggregate Device gate: green;
- C4 focused Swift/XCTest + physical speaker-bus IOProc gate: green at `9a42d8c0...`;
- production routing UI focused Xcode/XCTest gate: green at `cb6aba71...`.

## Final combined automated gate

The exact combined PR40 + PR41 tree must pass full XCTest, retained PR34–PR41 validators, realtime benchmarks, Debug build, Release Performance build, PR40 persistence/deployment/audition regressions, Content Preset independence, Global Bypass, Release app build, ad-hoc signing, sandbox validation and DMG creation/upload.

## Physical acceptance

PR40 and PR41 remain draft/unmerged until one combined Mac session validates real Room Correction, ordinary stereo, available same-/multi-device routing, safely connected physical crossover paths, Processed/Reference/Delta, driver-safe Global Bypass, persistence/relaunch, device recovery and sample-rate rebuilds.
