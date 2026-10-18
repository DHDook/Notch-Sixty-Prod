# PR41 — Active Crossover / Speaker Integration

Status: **IMPLEMENTATION COMPLETE — CLEAN FINAL EXACT-HEAD CI**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.
Final feature head: `cb6aba710c526606812b64e0aa6cb48ddc160e68`.

The full PR40 + PR41 product tree already passed combined CI at `4a7e694d5f2b243e18c772292d732c1733f04ede`. A subsequent housekeeping-only commit removed the last temporary C4 repair script from the PR diff. No product source changed. This documentation-only checkpoint re-runs the full combined gate so the **clean merge candidate itself** has exact-head certification.

## Completed implementation

- transactional Playback System crossover + routing ownership with rollback;
- persistent 2–8 physical output routes;
- Full Range / Low / Mid / High / Sub logical buses;
- same-device multichannel output;
- private multi-device Core Audio Aggregate Device transport;
- explicit reference clock device + HAL drift compensation;
- Mains + Sub / Bi-Amp / Tri-Amp physical crossover;
- LR24/LR48 lower and Tri-Amp upper crossover choices;
- Sub gain/polarity/all-pass phase alignment;
- speaker-bus derivation after shared EQ / Room Correction / FIR / dynamics / protection / audition processing;
- logical/recombined bass management suppression during true split routing to prevent double filtering;
- driver-safe mandatory physical crossover under Global Bypass;
- production physical topology / route / device / channel / synchronization UI;
- Content Preset and PR40 Room Correction independence;
- retained PR41 realtime output-map validator in the normal macOS lane.

## Legacy parity disposition

**Parity / improved:** 2–8 output matrix, same-device + multi-device output, Full Range/Low/Mid/High/Sub buses, Mains+Sub/Bi-Amp/Tri-Amp, lower/upper crossover points, LR24/LR48, Sub controls, persistent physical mapping, reference-clock/drift compensation, recovery integration, PR40/audition coexistence.

**Superseded:** legacy Software PLL by Core Audio Aggregate Device + HAL drift compensation; known legacy no-op/unfinished optimizer controls are not reproduced.

**Deferred follow-up, not claimed as PR41 parity:** arbitrary per-output EQ/gain/delay/limiting/metering and the larger measurement-assisted optimizer/diagnostic suite. Those should reuse PR40 measurement infrastructure plus PR41's stable physical speaker buses in a dedicated speaker-optimization milestone.

## Final clean automated gate

The exact cleaned PR40 + PR41 tree must pass full XCTest, retained PR34–PR41 validators, realtime benchmarks, Debug build, Release Performance build, PR40 persistence/deployment/audition regressions, Content Preset independence, Global Bypass, Release app build, ad-hoc signing, sandbox validation and DMG creation/upload.

## Physical acceptance

PR40 and PR41 remain draft/unmerged until one combined Mac session validates real Room Correction, ordinary stereo, available same-/multi-device routing, safely connected physical crossover paths, Processed/Reference/Delta, driver-safe Global Bypass, persistence/relaunch, device recovery and sample-rate rebuilds.
