# PR41 — Active Crossover / Speaker Integration

Status: **STACKED ON PR40 — SLICES A/B + C1 IMPLEMENTED; COMBINED PR40+C1 VALIDATION CHECKPOINT**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

Slice C1 substantive commit: `d339046f23c25490b55ca17bd86b012bb955752d`.

This document records the C1 boundary. Full combined CI is run against an unchanged source tree before C2 modifies the physical transport.

## Product model

**Stereo program content is not the same thing as a single physical output device.**

Notch Sixty keeps stereo program/content semantics while preserving multi-output speaker routing as a parity target:

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

- transactional Playback System ownership for `BassManagementConfiguration`;
- rollback on profile persistence failure;
- production Active Crossover UI writes through Playback System state;
- enable, crossover frequency, LR24/LR48, sub gain, polarity, sub phase alignment and logical monitor controls;
- Content Preset independence;
- PR40 room-correction deployment/provenance preservation;
- crossover + room-FIR realtime regression through 44.1/48/96/192/384 kHz;
- raw Global Bypass preservation.

The prior combined PR40 + PR41 checkpoint `5084dbfebc5d7d4a7fa77a5d621bfbd2c9c9f167` passed full Hardware Test DMG and macOS workflows.

## Completed Slice C1 — persistent multi-output routing contract

Implemented:

- physical output-channel capacity is discovered and carried by `AudioOutputDevice`;
- logical `SpeakerOutputBus` identities cover full-range, Low/Mid/High L/R and Sub Mono signals;
- `PhysicalOutputEndpoint` persists stable device UID + zero-based channel rather than transient Core Audio object IDs;
- named/enabled `SpeakerOutputRoute` entries map logical buses to physical endpoints;
- synchronization intent supports Automatic, Aggregate Device and Software PLL modes;
- persistent `MultiOutputRoutingConfiguration` supports up to 8 routes;
- structural validation rejects duplicate route IDs, empty UIDs, duplicate physical destinations, insufficient enabled routes and invalid reference-device selection;
- runtime activation validation checks current device presence, physical channel capacity, finite sample rate and native-rate support;
- one logical source may intentionally fan out to multiple physical destinations;
- Playback System persists routing intent transactionally with rollback;
- legacy profile archives remain compatible through optional routing state;
- storing routing intent does not mutate the current legacy selected output or pretend the route is live;
- Content Preset, bass-management and PR40 room-correction state remain unchanged by C1 routing edits;
- persistence/reload and failure-rollback tests are present.

Focused `xcode-27` validation passed the existing profile/room-correction controller suite plus new routing tests before the substantive commit was created.

## Architecture rules

1. Stable physical identity uses Core Audio device UIDs, not `AudioDeviceID`.
2. Logical buses and physical endpoints are separate concepts.
3. Multiple channels on one physical device share one hardware clock; multiple devices require explicit synchronization.
4. Equal nominal sample rates never imply hardware-clock synchronization.
5. No allocation, locks, logging, file I/O, coefficient design or unbounded work on render.
6. Multi-output activation must fail atomically rather than partially routing a system.
7. PR40 Room Correction, Processed/Reference/Delta and raw Global Bypass contracts remain authoritative on the shared program path.

## Next — Slice C2: same-device multi-channel transport realization

Implement the smallest real physical multi-output step first:

- realize enabled routes whose destinations are channels on one physical Core Audio device;
- use that single device's hardware clock; no SRC or PLL is needed in C2;
- map logical buses into an explicit bounded multi-channel output representation;
- validate stream layout/channel capacity at activation;
- preserve the current stereo single-output path unchanged when multi-output routing is disabled;
- provide atomic start/stop/rebuild and rollback behavior;
- add deterministic channel-map/routing tests before route-editing UI is exposed;
- keep PR40 FIR/audition/bypass semantics unchanged upstream of bus fan-out.

## Later Slice C3 — multiple physical devices

After same-device multi-channel is green:

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
- retained PR34–PR40 validators;
- no Content Preset mutation from routing/crossover work;
- PR40 persistence/deployment/audition regressions remain green;
- Global Bypass remains raw;
- no realtime allocation/locking regressions;
- DMG packaging, signing and sandbox validation remain green;
- physical multi-output is not exposed until its transport slice is complete and validated.
