# PR40 — Room Correction Production Workflow

## Purpose

PR40 turns the existing Room Correction runtime hook and placeholder production page into a reproducible multi-position acoustic measurement, target-curve, correction-design, and deployment workflow.

The work must preserve the product ownership boundary established in PR39:

- **Playback System Profile** owns the deployed room-correction state because it describes the physical playback system and room.
- **Content Preset** must never replace or reset room-correction calibration.
- **Session State** remains transient and does not own calibration.

Room correction remains distinct from:

1. main-EQ / per-band FIR,
2. global Speaker IR,
3. Active Crossover / mains-sub alignment.

## Clean-room / sources of truth

Implementation is net-new.

Permitted behavior sources:

- current proprietary Notch Sixty runtime and PR39 ownership model;
- public Apple capture/permission documentation;
- published acoustic-measurement literature;
- legacy documentation/UI/config only for observable product semantics.

Historical GPL DSP/source/tests are not implementation templates.

Measurement-method reference for the first production design:

- Angelo Farina, *Simultaneous Measurement of Impulse Response and Distortion with a Swept-Sine Technique*, AES 108, 2000.
- Angelo Farina, *Advancements in Impulse Response Measurements by Sine Sweeps*, AES 122, 2007.

The implementation may use the published exponential-sine-sweep method and independently derived math; source expression from another implementation must not be copied.

## Current-state inventory

### Existing runtime

The engine already has a dedicated room-correction convolution path with its own prepared program lifecycle, diagnostics, latency contribution, and program-miss accounting.

Current render order places room correction after the crossover stage. The existing realtime path must be reused rather than duplicated.

Existing runtime filter model:

- optional enabled state;
- name;
- optional source sample rate;
- independent left taps plus optional right taps;
- declared filter latency;
- finite/tap-count/sample-rate validation;
- control-plane program preparation;
- click-safe graph transition and raw Global Bypass semantics.

### Existing persistence

`PlaybackSystemState` already owns:

- bass management;
- room-correction runtime configuration;
- Speaker IR;
- system-level gain and speaker controls.

Applying a Playback System is transactional and applying a Content Preset preserves system-owned fields.

### Existing production UI

The Room Correction route currently exposes only:

- loaded filter name;
- correction enabled/bypassed state;
- a placeholder for measurement/design workflow.

### Permission gap

The current production target has system-audio capture usage text but does not yet declare microphone usage or audio-input sandbox access. PR40 must add microphone-specific permission plumbing before acoustic capture is enabled.

## Product workflow contract

The production workflow is intentionally split into **Daily Playback** and **Calibration**.

### Daily Playback

Visible without entering calibration mode:

- selected Playback System name;
- correction enabled/bypassed state;
- active correction design name/status;
- measurement date / design date summary;
- measured correction range;
- headroom cost / recommended attenuation summary;
- button to open or resume Calibration.

Normal playback must remain unchanged while calibration is not active.

### Calibration stages

The guided workflow is:

1. **Setup**
   - select microphone input;
   - inspect/request microphone permission;
   - load or clear microphone calibration data;
   - select sweep level and safe measurement settings;
   - confirm selected Playback System / output device.

2. **Measure**
   - generate a deterministic exponential sine sweep off the realtime callback;
   - play the known excitation through the selected physical output;
   - capture microphone input into preallocated/bounded buffers;
   - name each position;
   - support the product’s intended three-seat workflow while allowing additional bounded positions;
   - retain the raw captured response and exact sweep/design parameters.

3. **Analyze**
   - deconvolve the captured sweep into an impulse response;
   - derive transfer-function magnitude and phase;
   - estimate acoustic arrival / timing information;
   - determine usable frequency range and measurement confidence;
   - flag clipping, insufficient level/SNR, missing sweep energy, invalid sample rate, or incomplete capture.

4. **Average**
   - allow inclusion/exclusion of positions;
   - support explicit position weights;
   - derive a spatially robust aggregate response without raw complex cancellation across seats;
   - preserve each individual measurement alongside the aggregate.

5. **Target**
   - choose a built-in target or custom target;
   - edit/import target points;
   - set correction range;
   - set smoothing;
   - set maximum boost and maximum cut;
   - preview measured/aggregate/target response before design.

6. **Design**
   - generate a bounded correction FIR for the current output sample rate;
   - enforce boost limits and usable-range limits;
   - compute conservative headroom impact;
   - validate finite taps, tap budget, and latency;
   - keep first production design magnitude-focused/minimum-phase unless validated measurement data justifies an explicit mixed/excess-phase mode later.

7. **Deploy**
   - deploy through the **existing room-correction convolution runtime**;
   - update the selected Playback System transactionally;
   - allow click-safe correction enable/bypass;
   - preserve Processed / latency-matched Reference / Delta behavior;
   - preserve raw Global Bypass.

## State and persistence model

PR40 separates lightweight playback state from reproducibility assets.

### Playback System Profile — authoritative playback state

The selected Playback System continues to contain the **deployed correction FIR** so playback does not depend on a sidecar project file being available.

Add only lightweight calibration/design metadata needed to identify and explain that deployed filter, for example:

- calibration project UUID (optional);
- active design UUID (optional);
- measurement/design timestamps;
- position count;
- correction range;
- target summary;
- smoothing / boost / cut limits;
- recommended headroom attenuation;
- design algorithm version.

The profile must remain sufficient to restore the active filter transactionally.

### Room Correction Project — reproducibility assets

Large/raw project assets live separately under Application Support, keyed by stable UUID, not inline in `profiles-v1.json`.

A versioned project contains:

- project identity and Playback System association;
- microphone identity metadata;
- microphone calibration curve/data and source metadata;
- sweep parameters;
- raw capture per position;
- deconvolved IR per position;
- transfer-function data per position;
- quality/confidence metrics;
- inclusion/weight state;
- aggregate response;
- target curve;
- correction-design parameters;
- generated design candidates and metadata.

Raw assets must remain available after a design is deployed so the design is reproducible and can be regenerated after target changes.

### Failure semantics

- Missing/corrupt project sidecar must **not** break playback of an already deployed correction FIR.
- Missing/corrupt project sidecar must block redesign/resume with a clear recoverable error.
- Applying a Playback System remains transactional.
- Applying a Content Preset never touches room-correction project/deployed state.

## Measurement architecture

### Control / worker planes

All of the following stay off the physical-output realtime callback:

- microphone enumeration;
- permission requests;
- sweep synthesis;
- microphone calibration parsing;
- deconvolution;
- FFT/transfer-function analysis;
- spatial averaging;
- target interpolation/smoothing;
- FIR design;
- project persistence.

### Realtime path

The render callback may only consume already-prepared measurement playback/capture state through bounded, preallocated structures.

If sweep injection is added to the output graph, it must be explicit calibration-session state, not ordinary content DSP, and must not allocate/lock/log/touch UI in the callback.

Measurement capture uses its own bounded/preallocated path and must never route captured microphone audio into normal playback.

### Calibration session lifecycle

Use an explicit calibration lifecycle independent from ordinary Playback System persistence:

```text
idle
requestingPermission
enumeratingInputs
ready
arming
measuring
analyzing
reviewing
designing
deploying
failed
```

Stopping/canceling a measurement must return normal playback ownership cleanly and release capture resources.

## Microphone permission and device contract

PR40 adds:

- `NSMicrophoneUsageDescription` with a room-measurement-specific explanation;
- App Sandbox audio-input entitlement;
- explicit authorization-status UI;
- user-initiated permission request from the calibration workflow;
- microphone enumeration with stable IDs and user-visible names.

Do not request microphone permission merely because the app launches or because normal system DSP starts.

## Microphone calibration contract

Support a calibration curve as frequency/gain points with metadata, not as opaque DSP source code.

Required behavior:

- import user-selected calibration text where format can be parsed unambiguously;
- normalize/sort/deduplicate frequency points;
- reject non-finite/invalid frequencies;
- interpolate calibration gain in log-frequency space for analysis;
- retain original source filename/metadata when available;
- calibration applies to measurement analysis only and is never inserted into daily playback DSP.

## Measurement quality contract

Each measurement records objective quality flags/metrics. At minimum:

- capture clipped / not clipped;
- playback/capture peak level;
- estimated signal-to-noise or noise-floor margin;
- sweep completeness;
- direct-arrival detectability;
- usable low/high frequency estimate;
- sample-rate validity;
- finite-data validation.

A low-confidence measurement may be retained for inspection, but correction design must not silently treat it as a good measurement.

## Multi-position contract

The intended production flow foregrounds three named positions, but the state model must not hard-code exactly three.

Default naming may be ergonomic (for example Center / Left / Right), but the user can rename positions.

Spatial averaging rules:

- average magnitudes in the log/dB domain using normalized user weights;
- do not average unrelated seat phases as raw complex spectra;
- retain per-position phase/timing for diagnostics and future validated phase work;
- make excluded positions explicit rather than deleting their data.

## Target / correction design contract

### Target representation

Use versioned frequency/gain points plus a target identity/metadata layer.

Built-in library should be small and defensible at first (for example Flat, Gentle Downward Tilt, Bass Shelf + Tilt) and remain editable after selection.

### Smoothing

Smoothing is an analysis/design control, not destructive mutation of raw measurements.

### Boost/cut safety

Correction design must:

- clamp boost and cut to user-configured bounds;
- avoid boosting below/above usable measurement limits;
- avoid attempting to invert deep narrow nulls aggressively;
- expose the estimated maximum positive correction and headroom requirement.

### Headroom

PR40 must compute recommended correction headroom explicitly.

Do not silently overwrite Content Preset headroom attenuation, because that field belongs to Content Preset ownership. The UI may warn/recommend an amount and the final deployment path may use room-filter normalization/design gain so the Playback System remains safe without violating ownership.

The exact gain strategy must be deterministic and covered by tests before deployment is enabled.

## Latency and audition semantics

The generated filter declares intentional filter latency separately from the convolution engine’s fixed partition latency.

The existing graph remains authoritative for total latency.

Processed / Reference / Delta must remain aligned to the published graph latency.

Correction bypass must not create a stale latency mismatch or hidden alternate convolution path.

Global Bypass remains the raw escape path.

## Initial PR40 implementation slices

### Slice A — contract + durable data model

- this document;
- versioned measurement/project/design types;
- Playback System metadata/reference extension;
- project store under Application Support;
- persistence/corruption/migration tests;
- no audio-path changes.

### Slice B — microphone foundation

- sandbox/usage-description changes;
- permission controller;
- microphone catalog/selection;
- microphone calibration import/parser;
- production Setup UI;
- deterministic tests where possible.

### Slice C — sweep/capture foundation

- independently derived ESS generator/inverse filter;
- bounded calibration session buffers;
- explicit sweep playback/injection path;
- microphone capture;
- cancellation/recovery;
- deterministic generator and capture-state tests.

### Slice D — analysis + multi-position

- deconvolution;
- IR/transfer-function/timing analysis;
- quality metrics;
- named positions and weighting;
- aggregate magnitude;
- raw project persistence.

### Slice E — target + correction design

- target library/editor/import;
- smoothing/range/limits;
- correction FIR design;
- headroom accounting;
- deterministic response/design tests through supported sample rates.

### Slice F — deployment + production polish

- deploy generated FIR through existing room-correction runtime;
- daily playback summary/bypass;
- visualization/status;
- transactional profile integration;
- Processed/Reference/Delta and Global Bypass regression tests;
- exact-head CI and focused real-Mac acoustic/hardware acceptance.

## Deterministic acceptance gates

PR40 is not complete until tests cover at least:

- project encode/decode/version rejection/corrupt recovery;
- profile/runtime state ownership preservation;
- Content Preset application preserving calibration;
- Playback System transactional restore;
- permission-state mapping independent of UI;
- microphone calibration interpolation/validation;
- ESS generation finite/deterministic behavior;
- deconvolution recovery from a synthetic known system;
- timing/arrival estimation from synthetic delayed IR;
- magnitude/phase transfer-function correctness;
- multi-position weighted averaging;
- excluded-position behavior;
- smoothing/target interpolation;
- correction-range and boost/cut limits;
- generated FIR finite/tap-budget/sample-rate validation;
- headroom calculation;
- deployment through existing room-correction program lifecycle;
- correction bypass and raw Global Bypass;
- latency-matched audition modes;
- supported native rates including 44.1/48/96 kHz and high-rate stress through 384 kHz where algorithmically applicable.

## Manual acceptance gate

Because PR40 changes acoustic measurement behavior structurally, merge requires a focused real-Mac acceptance run on the exact substantive tree unless explicitly waived after an equivalent accepted build.

The hardware/acoustic check should verify:

- microphone permission UX;
- real microphone enumeration/selection;
- at least three named positions;
- sweep playback and clean capture;
- sensible measured response/IR/timing;
- quality warnings for intentionally bad captures;
- target editing and preview;
- generated correction deployment;
- audible/visible enable-bypass behavior;
- no glitches during normal playback outside calibration;
- profile save/restore across relaunch;
- Processed/Reference/Delta alignment;
- raw Global Bypass;
- no unexpected CPU regression when calibration is idle.

## Non-goals for PR40

- physical multichannel output;
- pretending the current stereo physical route provides an independent subwoofer hardware channel;
- replacing the existing convolution engine;
- merging Speaker IR, room correction, and per-band FIR into one user concept;
- aggressive excess-phase correction without validated measurements and dedicated acceptance evidence;
- cloud measurement, telemetry, or remote processing.
