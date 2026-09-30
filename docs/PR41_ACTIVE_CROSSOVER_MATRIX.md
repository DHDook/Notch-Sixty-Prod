# PR41 — Active Crossover / Speaker Integration

Status: **STACKED ON PR40 — SLICES A/B IMPLEMENTED; COMBINED CI GREEN; MULTI-OUTPUT PARITY RETAINED**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

Combined PR40 + PR41 source checkpoint `5084dbfebc5d7d4a7fa77a5d621bfbd2c9c9f167` passed the full Hardware Test DMG and macOS workflows before this documentation-only clarification.

## Purpose

Turn the existing clean-room bass-management/crossover foundation into the production Active Crossover / speaker-integration workflow while preserving the commercial product identity and the legacy product's useful routing capability:

- stereo program/content semantics remain the default listening model;
- multiple physical output channels/devices remain a parity target where required for active crossover and speaker integration;
- no headphone feature expansion;
- Playback System owns speaker/crossover/output-routing state;
- Content Presets remain content DSP only;
- touched DSP must remain realtime-safe and native-rate through the currently supported sample-rate matrix.

PR41 is deliberately stacked on PR40 so Room Correction and Active Crossover can receive one combined hands-on Mac acceptance pass after both automated gates are green.

## Important product-model distinction

**Stereo program content is not the same thing as a single physical output device.**

The legacy application already separates these concepts: it can start from a stereo program, derive logical crossover buses, and route those buses to multiple physical output channels/devices. The commercial rewrite should preserve that capability if it can be done cleanly within the proprietary transport architecture and App Store constraints.

Accordingly, PR41 must not classify multi-output support as out of scope merely because the source program is stereo.

The intended model is:

```text
Stereo program / content DSP
            ↓
Room / system processing
            ↓
Active-crossover signal derivation
            ↓
Per-output speaker processing
            ↓
Physical output routing (one or more devices)
```

This keeps stereo listening semantics clean while allowing true independent mains/sub or multi-driver output paths when configured.

## Existing production foundation

The current production engine already provides a clean-room crossover primitive and should be evolved rather than replaced:

- stereo mains logical bus;
- mono sub logical bus;
- Linkwitz-Riley 24 dB/oct and 48 dB/oct topologies;
- 20–500 Hz crossover range;
- sub gain;
- sub polarity inversion;
- optional sub all-pass phase alignment;
- recombined / mains-only / sub-only validation monitoring;
- preallocated realtime state;
- control-plane coefficient design;
- short dual-path transition for live crossover changes;
- no intentional algorithmic latency from the crossover itself.

`PlaybackSystemState` already owns `BassManagementConfiguration`, which is the correct persistence layer for the current speaker-integration state. Multi-output routing should also belong to Playback System state rather than Content Presets.

## Legacy behavioral evidence

The PR34 source/test audits establish that the historical Active Crossover family contained substantially more than one crossover filter. Confirmed reachable behavior included:

- 2–8 output source/target matrix;
- full-range, L/R Low/Mid/High, and Sub Mono source assignments;
- Full Range / Bi-Amp / Tri-Amp topology;
- lower/upper crossover points;
- asymmetric LP/HP frequency, slope, and filter type controls;
- Linkwitz-Riley and Butterworth crossover families;
- per-output EQ, gain, polarity, delay, limiter and metering;
- group-delay analysis/correction;
- predicted acoustic summation plus measured overlay;
- crossover-frequency and per-output-EQ optimisation;
- broadband driver time alignment;
- polarity diagnosis;
- crossover-region acoustic-centre refinement;
- baffle-step recommendations;
- diaphragm-resonance suggestions;
- combined-system verification;
- multi-device Aggregate Device / Software PLL routing.

The same audits also identify legacy behavior that must **not** be reproduced mechanically:

- no-op optimiser slope toggle;
- no-op optimiser delay toggle;
- an unimplemented output-EQ pre-ringing blend;
- comments claiming controls that were not actually rendered;
- ambiguous optimiser delta-vs-absolute Apply-All semantics.

## Product-scope disposition

The commercial rewrite keeps stereo program semantics, but **multi-output routing remains a parity target**.

The following legacy capabilities are therefore no longer pre-classified as out of current product scope:

- multiple physical output channels;
- multiple simultaneous physical output devices;
- independently routable mains/sub or driver-derived buses;
- Aggregate Device and/or independently implemented software synchronization/SRC where required for multiple hardware clocks.

Exact implementation is intentionally not frozen yet. PR41 should first determine the cleanest proprietary architecture and App Store-safe transport model.

The commercial rewrite does **not** need to reproduce the historical routing internals. It does need to preserve the observable capability where practical, with equal or better synchronization, recovery, and realtime safety.

## Architecture rules

1. **Playback System ownership**
   - crossover/speaker integration and physical output routing belong to the selected Playback System profile;
   - changing Content Presets must not alter crossover or output routing state;
   - changing crossover/routing state must not overwrite Content Preset EQ/dynamics/headroom.

2. **Stereo program, explicit output fan-out**
   - keep the source/content DSP model stereo;
   - derive speaker/driver buses only after the appropriate shared program stages;
   - output fan-out must be explicit and testable rather than hidden inside the stereo render path.

3. **No duplicate DSP path**
   - extend the existing `N60Crossover` / graph snapshot foundation where appropriate;
   - do not create a second unrelated crossover engine.

4. **Clock-domain correctness**
   - one physical device may use the ordinary selected-device clock domain;
   - multiple devices with independent hardware clocks require an explicit synchronization strategy;
   - evaluate Aggregate Device first where appropriate, with an independently authored software PLL/SRC fallback only if needed;
   - never assume two devices remain sample-synchronous merely because their nominal rates match.

5. **Realtime safety**
   - no allocation, locks, logging, file I/O, coefficient design, FFT work, or async work on render;
   - SRC/PLL control state must be bounded and render-safe if implemented;
   - all candidate designs and measurement analysis remain control-plane/offline;
   - graph/routing changes use bounded transition discipline.

6. **Room Correction interaction**
   - PR40 remains the authoritative room-measurement/correction workflow;
   - crossover measurement assistance should reuse PR40 measurement/analysis assets where technically meaningful rather than adding another microphone pipeline;
   - deployment ordering, per-output correction ownership, and latency must remain explicit and testable.

7. **Global audition contract**
   - Processed / Reference / Delta semantics remain latency-correct;
   - raw Global Bypass must remain raw apart from the established master-volume contract;
   - crossover/output-routing state must not break PR40 room-correction audition/bypass behavior.

## Slice A/B implementation checkpoint

Implemented on top of PR40:

- added `ProductProfileController.replaceSelectedSystemBassManagement(_:)`, a narrow transactional Playback System update matching the room-correction ownership pattern;
- profile persistence failure rolls back both live `AudioIOEngine` crossover state and the in-memory Playback System profile;
- added persistent enable/bypass convenience without overwriting unrelated Playback System fields;
- Active Crossover production UI now writes through the selected Playback System rather than mutating transient engine state directly;
- production UI now exposes the existing engine capabilities that were previously hidden: sub gain, sub phase-alignment enable/frequency/Q, and the logical verification monitor path;
- current logical monitor copy correctly states that the present implementation does not yet create a separately routed physical sub output;
- Content Preset state remains independent from crossover changes;
- deployed PR40 Room Correction configuration and calibration provenance remain unchanged by crossover edits;
- reload restores the persisted crossover state alongside Room Correction;
- deterministic realtime coverage verifies that enabling/changing the zero-latency crossover preserves the attached room-correction convolution program generation and latency at 44.1/48/96/192/384 kHz;
- raw Global Bypass remains raw with crossover + room correction attached.

Focused `xcode-27` validation passed before the substantive commit was created. The combined PR40 + PR41 checkpoint then passed the full Hardware Test DMG and macOS workflows.

## Planned slices

### Slice A — contract, ownership and baseline tests — COMPLETE

- establish Playback System ownership;
- inventory current crossover model, render stage, persistence and production UI;
- add deterministic tests proving Content Preset independence;
- add exact baseline tests around crossover + Room Correction stage ordering and audition/bypass behavior.

### Slice B — complete the current production crossover surface — COMPLETE

Expose and persist the capabilities that already exist in the production engine but were incomplete in the production UI:

- enable/bypass;
- frequency;
- LR24/LR48 topology;
- sub gain;
- polarity;
- sub phase-alignment enable/frequency/Q;
- logical validation monitor path.

All production edits now persist through the selected Playback System rather than mutating only transient engine state.

### Slice C — multi-output routing architecture + stereo speaker/sub crossover model

Before expanding crossover math, establish the physical-output architecture required to preserve legacy multi-output capability cleanly.

Work includes:

- model logical output buses independently from physical devices/channels;
- define per-output identity, enable state, source assignment, device UID and physical channel mapping;
- preserve stereo program semantics while permitting true mains/sub and later bi/tri-amp fan-out;
- determine same-device multichannel routing versus multiple-device routing contracts;
- evaluate Aggregate Device support and software clock-synchronization/SRC fallback;
- define bounded device-loss/recovery and sample-rate rebuild behavior;
- keep routing state in Playback System persistence;
- only then expand crossover families/asymmetric HP/LP controls where they map to real independently addressable output paths.

No UI control should imply an independent physical path unless one actually exists.

### Slice D — per-output speaker processing + measurement-assisted integration

Reuse PR40 measurement infrastructure and add per-output speaker processing where independently addressable outputs exist.

Candidate capabilities:

- per-output gain/polarity/delay;
- per-output EQ/limiting where justified by the parity audit;
- measured/predicted crossover-region response comparison;
- group-delay visualization/correction;
- reviewable time-alignment and polarity suggestions;
- crossover-frequency/acoustic-centre refinement;
- explicit before/after verification.

No automatic mutation from a single measurement. Suggestions must be reviewable and explicitly applied.

### Slice E — production workflow and parity closure

- polished Active Crossover / Output Routing workspace;
- authoritative Playback System summary;
- persistence/reload coverage;
- multi-device clock/recovery hardening;
- corruption/rollback handling;
- combined PR40 + PR41 regression pass;
- final legacy disposition ledger: PARITY / IMPROVED / SUPERSEDED / OUT OF CURRENT PRODUCT SCOPE / BLOCKED.

## Acceptance gates

Automated:

- exact-head XCTest;
- Debug and Release builds;
- existing retained PR34–PR40 validators remain green;
- native-rate coverage through supported 44.1/48/96/192/384 kHz matrix where deterministic tests apply;
- no Content Preset mutation from crossover/routing operations;
- PR40 Room Correction persistence/deployment/audition tests remain green;
- Global Bypass remains raw;
- no realtime allocation/locking regressions;
- deterministic clock-domain/routing tests before multi-device output is enabled;
- DMG packaging and sandbox validation remain green.

Combined hands-on Mac acceptance after PR40 + PR41 automated completion:

- verify PR40 measurement/design/deployment workflow;
- verify Active Crossover controls and Playback System persistence;
- verify same-device multi-output routing where hardware permits;
- verify multi-device routing/synchronization where hardware permits;
- verify crossover/routing changes do not alter Content Presets or deployed room-correction provenance;
- verify Processed / Reference / Delta and Global Bypass with crossover + room correction together;
- verify stop/start, relaunch, sample-rate rebuild, disconnect/reconnect and device-recovery behavior;
- listen for clicks, dropouts, drift, combing, level jumps, unexpected latency or channel imbalance.

## Next implementation decision

Slice C will now begin with the **multi-output routing architecture**, not with the earlier assumption that the product should remain single-device. The goal is to preserve a stereo program model while restoring true independently addressable physical output paths cleanly enough to support mains/sub and later driver-level crossover workflows without importing the legacy transport implementation.
