# PR105 — Guided Speaker Characterization & Verification

Status: **SLICE 1 IMPLEMENTED — EXACT-HEAD CI PENDING**

Base: PR104 measurement-driven Speaker Optimization Engine.

## Why this prerequisite exists

The existing Speaker Optimizer listening-position campaign deliberately measures
each whole speaker/subwoofer separately at listener seats. That is excellent for
in-room optimization and system integration, but it still contains room and
placement response.

PR105 adds a SECOND, independently typed evidence domain for whole-speaker
characterization. It is intended to help later logic distinguish response traits
that follow the loudspeaker from effects that vary strongly by listening seat.
This is not an anechoic measurement claim.

## Slice 1 — Geometry-bound whole-speaker characterization foundation

- One movable calibrated microphone.
- Whole loudspeakers only; subwoofers remain listening-position measurements
  because room modes dominate their useful integration evidence.
- The speaker remains in its normal installed position.
- Default mic distance 1.0 m. Accepted geometry 0.75–2.0 m and within ±10°
  of the selected acoustic/tweeter/manufacturer axis.
- Geometry is persisted per acoustic source. Capture position identity is the
  characterization target ID, so near-speaker evidence cannot be mistaken for
  a listening seat.
- Three stationary repeated sweeps per speaker before moving the microphone.
- Qualification reuses PR103's exact repeated-sweep evidence evaluator: SNR,
  clipping, magnitude repeatability, arrival stability, common usable bandwidth
  and inter-repeat phase consistency.
- Characterization may link to a listening-position baseline, but pairing
  requires the same playback system, route, microphone/calibration and sample
  rate.
- Separate compact persistence; no raw sweep or impulse buffers are retained.

## Safety and interpretation

A 1 m installed-room sweep is still speaker + nearby boundaries + room. It is
expected to be less seat-dependent than a couch measurement, not a true
free-field or anechoic response.

No filter design consumes this new domain in Slice 1. No playback DSP,
crossover, polarity, delay or limiter is modified.

Protected Low/Mid/High driver buses remain blocked. We characterize the whole
speaker only through an already safe acoustic-source route.

## Planned follow-on slices

1. Add an explicitly bounded early-window characterization response derived
   before compact persistence, with microphone calibration retained.
2. Correlate speaker-characterization features against multi-seat features to
   classify source-persistent vs seat/room-dependent deviations.
3. Integrate classification into PEQ/FIR ranking so room-specific nulls cannot
   masquerade as loudspeaker defects.
4. Add guided UI workflow under SYSTEM → Speaker Calibration.
5. Continue explicit Apply / rollback / new measured verification.

Physical testing remains required for actual mic-distance guidance, integration
distance for unusual loudspeakers, reflection-window limits and safe/beneficial
correction.
