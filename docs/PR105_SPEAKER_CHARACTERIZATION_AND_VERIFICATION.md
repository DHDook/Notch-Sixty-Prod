# PR105 — Guided Speaker Characterization & Verification

Status: **SLICES 1–2 REMOTE SOFTWARE VERIFIED — PHYSICAL ACOUSTIC ACCEPTANCE PENDING**

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

## Slice 2 exact-head verification

Slice 2 code at `3052415b759b86f483b36e90651d9659add380cf` passed both
GitHub Actions paths:

- push run 38204073457;
- pull-request run 38204076224.

Both runs passed the PR105/PR104/PR103 contract validators, Apple Silicon Debug
build, targeted Speaker Optimizer characterization tests, and full XCTest
regression. This documentation-only checkpoint creates a subsequent head that
must pass the same workflow before it is treated as the final verified Slice 2
handoff.

Physical microphone distance, loudspeaker integration distance, actual room
reflection timing and acoustic benefit remain unverified.

## Slice 3 — Cross-domain speaker-vs-room classification

- Requires BOTH the ordinary listening-position baseline and the separately
  qualified characterization campaign to pass their existing evidence gates.
- Compares local response SHAPE rather than absolute dB. A ~1 m capture and a
  listening-seat capture have different propagation gain, so direct absolute
  level subtraction would be invalid.
- Each domain is reduced to residual response around a 1/3-octave
  log-frequency-smoothed local trend.
- A feature is `speakerPersistent` only when a significant near-speaker
  deviation appears in the same direction and magnitude at the listening
  positions with low seat-to-seat spread.
- A feature is `roomSeatDependent` when characterization is locally
  flat but the listening area has a strong deviation or strong seat variation.
- Disagreement or insufficiently decisive evidence remains `ambiguous`.
- Flat regions are explicitly `noMaterialDeviation`; the classifier does
  not manufacture a speaker defect merely because two data sets exist.
- Classification is constrained to the early-window reliable frequency band.
  Frequencies below that boundary remain listening-position evidence only.
- Classification is preview/advisory evidence: `canDeploy == false`. It
  never authorizes PEQ/FIR, timing, polarity, crossover or live DSP mutation.

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
