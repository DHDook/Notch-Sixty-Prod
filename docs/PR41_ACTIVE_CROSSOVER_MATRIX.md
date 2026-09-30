# PR41 — Active Crossover / Speaker Integration

Status: **STACKED ON PR40 — SLICES A/B + C1 + C2a IMPLEMENTED; FULL COMBINED CI IN PROGRESS**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

C1 substantive commit: `d339046f23c25490b55ca17bd86b012bb955752d`.
C2a substantive commit: `fe49d2df8436e127904810630e912e1720398f55`.

This documentation-only checkpoint triggers full PR40 + PR41 validation before C2b changes `CoreAudioTransportSession`. PR41 is temporarily targeted at `main` only to invoke the repository's normal workflows and will return to the PR40 base afterward.

## Product model

**Stereo program content is not the same thing as a single physical output device.**

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

Playback System owns crossover and physical-output routing. Content Presets remain content DSP only.

## Completed Slice A/B

- transactional Playback System ownership for bass management;
- persistent production crossover controls;
- Content Preset independence;
- PR40 room-correction deployment/provenance preservation;
- crossover + room-FIR regression through 44.1/48/96/192/384 kHz;
- raw Global Bypass preservation.

## Completed Slice C1 — persistent multi-output routing contract

- physical output-channel capacity is discovered by the Core Audio catalog;
- logical `SpeakerOutputBus` identities are separate from physical endpoints;
- stable device UID + zero-based physical channel persistence;
- up to 8 named/enabled output routes;
- Automatic / Aggregate Device / Software PLL synchronization intent;
- structural and runtime capability validation;
- logical source fan-out allowed; duplicate physical destinations rejected;
- Playback System persistence with rollback and legacy-profile compatibility;
- routing intent does not activate an unimplemented transport path;
- Content Preset, bass-management and room-correction state remain independent.

C1 full combined exact-head validation passed on `0f6dcc9b06a5650f1301ccc554ddbf3e7570d707`:
- Hardware Test DMG `36708903127`: success.
- macOS `36708903198`: success.

## Completed Slice C2a — same-device route plan and realtime fan-out primitive

- immutable `SameDeviceOutputRoutePlan` requires all enabled routes to target one physical device/clock domain;
- disabled routes are excluded while enabled-route order is preserved;
- multi-device plans are rejected here and reserved for C3;
- fixed-size C `N60SameDeviceOutputMap` supports up to 8 mapped routes with no render-time allocation/locking;
- `N60SpeakerBusFrame` defines bounded logical bus values independent from hardware layout;
- fan-out writer supports interleaved and planar Core Audio `AudioBufferList` layouts;
- every represented physical channel is silenced before mapped values are written, preventing stale samples on unassigned channels;
- duplicate physical channels, invalid buses and out-of-range routes are rejected;
- deterministic C validation covers interleaved 4-channel and planar 4-buffer layouts;
- the validator is retained in the normal macOS workflow;
- the primitive remains dormant: the live IOProc is unchanged until C2b.

Focused C2a validation passed on the xcode-27 runner before the substantive commit.

## Architecture finding before C2b

The current render kernel computes logical mains/sub crossover signals and then recombines them to stereo before downstream room-correction/convolution/dynamics stages. Therefore C2b must **not** pretend that duplicating the final stereo stream produces independent active-crossover outputs.

C2b will first make the physical transport genuinely multichannel while preserving the proven stereo program path. Only bus types whose signal semantics are actually available at the correct point in the DSP graph may be activated. Unsupported independent Low/Mid/High/Sub physical routes must fail explicitly rather than silently carrying the wrong signal.

## Next — Slice C2b: same-device multichannel Core Audio transport

- admit one physical output device with more than two output channels;
- compile the C2a route map during control-plane setup;
- keep stereo system-audio capture/tap semantics unchanged;
- preserve existing two-channel IOProc behavior when multi-output routing is disabled;
- add an explicit multichannel output IOProc path without render-thread allocation or locks;
- define which logical buses are valid for this first live transport step and reject the rest until true post-DSP independent buses exist;
- make start/stop/rebuild atomic and rollback-safe;
- validate interleaved/planar device stream layouts and physical channel capacity;
- preserve PR40 Processed / Reference / Delta and raw Global Bypass contracts.

## Later Slice C3 — multiple physical devices

- Aggregate Device realization where appropriate;
- explicit reference/clock-master selection;
- drift compensation/recovery validation;
- independently authored software PLL/SRC fallback if required;
- disconnect/reconnect and sample-rate rebuild behavior.

## Later Slice C4 — crossover topology expansion

Only after independently addressable physical routes exist:
- true mains/sub and later bi/tri-amp fan-out;
- asymmetric HP/LP review;
- bounded crossover family/order choices with defined summation/phase behavior;
- no UI control without a real render-path effect.

## Acceptance gates

- exact-head XCTest;
- Debug and Release builds;
- retained PR34–PR41 validators;
- no Content Preset mutation from routing/crossover work;
- PR40 persistence/deployment/audition regressions remain green;
- Global Bypass remains raw;
- no realtime allocation/locking regressions;
- DMG packaging, signing and sandbox validation remain green;
- physical multi-output UI remains hidden until its transport is genuinely live and validated.
