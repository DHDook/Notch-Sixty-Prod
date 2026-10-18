# PR38 Legacy Dynamics Code Audit

Status: **SOURCE INVENTORY COMPLETE; PRODUCTION PARITY UI IMPLEMENTED; HARDWARE ACCEPTANCE PENDING**

This audit defines the parity floor for the PR38 production Dynamics workspace.

## Source-of-truth rule

Legacy parity is determined from **legacy source code**, not the user guide, README, handoff prose, planning notes, or other documentation.

Authoritative legacy evidence, in order:

1. `src/ui/views/dynamics/DynamicsView.swift` — proves a control was actually user-accessible and records its UI range, step, conditional visibility, and reset behavior.
2. `src/dsp/dynamics/DynamicsConfig.swift` — records persisted configuration, defaults, and implemented subconfiguration.
3. `src/dsp/dynamics/DynamicsProcessor.swift` plus specialized processor source such as `src/dsp/denoising/SpectralDenoiser.swift` — confirms runtime semantics where a field is ambiguous.
4. `src/app/EqualiserStore.swift` — confirms update/binding behavior where needed.

Documentation is deliberately excluded as parity evidence.

Classification used below:

- **UI parity** — directly exposed in the legacy UI. Production must preserve the capability, although it may live in a more logical workspace.
- **Legacy DSP-only** — implemented/configurable in code but not exposed by the legacy Dynamics UI. Candidate, not automatic parity.
- **Prod-present** — represented by the commercial control plane and realtime snapshot.
- **Prod-gap** — legacy UI capability not currently representable by the commercial control plane.
- **Relocate** — preserve the capability, but not on the production Dynamics page.
- **Enhancement** — additional control justified by useful DSP behavior rather than knob count.

## 1. Noise / restoration

### Infrasonic Filter

Legacy UI parity:
- enable
- cutoff frequency
- slope: 24 / 48 / 96 dB/oct
- application target: main chain / sub output only / both

Commercial status:
- enable, cutoff, and slope are **Prod-present**.
- application target is a **Prod-gap + Relocate**. The commercial realtime setter currently represents only a main-chain infrasonic filter. Target-aware sub-output protection belongs with Active Crossover / output routing rather than being hidden in Dynamics. PR38 records the gap; the production UI must not pretend parity exists until target-aware routing is restored.

### Mains Hum Notch

Legacy UI parity:
- enable
- 50/60 Hz nominal region
- one-shot Detect
- detected-frequency status
- continuous tracking
- harmonic count, 1–16
- global Q
- independent depth for each enabled harmonic

Commercial status: **Prod-present**. PR38 now exposes the complete workflow, including one-shot Detect/status and per-harmonic depth editing. One-shot Detect temporarily enables the existing detector only for its measurement window, then restores the user's Continuous Tracking preference; Tracking remains parked when OFF.

### Spectral Denoiser

Legacy UI parity:
- enable
- threshold / noise floor
- Natural / Standard / Aggressive / Dehiss / Custom preset
- Quality / High / Ultra FFT mode
- Wiener floor
- reduction amount
- attack
- release
- protected-frequency-range enable
- protected low/high endpoints
- profile Capture
- profile Reset
- capture/profile-lock status

Commercial status:
- enable, preset/base preset, quality, reduction, threshold, protected range, profile command/revision and telemetry are **Prod-present**.
- Wiener floor and attack/release were **confirmed Prod-gaps** and are now restored by PR38 behind an explicit advanced-tuning override so named-preset sound remains unchanged by default.

Processor-level finding: the commercial `N60SpectralDenoiserSnapshot` already owns `minimumGain`, `suppressionAttack`, and `suppressionRelease`, but `N60SpectralDenoiserSnapshotConfigure` currently overwrites them from tuning defaults. Legacy code exposed Wiener floor and millisecond smoothing explicitly. PR38 will restore advanced user overrides while keeping named-preset behavior unchanged unless the user deliberately customizes them.

World-class direction: smoothing controls should be expressed in time units and converted for the active hop/sample rate, rather than exposing internal one-pole coefficients.

## 2. Dialogue / program leveling

### Dialogue-Relative Leveler

Legacy UI parity:
- enable
- dialogue band low/high
- target gap
- boost ratio
- maximum boost
- attack
- release
- program gate threshold
- Voice Gate enable
- Voice Gate sensitivity; the legacy UI couples confidence floor/ceiling
- Voice Gate minimum confidence

Legacy DSP-only fields:
- detector window
- modulation center
- modulation bandwidth
- voice-envelope window
- voice measurement window
- independent confidence floor and ceiling

Commercial status: all of the above DSP fields are **Prod-present**.

PR38 decision: preserve the legacy simple controls in the primary editor and expose detector/voice-analysis details in an **Advanced Detection** disclosure. These are useful expert controls and therefore accepted as an **Enhancement**, not required to clutter the primary surface.

### LUFS Loudness Match / loudness compensation

Legacy UI parity:
- match enable
- target LUFS
- maximum correction
- attack
- release
- dialogue gate
- volume-dependent loudness enable
- reference phon level
- reference system-volume level
- contour strength

Commercial status:
- LUFS target/max-correction/attack/release/dialogue gate are **Prod-present**.
- the commercial loudness-contour engine has strength, reference phons, maximum boost, maximum cut, and selectable level source. This is a more explicit production model than the legacy contour implementation.
- the legacy `referenceVolume` scalar is not represented one-for-one. This is recorded as a **behavioral parity item** to validate rather than blindly recreating an old scalar if the current system-volume-derived contour already covers the same use case.

PR38 presentation: LUFS Match and Loudness Compensation are separate modules so users can understand normalization versus low-level equal-loudness compensation.

## 3. Core dynamics

### De-Esser

Legacy UI parity:
- enable
- frequency
- detector Q
- threshold
- ratio
- range / maximum attenuation
- attack
- release

Legacy DSP-only:
- Dynamic-EQ processing mode existed in config/processor code but was not exposed by the legacy Dynamics UI.

Commercial status: all fields, including Dynamic-EQ mode, are **Prod-present**.

PR38 decision: expose Dynamic-EQ mode under **Advanced** as a useful **Enhancement**.

### Three-Band Multiband Compressor

Legacy UI parity:
- enable
- low/mid crossover
- mid/high crossover
- Low / Mid / High, each with threshold, ratio, attack, release, knee, makeup gain, and sidechain high-pass

Legacy config also carried separate low/mid and mid/high crossover slopes; the old inline UI did not make those prominent.

Commercial status: all three bands and independent crossover slopes are **Prod-present**.

PR38 decision: expose both crossover slopes because the production DSP already supports them and they materially affect band isolation. This is an **Enhancement** over the old UI.

### Wideband Compressor

Legacy UI parity:
- enable
- threshold
- ratio
- knee
- attack
- release
- makeup gain
- program-dependent release
- feed-forward / feed-back topology
- sidechain high-pass

Commercial status: **Prod-present**.

Potential future enhancements such as detector Peak/RMS selection, stereo-link percentage, sidechain audition, or auto makeup require real DSP semantics and are **not** being added merely as cosmetic controls in PR38.

### Expander

Legacy UI parity:
- enable
- threshold
- ratio
- range
- attack
- release

Commercial status: **Prod-present**.

### Pause Gate

Legacy UI parity:
- enable
- named preset: Amplifier Hiss / Sensitive / Relaxed / Broadcast / Custom
- threshold
- hold
- attack
- release
- hysteresis

Commercial status:
- threshold, hold, attack, release and hysteresis are **Prod-present**.
- named presets were a **confirmed Prod-gap** in the Swift control plane and are now restored in PR38 without changing Pause Gate DSP semantics.

Product convention is explicit and retained:
- **Attack = fade-out / close time**
- **Release = fade-in / open time**

The production editor will show those descriptions next to the industry-standard names.

## 4. Protection / gain management

### Dynamic Gain Rider

Legacy UI parity:
- enable
- target sustained limiter gain reduction
- maximum reduction
- response speed
- live rider gain

Commercial status: processing controls are **Prod-present**. Live status must use an independently demanded telemetry pipeline; opening another dynamics module must not activate it.

### Soft Clipper

Legacy UI parity:
- enable
- drive
- threshold
- knee
- curve: Quadratic / Cubic / Sine / Tube
- automatic gain compensation
- asymmetry trim, -3…+3 dB

Commercial status: **Prod-present**, including asymmetry trim.

### Look-Ahead Limiter

Legacy UI parity:
- enable
- ceiling
- attack
- release
- look-ahead
- true-peak guard

Commercial status: **Prod-present**.

### Automatic / predictive headroom

The legacy surface contained two different ideas that must stay distinct:
- **Dynamic Gain Rider**: reactive, driven by sustained limiter reduction.
- **EQ Headroom Compensation**: predictive/static attenuation derived from known EQ/correction boost.

Commercial status:
- Gain Rider is **Prod-present**.
- `AutomaticHeadroomConfiguration` represents the commercial predictive-headroom control.

PR38 presentation keeps these as separate modules/concepts rather than a single ambiguous “auto level” switch.

### Oversampling

Legacy UI exposed a 4× toggle. Commercial protection supports 1× / 2× / 4×. The expanded selector is a justified **Enhancement** and is **Prod-present**.

## 5. Conditioning / stereo controls

### De-Harsh

Legacy UI parity:
- enable
- amount / tilt
- frequency

Commercial status: **Prod-present**.

### Stereo Widener

Legacy UI parity:
- enable
- low width
- mono-low-band option
- low/mid crossover
- mid width
- mid/high crossover
- high width

Commercial status: **Prod-present**.

### Stereo mode

Legacy UI parity: Stereo / Wide Mono / True Mono.

Commercial status: **Prod-present**.

### DC Offset Filter

Legacy UI parity: enable.

Commercial status: **Prod-present**.

## 6. Legacy Dynamics-surface items that belong elsewhere in production

The old Dynamics screen also surfaced controls that are not dynamics processors. They remain part of the source audit, but old screen placement is not binding on the production UX.

**Relocate to Active Crossover / speaker integration:**
- Bass Management
- sub-bass phase alignment
- speaker IR/time alignment where it is specifically part of driver/sub integration

**Relocate to Room Correction:**
- FIR impulse-response correction
- multi-seat averaging
- room-correction-related FIR/convolution workflows

**Relocate to Equalizer / processing architecture:**
- Dynamic EQ editing; PR37 already made Dynamic EQ contextual to ordinary EQ bands
- high-resolution coefficient behavior where it is an EQ implementation mode

**Relocate to system/advanced processing rather than Dynamics:**
- sync buffer
- latency policy
- dither

**Stereo/spatial features requiring later placement review:**
- symmetry balance
- panning gain matrix
- crosstalk cancellation

These capabilities are not to be silently deleted. Their eventual production home must be explicit before Engineering Validation is removed.

## 7. Production Dynamics information architecture

PR38 uses a two-level workspace rather than recreating the legacy six-column control wall.

Primary groups:

1. **Dynamics** — Compressor, Multiband Compressor, Expander, Pause Gate, Gain Rider
2. **Restoration** — Spectral Denoiser, De-Esser, Mains Hum, Infrasonic Filter
3. **Level & Dialogue** — LUFS Match, Loudness Compensation, Dialogue Leveler
4. **Protection** — Limiter, Soft Clipper, Automatic Headroom, Oversampling
5. **Conditioning** — De-Harsh, Stereo Widener, Stereo Mode, DC Offset Filter

The left processor navigator shows module name, enable state and concise status. Selecting a module opens one dedicated editor. Advanced subconfiguration uses named disclosure sections inside that editor; it is never hidden behind an unrelated settings/wrench button.

## 8. Metering / telemetry rule

Every live production meter is independently demand-gated unless its signal is intentionally derived from another already-requested meter.

Examples:
- compressor gain-reduction display requests compressor GR only;
- gain-rider readout requests rider telemetry only;
- denoiser suppression/profile status requests denoiser telemetry only;
- limiter/true-peak display does not wake compressor, RTA, or VU pipelines.

A processor being enabled does not imply its UI telemetry must also run when the editor is hidden. PR38 implements live status as a cancellable child of the selected processor editor at 8 Hz. Compressor/expander/limiter/GR/etc. values are direct runtime state already required by the active processor, so reading them does not enable the expensive render-kernel meter accumulator or a second analyzer pipeline. True analyzers/detectors such as Mains detection retain explicit activation semantics.

## 9. Accepted enhancement candidates for PR38

Add when already supported by the commercial DSP/control plane:
- Multiband independent crossover slopes.
- De-Esser Dynamic-EQ mode under Advanced.
- Dialogue detector window and detailed Voice Gate parameters under Advanced.
- 1× / 2× / 4× oversampling selector rather than legacy 4× boolean.
- clear reset-to-default action per module.

Restore because they are actual legacy parity gaps:
- Pause Gate named presets.
- Denoiser Wiener/minimum-gain and attack/release customization, preserving named-preset defaults until explicitly overridden.

Do **not** add in PR38 without a separate DSP design/measurement justification:
- compressor auto-makeup;
- compressor detector Peak/RMS switching;
- stereo-link percentage;
- external sidechain routing;
- sidechain solo/audition;
- limiter release-shape modes.

Those are plausible professional features, but “world class” here means useful, measurable behavior—not maximum knob count.

## 10. PR38 acceptance checklist derived from source

Before PR38 can merge:

- every **UI parity** control above is either present in the production workspace or explicitly assigned to another production workspace;
- true **Prod-gap** items implemented in PR38 have validator/test coverage;
- every module OFF state preserves PR35 computational parking semantics;
- live telemetry is independently demand-gated;
- Dynamics no longer routes ordinary users to Engineering Validation for its supported production controls;
- legacy source, not documentation, remains the parity authority;
- a retained PR38 CI guard checks the production module inventory and the key advanced subcontrols.
