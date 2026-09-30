# PR41 — Active Crossover / Speaker Integration

Status: **IMPLEMENTATION COMPLETE — READY FOR FINAL COMBINED PR40 + PR41 CI**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.
Final feature head: `cb6aba710c526606812b64e0aa6cb48ddc160e68`.

The product tree is feature-frozen for the final combined automated gate. Subsequent commits before that gate are documentation-only.

## Completed core
- transactional Playback System ownership for crossover/routing;
- 2–8 persistent physical output routes;
- Full Range / Low / Mid / High / Sub logical buses;
- same-device multichannel transport;
- private multi-device Core Audio Aggregate Device transport;
- explicit reference clock and HAL drift compensation;
- Mains + Sub / Bi-Amp / Tri-Amp physical crossover;
- LR24/LR48 lower and Tri-Amp upper crossover choices;
- Sub gain/polarity/all-pass phase alignment;
- post-shared-DSP speaker-bus derivation;
- driver-safe physical crossover under Global Bypass;
- production route/device/channel/synchronization UI;
- Content Preset and PR40 Room Correction independence.

## Parity disposition

**Parity / improved:** multi-output matrix, multiple devices, speaker buses, Mains+Sub/Bi-Amp/Tri-Amp, lower/upper crossover points, LR24/LR48, Sub controls, physical routing persistence, clock reference/drift compensation, recovery integration, PR40/audition coexistence.

**Superseded:** legacy Software PLL by HAL Aggregate Device drift compensation; known legacy no-op/unfinished optimizer controls are not reproduced.

**Deferred follow-up, not claimed as PR41 parity:** arbitrary per-output EQ/gain/delay/limiting/metering and the larger measurement-assisted optimizer/diagnostic suite. Those should build on PR40 measurement infrastructure plus PR41's stable physical buses in a dedicated speaker-optimization milestone.

## Final gate
The final combined PR40 + PR41 tree must pass full XCTest, retained PR34–PR41 validators, realtime benchmarks, Debug/Release builds, PR40 deployment/audition regressions, Content Preset independence, Global Bypass, Release app build, signing, sandbox validation and DMG creation/upload.

## Physical acceptance
PR40 and PR41 remain draft/unmerged until the combined Mac session validates real Room Correction, ordinary stereo, available same-/multi-device routing, safely connected physical crossover paths, Processed/Reference/Delta, Global Bypass, persistence/relaunch, device recovery and sample-rate rebuilds.
