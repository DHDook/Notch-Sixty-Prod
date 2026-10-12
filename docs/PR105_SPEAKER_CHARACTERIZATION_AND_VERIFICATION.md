# PR105 — Guided Speaker Characterization & Verification

Status: **SLICE 1 VERIFIED; SLICE 2 IMPLEMENTED — EXACT-HEAD CI PENDING**

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

## Slice 2 — Bounded early-window characterization

- Derives an additional response from the in-memory deconvolved impulse before
  compact persistence discards raw capture and impulse buffers.
- Default gate keeps 0.75 ms before the direct-arrival peak and 6.0 ms after it,
  with a 1.5 ms raised-cosine tail.
- The gate is an explicit analysis assumption; PR105 does not claim to detect
  the first room reflection or produce a true anechoic/free-field response.
- The trusted low-frequency boundary is derived from gate duration. The default
  requires two complete periods inside the 6 ms post-arrival window (~333 Hz)
  and then snaps to the actual analyzed frequency grid.
- The result is magnitude-only. Windowed phase is discarded so it cannot enter
  crossover, polarity or synchronized timing decisions.
- The same microphone calibration curve is explicitly reapplied to the gated
  impulse-derived magnitude, and the characterization microphone calibration
  identity is retained in the compact evidence.
- A late reflection outside the gate is rejected from the derived magnitude in
  deterministic tests; frequencies below the gate-derived boundary continue to
  rely on the ordinary listening-position campaign.
- Compact characterization persistence stores only the derived frequency
  response and audit metadata, never the raw sweep or impulse response.

## Planned follow-on slices

1. Correlate speaker-characterization features against multi-seat features to
   classify source-persistent vs seat/room-dependent deviations.
3. Integrate classification into PEQ/FIR ranking so room-specific nulls cannot
   masquerade as loudspeaker defects.
4. Add guided UI workflow under SYSTEM → Speaker Calibration.
5. Continue explicit Apply / rollback / new measured verification.

Physical testing remains required for actual mic-distance guidance, integration
distance for unusual loudspeakers, reflection-window limits and safe/beneficial
correction.
