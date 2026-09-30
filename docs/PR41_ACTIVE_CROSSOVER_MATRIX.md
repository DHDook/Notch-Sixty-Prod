# PR41 — Active Crossover / Speaker Integration

Status: **IMPLEMENTATION COMPLETE — FINAL COMBINED PR40 + PR41 CI / HANDS-ON ACCEPTANCE REMAIN**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

Key substantive checkpoints:
- C1 routing contract: `d339046f23c25490b55ca17bd86b012bb955752d`
- C2a realtime output-map primitive: `fe49d2df8436e127904810630e912e1720398f55`
- C2b live same-device multichannel transport: `3daf12648c312d601b7cfee3b4f6252da30710fa`
- C3 multi-device Aggregate Device transport: `511458e5...`
- C4 true physical speaker buses: `9a42d8c0894fe78d9a1fa642fd9cb40c1e557576`
- Production routing/crossover UI: `cb6aba710c526606812b64e0aa6cb48ddc160e68`

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

## Completed ownership and persistence foundation

- transactional Playback System ownership for bass-management/crossover state;
- transactional Playback System ownership for physical output routing;
- persistence failures roll back live engine state and the in-memory Playback System profile together;
- Content Preset EQ/dynamics/preamp/headroom remain independent;
- PR40 Room Correction deployment and provenance remain independent;
- reload restores crossover, physical routes and Room Correction together;
- physical route/topology edits that require transport reconstruction are rejected while processing is running.

## Completed physical routing contract

- physical output-channel capacity is discovered from Core Audio;
- stable device UID + zero-based physical channel identities are persisted;
- up to 8 named/enabled output routes;
- logical source fan-out is allowed;
- duplicate physical destinations are rejected;
- configurations may remain saved while hardware is disconnected;
- activation performs stricter device/channel/sample-rate capability checks;
- logical `SpeakerOutputBus` identities are independent from physical endpoints.

Supported logical buses:
- Left / Right Full Range;
- Left / Right Low;
- Left / Right Mid;
- Left / Right High;
- Sub Mono.

## Completed same-device multichannel transport

- immutable same-device route plans require one hardware clock domain;
- fixed-size realtime output map supports up to 8 physical routes;
- interleaved and planar Core Audio output layouts are supported;
- unassigned physical channels are deterministically silenced;
- render callback routing remains allocation-free and lock-free;
- when multi-output is disabled, the existing stereo transport remains unchanged.

C2a full combined exact-head validation passed on `df0aab8f721293315330d119666c57e1b73f3a32`:
- Hardware Test DMG `36711072797`: success;
- macOS `36711072774`: success.

C2b full combined exact-head validation passed on `072757c6...`:
- Hardware Test DMG: success;
- macOS: success.

## Completed multi-device transport / synchronization

C3 realizes multiple physical output devices through a private Core Audio Aggregate Device rather than a bespoke realtime clock engine.

Implemented:
- deterministic reference/clock-master device selection;
- aggregate subdevice ordering with the reference device first;
- physical-route channel indices flattened into aggregate-channel indices;
- private Aggregate Device lifecycle owned by `CoreAudioTransportSession`;
- HAL drift compensation enabled for non-reference output devices;
- same-device plans continue to bypass Aggregate Device creation;
- device/sample-rate/routing validation remains control-plane only;
- disconnect/rebuild paths continue through the existing transport recovery lifecycle.

`Automatic` and `Aggregate Device` synchronization use this clock domain. The archived `Software PLL` enum value remains decodable for compatibility but is rejected for activation with an explicit superseded error. A second custom SRC/PLL implementation is intentionally not maintained in parallel with the HAL clock-domain solution.

## Completed true physical speaker-bus crossover

C4 adds a dedicated post-shared-DSP speaker-bus splitter. This is separate from the historical logical/recombined stereo bass-management preview.

Supported physical modes:
- **Mains + Sub** — stereo high-passed mains plus mono low-passed Sub bus;
- **Bi-Amp** — independent stereo Low and High buses;
- **Tri-Amp** — independent stereo Low, Mid and High buses.

DSP behavior:
- Linkwitz-Riley 24 dB/oct and 48 dB/oct lower crossover topologies;
- independently selectable upper LR24/LR48 topology for Tri-Amp;
- lower crossover range expands to the speaker-frequency domain for Bi/Tri-Amp;
- Tri-Amp validates a distinct upper crossover above the lower crossover and below Nyquist;
- Mains + Sub retains sub gain, polarity inversion and bounded all-pass phase alignment;
- splitter coefficients are designed on the control plane and copied as an immutable snapshot into preallocated realtime state;
- no allocation, locks, file I/O, logging or coefficient design occur in the output callback.

Signal-ordering contract:
- shared stereo EQ, Room Correction, dynamics/protection, FIR stages and audition processing happen before the physical speaker-bus splitter;
- Full Range L/R routes therefore receive the ordinary final processed stereo program;
- split driver buses are derived from that same final shared stereo result;
- ordinary stereo playback is unchanged when physical split routing is inactive;
- the ordinary logical/recombined bass-management stage is suppressed when true split speaker routes are active to avoid double-crossover processing;
- mandatory physical driver crossover remains in force for split routes even when Global Bypass requests raw shared-program processing, preventing accidental full-range signal delivery to a routed driver band.

Focused C4 validation passed on `xcode-27` before commit `9a42d8c0...`:
- Swift/XCTest routing/crossover coverage;
- strict C compilation;
- direct `N60CaptureIOProc` → `N60OutputIOProc` physical-speaker-bus simulation;
- actual low-passed Sub and high-passed mains delivery to distinct physical channels;
- Full Range mirror remains the post-shared-DSP program;
- route/topology compatibility validation.

## Completed production workflow

The production Active Crossover page now exposes the live architecture rather than hiding transport capability:

- enable/bypass;
- Stereo/logical-only, Mains + Sub, Bi-Amp and Tri-Amp selection;
- lower crossover frequency/topology;
- upper Tri-Amp crossover frequency/topology;
- sub gain and polarity where applicable;
- Mains + Sub phase-alignment frequency/Q;
- logical verification monitor;
- physical routing enable;
- Automatic / Aggregate Device synchronization;
- explicit reference device for multi-device systems;
- 2–8 route matrix;
- per-route logical bus, device and physical channel assignment;
- route enable/delete/add controls;
- supported bus choices are constrained by the selected physical topology;
- transport-sensitive controls are disabled while processing is running;
- Software PLL is visibly marked superseded rather than presented as a working alternate clock engine.

The UI compiles and its focused profile/controller tests pass on `xcode-27` at the production UI checkpoint.

## Legacy parity disposition

### PARITY / IMPROVED in PR41

- 2–8 physical output route matrix;
- one-device multichannel and multiple-device output;
- Full Range / Low / Mid / High / Sub logical sources;
- Mains + Sub / Bi-Amp / Tri-Amp physical crossover modes;
- lower and upper crossover points where the topology requires them;
- LR24 / LR48 complementary crossover families;
- Sub gain / polarity / all-pass phase alignment;
- stable persistent device/channel mapping;
- explicit reference clock selection;
- multi-device drift compensation;
- device/channel/sample-rate capability validation;
- safe device loss/rebuild path through the production transport lifecycle;
- production Playback System ownership with rollback;
- physical crossover protection under Global Bypass;
- coexistence with PR40 Room Correction and existing Processed / Reference / Delta audition semantics.

The commercial rewrite improves on the legacy organization by separating logical speaker buses, physical endpoint identities, clock-domain realization and realtime mapping into explicit independently testable layers.

### SUPERSEDED

- legacy Software PLL / secondary-output clock loop → Core Audio Aggregate Device clock domain with HAL drift compensation;
- legacy no-op optimiser slope toggle → omitted;
- legacy no-op optimiser delay toggle → omitted;
- legacy unimplemented output-EQ pre-ringing blend → omitted;
- ambiguous legacy optimiser Apply-All delta-vs-absolute semantics → not reproduced.

### DELIBERATELY DEFERRED FOLLOW-UP — NOT CLAIMED AS PR41 PARITY

The historical Active Crossover family also included functionality that is larger than the routing/crossover transport milestone and is not silently claimed as complete here:

- arbitrary per-output parametric EQ chains;
- arbitrary per-output gain/polarity/delay beyond the implemented Sub controls;
- per-output limiter/metering;
- group-delay analysis/correction UI;
- measured acoustic-summation overlay;
- automatic crossover-frequency / per-output-EQ optimisation;
- broadband driver time-alignment optimiser;
- polarity diagnosis automation;
- acoustic-centre refinement;
- baffle-step and diaphragm-resonance recommendation tools;
- automated combined-system verification workflow.

These should reuse the production routing buses and PR40 measurement infrastructure in a later dedicated speaker-optimization milestone rather than expanding PR41 after its transport/crossover contract is stable.

## Final automated acceptance gate

PR41 closes only after the final exact combined PR40 + PR41 tree passes:

- full XCTest;
- retained PR34–PR41 realtime validators;
- Debug build;
- Release Performance build;
- realtime benchmarks;
- Content Preset independence regressions;
- PR40 Room Correction persistence/deployment/audition regressions;
- Global Bypass regressions;
- Release app build;
- ad-hoc signing;
- sandbox validation;
- DMG creation/upload.

## Combined hands-on Mac acceptance

PR40 and PR41 intentionally share one final physical acceptance session:

- complete a real PR40 microphone measurement/design/deployment pass;
- verify ordinary two-channel playback before enabling physical routing;
- verify same-device multichannel routing on available hardware where possible;
- verify a multi-device Aggregate Device system if two suitable outputs are available;
- verify physical Mains + Sub / Bi-Amp / Tri-Amp routes only with appropriately connected hardware;
- verify no driver receives an unsafe full-range signal when Global Bypass is engaged;
- verify Processed / Reference / Delta with Room Correction + crossover together;
- verify route/crossover persistence after stop/start and app relaunch;
- verify device disconnect/reconnect and sample-rate rebuild behavior;
- listen for clicks, dropouts, level jumps, drift, channel swaps, unexpected latency or tonal discontinuities.

Until that physical pass is complete, PR41 remains draft/unmerged even after automated CI is green.
