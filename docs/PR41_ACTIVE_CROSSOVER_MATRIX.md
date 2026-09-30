# PR41 — Active Crossover / Speaker Integration

Status: **IMPLEMENTATION COMPLETE — FINAL COMBINED PR40 + PR41 CI GATE**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

Final feature head immediately before this documentation checkpoint: `cb6aba710c526606812b64e0aa6cb48ddc160e68`.

This documentation-only checkpoint exists to make the final automated gate attributable to one direct exact head. No product source changed after the focused-green C4 core and production routing UI checkpoints.

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
- persistence rollback restores both engine and profile state;
- Content Presets remain independent;
- PR40 Room Correction configuration/provenance remains independent;
- route/topology edits requiring transport reconstruction are idle-only.

### Physical routing

- stable device UID + zero-based physical channel persistence;
- 2–8 enabled/named routes;
- Full Range / Low / Mid / High / Sub logical speaker buses;
- source fan-out allowed and duplicate hardware destinations rejected;
- disconnected systems may remain saved, while activation performs strict device/channel/sample-rate validation.

### Same-device multichannel

- immutable same-clock route plans;
- fixed-size lock-free/allocation-free realtime output map;
- interleaved and planar Core Audio output layouts;
- deterministic silence on unassigned physical channels;
- ordinary stereo transport unchanged when physical routing is disabled.

### Multiple physical devices / synchronization

- private Core Audio Aggregate Device transport;
- explicit reference/clock-master device;
- deterministic subdevice ordering;
- HAL drift compensation on non-reference devices;
- aggregate channel mapping back to persistent device/channel routes;
- archived Software PLL mode remains decodable but is rejected as superseded by the HAL aggregate clock domain.

### True physical speaker buses

Supported physical modes:
- Mains + Sub;
- Bi-Amp;
- Tri-Amp.

Supported crossover design:
- LR24 / LR48 lower topology;
- independently selectable LR24 / LR48 upper Tri-Amp topology;
- validated lower/upper crossover ranges through native supported sample rates;
- Mains + Sub gain, polarity and all-pass phase alignment.

Signal-ordering contract:
- shared EQ, Room Correction, FIR, dynamics/protection and audition processing occur before the physical speaker-bus splitter;
- Full Range L/R routes receive the ordinary final processed stereo program;
- Low/Mid/High/Sub buses are derived from that same final shared stereo result;
- logical/recombined bass management is suppressed when a true split physical crossover is active, preventing double filtering;
- mandatory physical speaker crossover remains active for split-driver routes under Global Bypass so a driver route cannot accidentally receive unsafe full-range material.

### Production workflow

The Active Crossover page exposes:
- crossover enable/bypass;
- Stereo/logical-only, Mains + Sub, Bi-Amp and Tri-Amp modes;
- lower and upper crossover settings where applicable;
- Sub gain/polarity/phase alignment;
- logical verification monitor;
- physical route enable;
- Automatic / Aggregate Device synchronization;
- explicit reference device;
- 2–8 route editor;
- logical bus / physical device / physical channel assignment;
- route enable/add/delete;
- topology-constrained bus choices;
- idle-only transport-sensitive editing;
- visible Software PLL supersession notice.

## Legacy parity disposition

### PARITY / IMPROVED in PR41

- 2–8 physical output route matrix;
- same-device multichannel and multiple-device output;
- Full Range / Low / Mid / High / Sub sources;
- Mains + Sub / Bi-Amp / Tri-Amp topology;
- lower/upper crossover points;
- LR24/LR48 complementary crossover families;
- Sub gain/polarity/phase alignment;
- persistent device/channel routing;
- reference-clock selection and drift compensation;
- device/channel/sample-rate validation;
- transport recovery integration;
- Playback System persistence/rollback;
- PR40 Room Correction coexistence;
- Processed / Reference / Delta coexistence;
- driver-safe Global Bypass behavior.

### SUPERSEDED

- legacy Software PLL → Core Audio Aggregate Device + HAL drift compensation;
- legacy no-op optimiser slope/delay controls → omitted;
- legacy unimplemented output-EQ pre-ringing blend → omitted;
- ambiguous Apply-All optimiser semantics → not reproduced.

### DELIBERATELY DEFERRED FOLLOW-UP — NOT CLAIMED AS PR41 PARITY

- arbitrary per-output parametric EQ;
- arbitrary per-output gain/polarity/delay beyond implemented Sub controls;
- per-output limiter/metering;
- group-delay analysis/correction UI;
- measured acoustic-summation overlay;
- automatic crossover-frequency / per-output-EQ optimisation;
- broadband driver time alignment;
- automated polarity diagnosis;
- acoustic-centre refinement;
- baffle-step / diaphragm-resonance recommendation tools;
- automated combined-system verification workflow.

These are intentionally reserved for a later speaker-optimization milestone that can reuse PR40 measurement infrastructure and PR41’s now-stable output buses.

## Automated evidence before final combined gate

- C1 full combined exact-head gate: green;
- C2a full combined exact-head gate: green;
- C2b full combined exact-head gate: green;
- C3 focused multi-device Aggregate Device gate: green;
- C4 focused Swift/XCTest + physical speaker-bus IOProc gate: green at `9a42d8c0...`;
- production routing UI focused Xcode/XCTest gate: green at `cb6aba71...`.

## Final automated acceptance gate

The final combined PR40 + PR41 tree must pass:
- full XCTest;
- retained PR34–PR41 realtime validators;
- realtime benchmarks;
- Debug app build;
- Release Performance app build;
- PR40 persistence/deployment/audition regressions;
- Content Preset independence regressions;
- Global Bypass regressions;
- Release app build;
- ad-hoc signing;
- sandbox validation;
- DMG creation and upload.

## Combined hands-on Mac acceptance

PR40 and PR41 intentionally share one final physical acceptance session:
- complete a real Room Correction measurement/design/deployment pass;
- verify ordinary stereo playback first;
- verify available same-device multichannel hardware;
- verify two-device Aggregate Device routing if suitable hardware is available;
- verify Mains + Sub / Bi-Amp / Tri-Amp only with appropriately connected drivers/amplifiers;
- verify no unsafe full-range driver signal under Global Bypass;
- verify Processed / Reference / Delta with Room Correction + crossover together;
- verify persistence across stop/start and relaunch;
- verify device disconnect/reconnect and sample-rate rebuild;
- listen for clicks, dropouts, drift, channel swaps, level jumps, unexpected latency or tonal discontinuities.

PR41 remains draft/unmerged until that physical pass is complete.
