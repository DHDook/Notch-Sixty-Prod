# PR38 Legacy Dynamics Code Audit

Status: **IN PROGRESS**

This audit defines the parity floor for the PR38 production Dynamics workspace.

## Source-of-truth rule

Legacy parity is determined from **legacy source code**, not the user guide, README, handoff prose, comments in planning documents, or other documentation.

Authoritative legacy evidence, in order:

1. `src/ui/views/dynamics/DynamicsView.swift` — proves a control was actually user-accessible and records the UI range/step/conditional visibility.
2. `src/dsp/dynamics/DynamicsConfig.swift` — records the persisted configuration model/defaults and implemented subconfiguration.
3. `src/dsp/dynamics/DynamicsProcessor.swift` plus specialized processor source (for example `src/dsp/denoising/SpectralDenoiser.swift`) — confirms runtime semantics when a field's behavior is ambiguous.
4. `src/app/EqualiserStore.swift` — confirms update/binding behavior where needed.

Documentation is deliberately excluded as parity evidence.

Each legacy item is classified as one of:

- **UI-exposed** — user-adjustable in legacy; PR38 parity requirement unless deliberately routed to a more appropriate production workspace.
- **DSP-only** — implemented/configurable in code but not exposed by the legacy UI; candidate, not automatic parity.
- **Prod-present** — already represented in the commercial control plane.
- **Prod-gap** — legacy UI-exposed behavior missing from the current commercial control plane.
- **Enhancement candidate** — additional control justified by DSP usefulness rather than knob count.

## Confirmed legacy UI inventory — first pass

### Noise / restoration

**Infrasonic Filter**
- enable
- cutoff frequency
- slope (24 / 48 / 96 dB/oct)
- application target (`mainChain`, `subOutputOnly`, `both`)
- Current Prod has enable/cutoff/slope; application target is a **Prod-gap** to evaluate/reroute with speaker/crossover architecture.

**Mains Hum Notch**
- enable
- 50/60 Hz region
- one-shot Detect action and detected-frequency status
- continuous tracking
- harmonic count (1–16)
- global Q
- independent depth for each enabled harmonic
- Current Prod already has the underlying notch model, continuous tracking, detected fundamental, harmonic count/Q/depth array; production UI still needs the complete user workflow.

**Spectral Denoiser**
- enable
- threshold / noise-floor level
- named preset
- quality mode
- Wiener floor
- reduction amount
- attack
- release
- protected-frequency-range enable
- protected range low/high endpoints
- profile Capture
- profile Reset
- captured/profile-lock status
- Current Prod exposes threshold, preset/base preset, quality, reduction, protected range and profile commands in the model; legacy Wiener-floor and attack/release controls are **Prod-gap candidates pending processor-level comparison**.

### Dialogue / leveling

**Dialogue-Relative Leveler**
- enable
- dialogue band low/high
- target gap
- boost ratio
- max boost
- attack
- release
- program gate threshold
- Voice Gate enable
- Voice Gate sensitivity (legacy UI couples confidence ceiling/floor)
- Voice Gate minimum confidence
- `DynamicsConfig.swift` also contains detector-window and deeper Voice Gate fields (modulation center/bandwidth, envelope window, measurement window, floor/ceiling); those are being classified separately as UI-exposed vs DSP-only.

**LUFS Loudness Match**
- enable
- target LUFS
- maximum correction
- attack
- release
- dialogue gate
- volume-dependent loudness mode
- reference phon level
- reference system-volume level
- contour strength
- Current Prod splits loudness matching and per-band/volume-dependent contouring into cleaner models; PR38 should preserve functionality while presenting the hierarchy more clearly than legacy.

### Core dynamics

**De-Esser**
- enable
- frequency
- detector Q
- threshold
- ratio
- maximum attenuation/range
- attack
- release
- dynamic-EQ mode exists in the legacy configuration and is being checked against actual UI exposure.

**Three-Band Multiband Compressor**
- enable
- low/mid crossover
- mid/high crossover
- crossover slope(s)
- for each Low / Mid / High band:
  - threshold
  - ratio
  - attack
  - release
  - knee
  - makeup gain
  - sidechain high-pass
- Current Prod has independent low/mid and mid/high slopes plus all three bands' core settings.

**Wideband Compressor**
- enable
- threshold
- ratio
- knee width
- attack
- release
- makeup gain
- program-dependent release
- feed-forward / feed-back topology
- sidechain high-pass
- Current Prod already represents all of these.

**Expander**
- enable
- threshold
- ratio
- range
- attack
- release
- Current Prod already represents all of these.

**Pause Gate**
- enable
- preset
- threshold
- hold
- attack / fade-out
- release / fade-in
- hysteresis
- PR38 product convention remains explicit: **Attack = fade-out/close; Release = fade-in/open**.

### Protection / gain management

**Dynamic Gain Rider**
- enable
- target sustained limiter gain reduction
- maximum reduction
- response speed
- live rider-gain status in legacy UI
- Current Prod has the processing model. Any live status display must use an independently gated meter/telemetry demand path.

**Soft Clipper**
- enable
- drive
- threshold
- knee
- curve type
- automatic gain compensation
- legacy advanced config also contains asymmetry trim; UI exposure is being verified.

**Look-Ahead Limiter**
- enable
- ceiling
- attack
- release
- look-ahead
- true-peak guard
- Current Prod has the processing model and a separate true-peak-guard flag.

**EQ Headroom Compensation / Automatic Headroom**
- legacy contains both predictive EQ-headroom behavior and the reactive gain-rider behavior; PR38 must keep their purposes distinct rather than combining them into an ambiguous single control.

### Conditioning / spatial items that appeared in the legacy Dynamics surface

The legacy Dynamics surface also exposed controls for De-Harsh, Stereo Widener, stereo mode, DC filter, sub-bass phase alignment, speaker IR alignment, symmetry balance, panning gain matrix, crosstalk cancellation, coefficient decoupling, oversampling, sync buffer, FIR IR/correction, multi-seat averaging, and Bass Management.

These are still part of the **code inventory**, but their old screen placement is not binding on the production UI. PR38 will route non-dynamics concepts to the production workspace that best matches their function. In particular, Bass Management / crossover-related controls should not be forced into Dynamics simply because the legacy UI put them there.

## PR38 UI rule derived from the audit

The production Dynamics workspace will use a two-level organization:

- grouped processor navigator for fast enable/status/selection;
- dedicated selected-processor editor with logical subsections for advanced controls.

Subconfiguration will not be hidden behind an engineering/settings button. Advanced fields can be collapsed into clearly named subsections inside the selected processor editor, but every supported production control remains discoverable from the Dynamics workspace.

Live gain-reduction/activity telemetry will be independently demanded per processor so opening or enabling one meter does not wake unrelated metering pipelines.

## Remaining audit work before the first full PR38 UI slice

- finish source-level enumeration of every legacy `DynamicsView` binding;
- distinguish legacy UI-exposed fields from config-only fields for Dynamic EQ, Dialogue Voice Gate, denoiser internals, clipper asymmetry, loudness contour, and protection controls;
- compare every UI-exposed legacy field with `NotchSixty/Audio/DynamicsConfiguration.swift` and the current C snapshot APIs;
- classify true Prod gaps versus deliberate architectural relocation;
- evaluate a small set of world-class enhancement candidates only after parity gaps are known;
- add a PR38 CI guard that prevents production Dynamics editors from silently losing audited controls.
