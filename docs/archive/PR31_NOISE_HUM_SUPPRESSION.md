# PR31 — Noise Reduction & Mains-Hum Suppression

## Purpose

PR31 continues advanced-DSP parity with a coherent early-chain cleanup subsystem:

1. tonal mains-hum suppression; and
2. stationary broadband-noise reduction.

The implementation is proprietary clean-room work. Legacy materials are used only to establish externally observable controls, ranges, defaults, and workflows.

## Observable product contract

### Mains Hum Notch

The legacy user-facing contract establishes:

- enable/bypass;
- nominal Region: 50 Hz or 60 Hz;
- one-shot Detect of the actual fundamental;
- optional Continuous Tracking;
- Harmonics: 1–16, legacy default 8;
- Q: 5–60;
- independent per-harmonic depth from 0 to −40 dB;
- intended use: electrical hum/buzz with a tonal harmonic structure;
- chain position before spectral denoising so a strong tonal contaminant does not bias the broadband noise-floor estimate.

### Spectral Denoising

The legacy user-facing contract establishes:

- enable/bypass;
- presets: Natural, Standard, Aggressive, Dehiss, with Custom when edited manually;
- Reduction Amount: 0–100%;
- Threshold/noise-floor safety control;
- Quality modes: Quality, High, Ultra;
- optional protected frequency range;
- noise-profile Capture and Reset workflow;
- intended use: stationary broadband noise such as tape hiss, vinyl surface noise, room tone, and codec/static artefacts.

Observable legacy preset bundles used only as product-state defaults:

| Preset | Threshold | Reduction | Quality | Protected range |
|---|---:|---:|---|---|
| Natural | −72 dBFS | 50% | High | off |
| Standard | −60 dBFS | 50% | High | off |
| Aggressive | −48 dBFS | 50% | High | off |
| Dehiss | −58 dBFS | 40% | High | 0–150 Hz protected |

The commercial implementation may improve internal mathematics while preserving the user need and observable workflow.

## Clean-room boundary

Do **not** use these historical files as implementation templates:

- `SpectralDenoiser.swift`
- `MainsHumDetector.swift`
- `GoertzelEstimator.swift`
- `MainsNotchCoefficients.swift`
- historical DSP implementation tests

Independent implementation sources should be public DSP literature/specifications, mathematical derivation, and independently generated synthetic test vectors.

## Commercial architecture

- C owns the realtime sample-processing/data plane.
- Swift owns product/control state, UI, preparation, capture commands, and telemetry presentation.
- Runtime memory is fixed/preallocated.
- No render-callback allocation/free, locks, logging, file/device I/O, UI work, or configuration construction.
- Parameter/state publication is immutable or bounded and click-safe.
- Mains hum suppression precedes spectral denoising in the processed graph.
- Processed / latency-matched Reference / Delta and Global Bypass semantics from PR25 remain authoritative.
- Any denoiser algorithmic latency must be explicit in graph latency accounting.

## Validation UI requirement

PR31 must ship its engineering acceptance controls in a dedicated **PR31 Noise / Hum** tab before a hardware DMG is generated. Do not repeat the PR30 discoverability problem.

Minimum validation surface:

- Mains Notch enable;
- 50/60 Hz region;
- Detect;
- Continuous Tracking;
- harmonic count;
- Q;
- per-harmonic depths;
- measured/tracked fundamental + confidence telemetry;
- Denoiser enable;
- preset;
- reduction amount;
- threshold;
- quality;
- protected frequency range;
- Capture / Reset profile;
- noise-estimate / suppression telemetry;
- total DSP latency.

## Acceptance gates

- disabled processors are transparent;
- deterministic 50/60 Hz and harmonic suppression tests;
- notch Q/depth/harmonic-count behavior is monotonic and bounded;
- detector/tracker remains bounded and does not chase ordinary program material;
- stationary synthetic broadband noise is reduced without unexplained broadband attenuation;
- stereo image remains stable;
- adaptive and captured-profile workflows remain deterministic and bounded;
- quality modes have explicit latency/CPU contracts;
- transitions are click-safe;
- supported high-rate behavior is tested through 384 kHz;
- PR25–30 behavior does not regress;
- focused hardware/listening acceptance before merge.

## Deferred

- mixed/excess-phase correction remains in the room-correction milestone because it requires phase-resolved measurements;
- independent sub/driver phase alignment remains dependent on physical routing;
- explicit SRC remains subject to later parity/product classification.


## Slice 2 implementation — mains detection and tracking

The commercial detector is an independently authored fixed-bank quadrature estimator. The realtime path decimates to approximately 1 kHz, evaluates 25 frequencies at 0.25 Hz spacing across a ±3 Hz window around the selected 50/60 Hz region, and publishes the strongest-bin estimate plus a bounded spectral-prominence confidence value once per approximately one-second window. It does not copy or adapt the legacy detector implementation.

One-shot **Detect** is a control-plane operation: it applies the latest estimate only above a confidence threshold. **Continuous Tracking** polls the same telemetry at a bounded cadence, requires a stronger confidence threshold, rejects negligible changes, and republishes coefficients on the control plane. The realtime notch owns dual old/new filter banks and crossfades coefficient retunes over roughly 10 ms so tracking never redesigns filters inside the render callback and does not hard-switch IIR coefficients/state.


## Slice 3 — spectral denoiser implementation

The commercial denoiser is an independent clean-room redesign. The legacy application supplies only the observable preset/control inventory; its `SpectralDenoiser` implementation and tests are not implementation references.

### Signal architecture

- Mains-notch cleanup runs first so coherent 50/60 Hz energy and selected harmonics do not contaminate broadband noise estimation.
- The denoiser uses a 50%-overlapped weighted overlap-add (WOLA) STFT with a square-root Hann analysis/synthesis pair.
- Linked stereo uses one common spectral gain per bin, derived from the larger L/R bin power, while preserving each channel's complex phase. This prevents independent-channel noise decisions from wandering the stereo image.
- Suppression uses a conservative decision-directed Wiener-style gain estimate, bounded by a preset-specific gain floor, plus temporal and modest neighboring-bin smoothing to reduce musical-noise artifacts.
- The protected-frequency range forces unity spectral gain inside the selected range.
- Dehiss increases the noise estimate progressively above roughly 3 kHz rather than applying a broadband extra cut.

### Noise profile behavior

Two workflows exist deliberately:

1. **Adaptive:** low-envelope/minimum statistics learn only bins at or below the Threshold safety ceiling. Clearly above-threshold program bins are not admitted into the adaptive noise model. Upward movement of the learned floor is bounded to approximately +1 dB per one-second estimator block.
2. **Capture:** an explicit user request measures roughly one second and freezes that spectrum as the profile. Capture intentionally bypasses the adaptive threshold gate because the user is declaring the passage to be noise-only; the Threshold still caps suppression-time assumed noise power.

Reset discards the captured profile and returns to conservative adaptive learning. Changing Quality changes the spectral grid and therefore resets the runtime profile.

### Quality / latency contract

| Mode | FFT | Hop | Added denoiser latency |
|---|---:|---:|---:|
| Quality | 1024 | 512 | 1024 frames |
| High | 2048 | 1024 | 2048 frames |
| Ultra | 4096 | 2048 | 4096 frames |

At 96 kHz, those added latencies are approximately 10.67 ms, 21.33 ms, and 42.67 ms. The graph publishes the chosen latency so Processed / Reference / Delta remain aligned. Enabling/disabling the denoiser and changing Quality while active use the graph-transition path rather than a hard live latency change.

### Realtime contract

- portable C hot path
- fixed/preallocated FFT, window, spectral, overlap-add, profile, and telemetry state
- no heap allocation/free, locks, logging, device/file I/O, or filter/FFT-plan construction in the render callback
- FFT/window tables are built at runtime creation on the control side
- exact input passthrough when disabled; analysis/profile state remains warm
- full graph tests include latency accounting, WOLA unity reconstruction against latency-matched Reference, linked-stereo behavior, program-content resistance, protected-band behavior, stationary-noise reduction, and finite 384 kHz operation

### Validation intent

The old denoiser's audible artifacts are not a parity target. Hardware acceptance prioritizes naturalness: noise reduction must not introduce pumping, chirping/musical noise, transient softening, vocal smearing, or stereo-image movement. Natural is the conservative baseline; Aggressive is a stress mode.
