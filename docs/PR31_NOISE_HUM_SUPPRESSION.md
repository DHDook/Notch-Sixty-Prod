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
