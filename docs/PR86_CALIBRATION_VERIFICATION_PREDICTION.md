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
