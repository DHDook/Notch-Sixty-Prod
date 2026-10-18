# PR34 — DSP Optimization, Enhancement, and Comprehensive Legacy Parity Audit

## Base

- `main`: `5ba227e1fc3b2f1a60940ba810eedca34e653ceb`
- Swift remains the product/control plane.
- Portable C remains the realtime DSP/data plane.
- PR33 closed the known dynamics/conditioning inventory, but PR34 must independently verify full-product parity from the legacy codebase before parity can be considered proven.

## Slice 0 — Comprehensive legacy source-level parity audit

This audit must not rely on the legacy user guide alone.

Audit the legacy repository using:

- recursive source tree
- app/state/configuration models
- UI wiring
- DSP module inventory
- routing/output-channel models
- preset and migration models
- measurement/room-correction code
- meters/RTA/analytics code
- device/sample-rate/volume code
- deterministic tests as evidence of externally observable behavior

### Clean-room restriction

Legacy source may be read to establish:

- feature existence
- state/configuration shape
- user-visible controls and modes
- UI reachability
- pipeline placement at a behavioral level
- observable test contracts

Do **not** copy, translate, adapt, or use historical DSP implementation expression as an implementation template.

### Audit classifications

Every identified capability must end in exactly one category:

1. **IMPLEMENTED / IMPROVED** — commercial product already covers the capability.
2. **LATER MILESTONE** — capability is required but explicitly belongs to an existing later milestone; name it.
3. **OUT OF CURRENT PRODUCT SCOPE** — excluded by current product directive.
4. **MISSING / BLOCKER** — required parity capability has no current implementation or roadmap disposition.
5. **LEGACY-DEAD / UNREACHABLE** — source exists but is not wired into reachable product behavior; this classification requires source-level evidence.

### Audit domains

- EQ/filter types, per-band controls, linked/independent channel behavior, minimum/linear/all-pass behavior
- dynamics / conditioning / protection
- oversampling / limiter / clipping / true peak
- denoising / mains-hum suppression
- FIR / convolution / external IR loading
- bass management / crossover / driver protection / alignment / crossover analysis utilities
- routing / output-channel matrix / secondary-output behavior
- room correction / microphone measurement / multi-seat workflows / target curves / dataset persistence
- measurement views: impulse, step, group delay, energy decay
- metering / RTA / goniometer / analytics
- presets / persistence / migrations / factory presets / interchange
- REW / AutoEQ / CamillaDSP / EasyEffects support
- device selection / sample-rate handling / volume / route recovery
- compare/reference/audition behavior
- explicit sample-rate conversion / cross-device clock-drift handling
- app-level controls and settings not represented in user documentation

## Initial tree-level findings to investigate

The recursive legacy tree already proves that the audit must cover more than the user guide. In addition to already-known processors, source modules include:

- `src/dsp/crossover/AcousticSummationEngine.swift`
- `src/dsp/crossover/ActiveCrossoverEngine.swift`
- `src/dsp/crossover/BaffleStepCalculator.swift`
- `src/dsp/crossover/CrossoverGroupDelayEngine.swift`
- `src/dsp/crossover/CrossoverOptimiser.swift`
- `src/dsp/crossover/CrossoverPathAlignmentEngine.swift`
- `src/dsp/crossover/DiaphragmResonanceDetector.swift`
- `src/dsp/crossover/DriverTimeAlignmentEngine.swift`
- `src/dsp/crossover/ExcursionProtectionLimiter.swift`
- `src/dsp/mixedphase/AdaptiveExcessPhaseCorrector.swift`
- `src/dsp/roomcorrection/BandLevelCalibrationEngine.swift`
- `src/dsp/roomcorrection/ExcessPhaseCorrector.swift`
- `src/dsp/roomcorrection/MicCalibrationLoader.swift`
- `src/dsp/roomcorrection/SweepAnalyser.swift`
- `src/dsp/roomcorrection/TargetCurveLibrary.swift`
- `src/dsp/roomcorrection/TransferFunctionDatasetStore.swift`
- `src/dsp/src/SRCProcessor.swift`
- `src/meters/GoniometerEngine.swift`
- `src/meters/RTAAnalyzer.swift`
- `src/pipeline/hal/SecondaryOutputWriter.swift`
- `src/pipeline/routing/DeviceClockPLL.swift`
- `src/pipeline/routing/PLLSRCWriter.swift`
- `src/routing/OutputChannelMatrixConfig.swift`
- `src/presets/MultiChannelCorrectionPresetManager.swift`
- measurement UI for impulse response, step response, group delay, and energy decay

These are **audit leads**, not automatic parity requirements. Each must be checked for reachability, observable behavior, and current product scope.

## Slice 1 — Performance baseline

After the parity inventory is sufficiently stable, establish repeatable performance fixtures at:

- 48 kHz
- 96 kHz
- 192 kHz
- 384 kHz

Profile:

- average render CPU
- worst-case callback time
- buffer-size sensitivity
- memory footprint / working set where practical
- per-stage timing where instrumentation can remain representative

Required stress cases include:

- many static EQ bands
- 64 supported Dynamic EQ bands
- Dynamic EQ Peak and RMS detection
- denoiser Quality / High / Ultra
- 4× protection oversampling
- multiband + compressor + De-Esser + dialogue processing
- FIR / convolution
- room-correction runtime
- worst coherent supported combination

## Slice 2+ — Measured optimization / enhancement

Only optimize measured hotspots. Candidate work includes:

- denoiser FFT and spectral loops
- Accelerate/vDSP benchmark against the current independent FFT
- NEON/vectorized spectral and FIR loops where justified
- convolution/FIR kernels
- oversampling/protection kernels
- Dynamic EQ loop/state layout
- cache / memory layout
- control-plane precomputation
- removal of redundant work while bypassed/inactive

Accepted sonic baselines must be preserved, especially PR31 denoiser transparency and PR27 protection/unity behavior.

## Exit gates

PR34 cannot close until:

- the source-level legacy parity ledger is complete enough that no unexplained capability remains
- any newly discovered required gap is implemented or explicitly assigned to an existing roadmap milestone
- missing work is not silently relabeled as superseded
- performance baseline vs optimized results are documented
- realtime-safety invariants remain intact
- deterministic high-rate tests remain green
- structural audio changes receive focused hardware validation
