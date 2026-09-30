# PR41 — Active Crossover / Speaker Integration

Status: **STACKED ON PR40 — SLICES A/B + C1 + C2a + C2b IMPLEMENTED; FULL C2b COMBINED CI IN PROGRESS**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

C1 substantive commit: `d339046f23c25490b55ca17bd86b012bb955752d`.
C2a substantive commit: `fe49d2df8436e127904810630e912e1720398f55`.
C2b substantive commit: `3daf12648c312d601b7cfee3b4f6252da30710fa`.

This documentation-only checkpoint triggers the full combined PR40 + PR41 workflows on the unchanged C2b source tree. PR41 is temporarily targeted at `main` only for CI and returns to its PR40 base afterward.

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
- the validator is retained in the normal macOS workflow.

C2a full combined exact-head validation passed on `df0aab8f721293315330d119666c57e1b73f3a32`:
- Hardware Test DMG `36711072797`: success.
- macOS `36711072774`: success, including the retained PR41 output-map validator.

## Completed Slice C2b — live same-device full-range transport

C2b makes the same-device multichannel transport real without falsely exposing independent crossover buses that do not yet exist at the correct downstream DSP boundary.

Implemented:

- `AudioIOEngine` now owns the active multi-output routing intent in addition to Playback System persistence;
- routing changes that would alter live physical transport require the engine to be idle;
- Playback System routing transactions update engine + profile atomically and roll both back together on persistence failure;
- transport startup compiles the persisted routing configuration into a `SameDeviceOutputRoutePlan`;
- live C2b activation requires every enabled route to target the selected physical output device;
- live C2b activation permits only `Left Full Range` and `Right Full Range` buses;
- Low/Mid/High/Sub routes fail explicitly instead of receiving semantically incorrect pre/post-DSP signals;
- `CoreAudioTransportSession` accepts a validated same-device route plan and admits float32 multichannel output formats while the capture/tap contract remains stereo;
- the realtime bridge copies one fixed-size `N60SameDeviceOutputMap` during session setup, before output callbacks start;
- the existing two-channel output path is unchanged when multi-output routing is disabled;
- when enabled, `N60OutputIOProc` renders the ordinary final post-DSP L/R program once and fans those samples to the configured physical channels;
- the live multichannel callback supports Core Audio interleaved/planar layouts through the C2a map writer;
- unassigned physical channels are silenced deterministically;
- analysis/VU semantics remain based on the final L/R program rather than duplicated physical endpoints;
- render callback routing remains allocation-free and lock-free.

Focused C2b validation passed on `xcode-27` before the substantive commit:
- full `RoomCorrectionProjectControllerTests` class;
- C2b route eligibility and Playback System/engine ownership tests;
- direct four-channel `N60CaptureIOProc` → `N60OutputIOProc` simulation proving final Left duplication to physical channels 1/2 and final Right duplication to channels 3/4;
- bridge delivery/unsupported-layout diagnostics;
- strict C compilation with `-Wall -Wextra -Werror`.

## Important remaining crossover-bus boundary

The current render kernel computes logical mains/sub crossover signals and recombines them before downstream Room Correction / FIR / dynamics processing. C2b therefore does **not** claim that Low/Mid/High/Sub are yet valid independent physical outputs.

Before those buses can become live, PR41 must define their correct downstream processing ownership and expose them from the render graph without bypassing Room Correction, speaker processing, audition latency, protection or other intended stages.

## Next — Slice C3a: true crossover-bus graph contract

Before multi-device clocks add another variable, define and prove the signal graph for independent physical speaker buses on the already-working one-device transport:

- establish where full-range program processing ends and per-output speaker processing begins;
- preserve Processed / Reference / Delta and raw Global Bypass semantics;
- expose true mains/sub (then Low/Mid/High) bus samples at a stable post-shared-DSP boundary;
- decide and test which correction/phase/protection stages are shared versus per-output;
- keep current stereo recombined playback bit-for-bit stable when physical crossover routes are not active;
- add deterministic summation/latency tests before activating `Sub Mono` or split-band physical routes.

## Later Slice C3b — multiple physical devices / synchronization

After independent bus semantics are correct on one hardware clock:

- Aggregate Device realization where appropriate;
- explicit reference/clock-master selection;
- drift compensation/recovery validation;
- independently authored software PLL/SRC fallback if required;
- disconnect/reconnect and sample-rate rebuild behavior.

## Later Slice C4 — crossover topology / per-output expansion

Only after true independent buses are live:
- independently routable mains/sub and bi/tri-amp paths;
- asymmetric HP/LP review;
- bounded crossover family/order choices with defined summation/phase behavior;
- per-output gain/polarity/delay/EQ/protection where parity and architecture justify them;
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
- output-routing UI remains hidden until the corresponding transport/bus path is genuinely live and validated.
