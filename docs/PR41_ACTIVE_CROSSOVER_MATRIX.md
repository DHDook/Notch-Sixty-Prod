# PR41 — Active Crossover / Speaker Integration

Status: **STACKED ON PR40 — CONTRACT / INVENTORY SLICE**

Base: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

## Purpose

Turn the existing clean-room bass-management/crossover foundation into the production Active Crossover / speaker-integration workflow without violating the commercial product boundary established for Notch Sixty:

- stereo playback product;
- no headphone feature expansion;
- no general multichannel host/transport rewrite;
- Playback System owns speaker/crossover state;
- Content Presets remain content DSP only;
- touched DSP must remain realtime-safe and native-rate through the currently supported sample-rate matrix.

PR41 is deliberately stacked on PR40 so Room Correction and Active Crossover can receive one combined hands-on Mac acceptance pass after both automated gates are green.

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

`PlaybackSystemState` already owns `BassManagementConfiguration`, which is the correct persistence layer for this work.

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

The commercial rewrite keeps the explicit two-channel product directive. PR41 therefore does **not** add an arbitrary 2–8-channel physical render transport or multi-device output PLL/SRC layer.

Legacy behaviors that fundamentally require independently addressable multichannel physical outputs are classified **OUT OF CURRENT PRODUCT SCOPE** for this product rather than silently omitted. This includes:

- arbitrary 2–8 physical output routing;
- bi-amp/tri-amp physical driver matrices;
- multiple simultaneous physical output devices;
- Aggregate Device / Software PLL secondary-output synchronization.

This is a product-scope disposition, not a claim that the historical behavior was dead.

Behaviors that remain meaningful in a stereo speaker + sub integration product are candidates for **PARITY / IMPROVED / SUPERSEDED** implementation in this PR, subject to the slices below.

## Architecture rules

1. **Playback System ownership**
   - crossover/speaker integration belongs to the selected Playback System profile;
   - changing Content Presets must not alter crossover state;
   - changing crossover state must not overwrite Content Preset EQ/dynamics/headroom.

2. **No duplicate DSP path**
   - extend the existing `N60Crossover` / graph snapshot path;
   - do not create a second crossover engine.

3. **Realtime safety**
   - no allocation, locks, logging, file I/O, coefficient design, FFT work, or async work on render;
   - all candidate designs and measurement analysis remain control-plane/offline;
   - graph changes use the existing bounded transition discipline.

4. **Room Correction interaction**
   - PR40 remains the authoritative room-measurement/correction workflow;
   - crossover measurement assistance should reuse PR40 measurement/analysis assets where technically meaningful rather than adding another microphone pipeline;
   - deployment ordering and latency must remain explicit and testable.

5. **Global audition contract**
   - Processed / Reference / Delta semantics remain latency-correct;
   - raw Global Bypass must remain raw apart from the established master-volume contract;
   - crossover state must not break PR40 room-correction audition/bypass behavior.

## Planned slices

### Slice A — contract, ownership and baseline tests

- freeze the commercial two-channel disposition above;
- inventory the current crossover model, render stage, persistence and production UI;
- add deterministic tests proving Playback System ownership and Content Preset independence;
- add exact baseline tests around crossover + Room Correction stage ordering and audition/bypass behavior before changing DSP semantics.

### Slice B — complete the current production crossover surface

Expose and persist the capabilities that already exist in the production engine but are incomplete in the production UI:

- enable/bypass;
- frequency;
- LR24/LR48 topology;
- sub gain;
- polarity;
- sub phase-alignment enable/frequency/Q;
- validation monitor path where appropriate for an engineering/verification surface.

All production edits must persist through the selected Playback System rather than mutating only transient engine state.

### Slice C — stereo speaker/sub crossover model improvements

Audit and independently design the useful subset of legacy asymmetric crossover behavior that remains meaningful without multichannel physical routing. Candidate improvements include:

- independently reviewable mains HP and sub LP settings rather than forcing hidden symmetry where a better commercial model is justified;
- bounded crossover family/slope choices only where complementary summation and phase behavior are well-defined;
- explicit validation of frequency/order combinations through 384 kHz;
- predictable transition behavior with no hard state discontinuity.

Do not add controls that have no real DSP effect.

### Slice D — measurement-assisted integration

Reuse PR40 measurement infrastructure for stereo speaker/sub integration where the measurement topology can produce trustworthy evidence. Candidate tools:

- measured/predicted crossover-region response comparison;
- group-delay visualization;
- reviewable phase/alignment suggestions;
- polarity diagnostics;
- explicit before/after verification.

No automatic mutation from a single measurement. Suggestions must be reviewable and explicitly applied.

### Slice E — production workflow and parity closure

- polished Active Crossover workspace;
- authoritative Daily Playback/System summary;
- persistence/reload coverage;
- corruption/rollback handling;
- combined PR40 + PR41 regression pass;
- final legacy disposition ledger: PARITY / IMPROVED / SUPERSEDED / OUT OF CURRENT PRODUCT SCOPE / BLOCKED.

## Acceptance gates

Automated:

- exact-head XCTest;
- Debug and Release builds;
- existing retained PR34–PR40 validators remain green;
- native-rate coverage through supported 44.1/48/96/192/384 kHz matrix where deterministic tests apply;
- no Content Preset mutation from crossover operations;
- PR40 Room Correction persistence/deployment/audition tests remain green;
- Global Bypass remains raw;
- no realtime allocation/locking regressions;
- DMG packaging and sandbox validation remain green.

Combined hands-on Mac acceptance after PR40 + PR41 automated completion:

- verify PR40 measurement/design/deployment workflow;
- verify Active Crossover controls and persistence;
- verify crossover changes do not alter Content Presets or deployed room-correction provenance;
- verify Processed / Reference / Delta and Global Bypass with crossover + room correction together;
- verify stop/start, relaunch and sample-rate rebuild behavior;
- listen for clicks, dropouts, level jumps, unexpected latency, channel imbalance or transition artifacts.

## First implementation decision

PR41 starts by strengthening the existing stereo crossover ownership/UI/testing path before changing crossover math. That gives us a small, independently testable first slice and preserves a clean rollback point while PR40 remains unmerged pending physical acceptance.
