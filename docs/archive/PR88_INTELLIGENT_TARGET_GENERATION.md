# PR88 — Intelligent Automatic Target-Curve Generation

PR88 adds a deterministic, explainable target-curve generator for Room Correction and automatic multichannel calibration.

## Goal

Generate a perceptually sensible starting target from the measured system instead of forcing users to choose only a static built-in/imported curve.

The generator must be conservative: it should describe a desirable listening-room trend that the measured loudspeaker/room system can realistically approach, not trace room modes or turn every measurement defect into a correction request.

## Inputs

- weighted multi-position room response
- per-position measurement quality and usable-band limits
- speaker/subwoofer measurements where available
- correction boost/cut limits
- measured spatial variance
- measured bass extension / roll-off
- broad high-frequency trend
- available correction bandwidth
- optional user preference profile

## Output

An ordinary `RoomCorrectionTargetCurve` plus an explainable generation report containing:
- derived bass shelf
- derived midrange reference level
- derived treble tilt
- effective target bandwidth
- confidence
- safety clamping decisions
- warnings / reasons for fallback behavior.

Generated targets use the same existing target representation as built-in/imported targets. No new target type reaches the DSP engine.

## Design principles

1. **Do not fit narrow room structure.** Analysis uses heavy fractional-octave smoothing and low-order trend extraction.
2. **Do not ask for impossible bass.** Low-frequency target extension follows measured usable bandwidth and roll-off with bounded lift.
3. **Do not force flat in-room treble.** The generator derives a gentle downward high-frequency trend within perceptual bounds.
4. **Do not normalize to pathological peaks/nulls.** Reference level uses robust statistics over a stable midband.
5. **Respect spatial disagreement.** Frequencies with high seat-to-seat variance reduce target aggressiveness.
6. **Respect correction limits.** Target shape is clamped before FIR/PEQ design so requested boosts remain bounded.
7. **Stay explainable and deterministic.** Same inputs + preferences produce the same target/report.
8. **Remain control-plane only.** Target generation performs no realtime work.

## Initial preference profiles

- Neutral — conservative room-adapted target with modest bass support and natural treble decline.
- Warm — slightly stronger low-frequency shelf and slightly steeper high-frequency decline.
- Studio — least bass lift and shallowest tilt, while still avoiding an unrealistically flat in-room high-frequency target.

These are bounded preference priors, not fixed curves; room/speaker evidence remains authoritative.

## PR86 integration

PR88-generated targets remain candidates until PR86 prediction verifies the resulting calibration. Automatic target generation never bypasses the independent deployment gate.

## Safety bounds

Initial generation bounds:
- target reference band: approximately 300–2,000 Hz, constrained to measured usable bandwidth
- maximum generated bass shelf: +4 dB relative to reference
- minimum generated bass shelf: 0 dB for Neutral/Studio, +0.5 dB nominal prior for Warm when supported
- high-frequency target decline at 20 kHz: bounded between -1 dB and -4 dB relative to 1 kHz
- no generated target point requests a correction beyond the configured maximum boost/cut when evaluated against the heavily smoothed aggregate
- target bandwidth never extends beyond trustworthy measured usable bandwidth
- low-confidence evidence produces a conservative fallback target and an explicit warning

## Non-goals

PR88 does not perform machine learning, cloud inference, room-type guessing, or opaque personalization. It does not replace user-imported/custom targets. It provides a high-quality automatic starting point that remains editable and verifiable.
