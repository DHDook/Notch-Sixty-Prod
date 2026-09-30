# PR41 — Active Crossover / Speaker Integration

Status: **STACKED ON PR40 — SLICES A/B + C1 IMPLEMENTED; MULTI-OUTPUT PARITY RETAINED**

Base implementation dependency: PR40 exact green head `56d2fbac467fc6b43df5b699f4b50d195bff98d1`.

Combined PR40 + PR41 source checkpoint `5084dbfebc5d7d4a7fa77a5d621bfbd2c9c9f167` passed the full Hardware Test DMG and macOS workflows before Slice C1. Slice C1 has passed its focused `xcode-27` model/profile gate and is ready for the next combined exact-head checkpoint.

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

The legacy application already separates these concepts: it can start from a stereo program, derive logical crossover buses, and route those buses to multiple physical output channels/devices. The commercial rewrite preserves that distinction.

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

`PlaybackSystemState` owns `BassManagementConfiguration` and now also owns the persistent multi-output routing intent introduced by Slice C1.

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

Known legacy no-op/unimplemented/ambiguous controls are not parity requirements and will not be reproduced mechanically.

## Architecture rules

1. **Playback System ownership**
   - crossover/speaker integration and physical output routing belong to the selected Playback System profile;
   - Content Presets must not alter crossover/output routing;
   - system routing changes must not overwrite Content Preset EQ/dynamics/headroom.

2. **Stereo program, explicit output fan-out**
   - keep source/content DSP stereo;
   - derive speaker/driver buses after the appropriate shared stages;
   - output fan-out is explicit, persistent, and testable.

3. **Logical buses are not physical endpoints**
   - a logical bus may intentionally feed more than one physical endpoint;
   - a physical device/channel endpoint may be claimed by at most one enabled route;
   - persistent device identity uses stable Core Audio UIDs, never transient `AudioDeviceID` values.

4. **Clock-domain correctness**
   - multiple channels on one hardware device share that device's clock;
   - multiple devices require an explicit synchronization strategy;
   - evaluate Aggregate Device first where appropriate and independently authored software PLL/SRC fallback where needed;
   - nominal sample-rate equality is not treated as clock synchronization.

5. **Realtime safety**
   - no allocation, locks, logging, file I/O, coefficient design, FFT work, or async work on render;
   - routing/clock state changes use bounded control-plane transitions;
   - C1 is persistence/validation only and does not activate unimplemented routes.

6. **Room Correction interaction**
   - PR40 remains the authoritative room-measurement/correction workflow;
   - deployment ordering, eventual per-output correction ownership, and latency remain explicit and testable.

7. **Global audition contract**
   - Processed / Reference / Delta remain latency-correct;
   - raw Global Bypass remains raw apart from established master-volume behavior.

## Slice A/B checkpoint — COMPLETE

Implemented:

- transactional Playback System ownership for `BassManagementConfiguration`;
- rollback on profile persistence failure;
- production Active Crossover UI writes through Playback System state;
- enable, crossover frequency, LR24/LR48, sub gain, polarity, sub phase alignment and logical monitor controls;
- Content Preset independence;
- PR40 room-correction deployment/provenance preservation;
- reload persistence;
- crossover + room-FIR realtime regression through 44.1/48/96/192/384 kHz;
- raw Global Bypass preservation.

The combined PR40 + PR41 checkpoint passed the full Hardware Test DMG and macOS workflows.

## Slice C1 — persistent multi-output routing contract — COMPLETE

Implemented at substantive commit `d339046f23c25490b55ca17bd86b012bb955752d`:

- `AudioOutputDevice` now carries discovered physical output-channel capacity while retaining compatible defaults for deterministic fixtures;
- Core Audio catalog reads aggregate output-channel count from the device stream configuration;
- introduced logical `SpeakerOutputBus` identities for full-range, Low/Mid/High L/R and Sub Mono signals;
- introduced stable `PhysicalOutputEndpoint` device-UID + zero-based-channel identity;
- introduced named/enabled `SpeakerOutputRoute` entries;
- introduced `MultiOutputSynchronizationMode`: Automatic, Aggregate Device, Software PLL;
- introduced persistent `MultiOutputRoutingConfiguration` with up to 8 routes;
- structural validation rejects duplicate route IDs, empty device UIDs, duplicate physical destinations, invalid enabled-route counts and invalid reference-device selection;
- runtime capability validation checks current device presence, real channel capacity, finite target sample rate and native-rate support;
- the same logical source may intentionally fan out to multiple physical destinations;
- Playback System persistence stores routing intent transactionally and rolls back on persistence failure;
- old profile archives remain compatible because the new routing field is optional and legacy single-output state decodes as no multi-output routing;
- storing routing intent does **not** alter the currently selected legacy output or activate an unimplemented transport path;
- Content Preset, bass-management and PR40 room-correction state remain unchanged by C1 routing edits;
- persistence/reload tests cover the new routing state.

Focused `xcode-27` validation passed the existing profile/room-correction controller suite plus the new routing tests. Temporary helper workflows/scripts self-removed after the substantive commit.

## Planned slices

### Slice A — contract, ownership and baseline tests — COMPLETE

### Slice B — complete current production crossover surface — COMPLETE

### Slice C1 — persistent multi-output routing contract — COMPLETE

### Slice C2 — same-device multi-channel transport realization

Next implementation target:

- realize enabled routes that target channels on one physical Core Audio device;
- keep one hardware clock domain and avoid unnecessary SRC;
- map logical buses into an explicit bounded multi-channel output frame/buffer representation;
- validate device stream layout and channel capacity at activation;
- preserve the current stereo single-output path unchanged when multi-output routing is disabled;
- define atomic start/stop/rebuild and rollback behavior;
- add deterministic routing/mixing tests before exposing route-editing UI;
- keep PR40 FIR/audition/bypass semantics intact on the shared stereo program path.

### Slice C3 — multiple physical devices / synchronization

After same-device multi-channel is green:

- Aggregate Device realization where appropriate;
- explicit reference/clock-master selection;
- drift compensation and recovery validation;
- independently authored software PLL/SRC fallback if required;
- device disconnect/reconnect and sample-rate rebuild behavior;
- no assumption that equal nominal rates imply synchronized clocks.

### Slice C4 — crossover topology expansion on real output paths

Only after physical routes are real:

- independently routable mains/sub and later bi/tri-amp buses;
- review asymmetric mains HP / sub LP controls;
- bounded crossover family/order options where summation/phase behavior is well-defined;
- no control without a real audible/render-path effect.

### Slice D — per-output speaker processing + measurement-assisted integration

Candidate capabilities:

- per-output gain/polarity/delay;
- per-output EQ/limiting where justified by parity evidence;
- measured/predicted crossover-region comparison;
- group-delay visualization/correction;
- reviewable time-alignment and polarity suggestions;
- crossover-frequency/acoustic-centre refinement;
- explicit before/after verification.

### Slice E — production workflow and parity closure

- polished Active Crossover / Output Routing workspace;
- authoritative Playback System summary;
- persistence/reload and corruption/rollback coverage;
- multi-device clock/recovery hardening;
- combined PR40 + PR41 regression pass;
- final legacy disposition ledger.

## Acceptance gates

Automated:

- exact-head XCTest;
- Debug and Release builds;
- retained PR34–PR40 validators remain green;
- native-rate coverage through supported sample-rate matrix where deterministic tests apply;
- no Content Preset mutation from crossover/routing operations;
- PR40 Room Correction persistence/deployment/audition tests remain green;
- Global Bypass remains raw;
- no realtime allocation/locking regressions;
- deterministic channel-map and clock-domain validation before physical multi-output is enabled;
- DMG packaging and sandbox validation remain green.

Combined hands-on Mac acceptance after PR40 + PR41 automated completion:

- verify PR40 measurement/design/deployment workflow;
- verify Active Crossover and routing persistence;
- verify same-device multi-output routing where hardware permits;
- verify multi-device routing/synchronization where hardware permits;
- verify crossover/routing changes do not alter Content Presets or room-correction provenance;
- verify Processed / Reference / Delta and raw Global Bypass;
- verify stop/start, relaunch, sample-rate rebuild, disconnect/reconnect and recovery;
- listen for clicks, dropouts, drift, combing, level jumps, latency or channel imbalance.

## Next implementation decision

Proceed with **Slice C2: same-device multi-channel transport realization**. This is the smallest real physical-output step because all routed channels share one hardware clock, allowing us to prove the bus/channel mapping and lifecycle contract before adding Aggregate Device or software PLL/SRC complexity.
