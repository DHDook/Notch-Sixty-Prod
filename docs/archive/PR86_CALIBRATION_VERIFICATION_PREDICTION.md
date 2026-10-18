# PR86 — Automatic Calibration Verification & Prediction

PR86 adds an independent offline verification layer between automatic calibration design and deployment.

## Goals

- Re-simulate the actual deployable trim, delay, polarity and PEQ settings against every captured seat/source transfer function.
- Compare predicted before/after response to the selected target on a common logarithmic grid.
- Quantify per-seat and per-source residual error, worst-case regression, spatial variance, timing alignment and measurement confidence.
- Fail closed when evidence is incomplete, low-confidence, non-finite, out of usable bandwidth, or predicts material regression.
- Keep prediction and verification entirely off realtime. Realtime receives only already-verified immutable calibration state.

## Independence

The verifier must not trust the designer's headline pre/post RMS values. It recomputes the deployed response from the persisted measurements and materialized calibration settings, providing a second implementation path capable of detecting designer/materialization drift.

## Confidence model

Confidence combines:
- capture SNR and clipping/sweep-complete state
- usable-band coverage
- phase availability
- seat coverage and weighting
- target-band sample coverage
- agreement between independent predicted RMS and designer-reported RMS

Deployment requires an accepted prediction report. Reports retain blocking reasons and warnings for UI diagnostics.

## Safety thresholds

Initial conservative defaults:
- no clipped or incomplete captures
- minimum per-measurement SNR: 30 dB
- minimum confidence: 0.70
- predicted weighted RMS must improve by at least 0.25 dB
- no source may regress in RMS by more than 0.25 dB
- no seat may regress in RMS by more than 0.75 dB
- maximum post-correction absolute target error: 12 dB
- designer/verifier post-RMS disagreement tolerance: 0.75 dB

These gates validate expected behavior before deployment; they do not replace later repeat-measurement verification on physical hardware.


## Room Correction deployment verification

PR86 applies the same commit-barrier principle to generated Room Correction FIR designs.

The room verifier does not trust the design's stored predicted response as its source of truth. It:
- computes the frequency response of the exact FIR taps that will be deployed;
- applies the deployed, headroom-scaled left/right FIR response to every source listening-position transfer function;
- evaluates weighted before/after target-shape RMS, per-position regressions, maximum residual and stereo response matching;
- scores confidence from clipping, sweep completeness, SNR, usable-band coverage and source-position coverage;
- audits unscaled FIR positive gain against declared headroom;
- confirms the actual scaled deployment FIR has no material positive gain;
- checks out-of-band FIR leakage;
- reconstructs the weighted source aggregate and cross-checks stored prediction metadata against the actual unscaled FIR.

Room Correction deployment is controller-owned and fail closed: a fresh accepted verification report is recomputed immediately before the Playback System profile is changed. A stale UI badge cannot authorize deployment.

This remains a pre-deployment prediction layer. Physical repeat-measurement after correction remains the later empirical verification step when hardware access is available.
