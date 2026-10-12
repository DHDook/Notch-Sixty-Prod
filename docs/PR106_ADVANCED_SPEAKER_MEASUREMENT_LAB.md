# PR106 — Advanced Speaker Measurement Lab

Status: **SLICE 1 SOFTWARE VERIFIED — SLICE 2 IMPLEMENTED — EXACT-HEAD CI PENDING**

Base: PR105 Guided Speaker Optimizer & Acoustic Verification.

## Purpose

PR106 turns the measurement foundation built in PR103–PR105 into an advanced
speaker diagnostics surface. It is intentionally a measurement/analysis track,
not another automatic correction or live-DSP expansion.

The lab must never weaken the protection contracts already established for
active crossovers, per-driver limiters, measurement identity or coherent timing.

## Slice 1 — Mode, geometry and safety capability foundation

Available-now diagnostic intents:

- whole-speaker on-axis transfer measurement;
- whole-speaker off-axis/directivity measurement; and
- subwoofer near-field diagnostic measurement.

These modes delegate to the existing PR103 targeted-output safety planner.
Therefore they are available only when that transport can reach the acoustic
source without bypassing active split-driver routing or configured driver
protection.

Mode-specific geometry:

- whole-speaker on-axis: 0.5–5.0 m and within ±10°;
- whole-speaker off-axis: 0.5–5.0 m with at least 10° angular offset;
- subwoofer near-field: 0.01–0.50 m;
- protected-driver near-field: 0.01–0.50 m, but acquisition remains blocked;
- coherent mains/sub timing: 0.5–10.0 m, but acquisition remains blocked.

All lab acquisition protocols require at least the same three repeats as the
Speaker Optimizer evidence foundation.

## Hard safety boundaries

### Protected Low/Mid/High driver buses

Still blocked.

The current targeted calibration transport writes its sweep directly to one
physical output lane. PR106 Slice 1 does not pretend that this preserves an
active crossover or per-driver limiter. A driver-level lab request returns a
specific crossover-preserving-transport requirement and cannot start.

### Coherent mains/sub timing and phase

Still blocked.

PR103/PR104 source-isolated evidence does not independently authenticate a
common source-to-source playback/capture clock origin. A timing/phase lab
request explicitly requires authenticated shared-clock provenance and cannot
start from saved v1 measurements.

### No DSP mutation

Every Slice 1 plan is measurement-only:

- `canDeploy == false`;
- `canMutateDSP == false`;
- no PEQ/FIR/crossover/delay/polarity/limiter state is changed.

## Interpretation limits

- Installed-room whole-speaker measurements are not claimed to be anechoic.
- Off-axis angle is entered physical geometry; software does not infer the mic
  angle.
- Near-field subwoofer response is a local radiator/port diagnostic and does
  not replace listening-position bass integration evidence.
- Physical distance/angle accuracy remains a hardware/user setup gate.

## Slice 1 exact-head verification

Slice 1 exact head `9718cd23e670afd16d903f3c2864e56d073fd19a` passed the
full push workflow, including the PR106/PR105 validators, Apple Silicon Debug
build, targeted capability tests and full XCTest regression.

## Slice 2 — Persistent guided lab sessions

- Adds a separate versioned Advanced Speaker Measurement Lab session model;
  listening-seat identities are not overloaded as fake lab positions.
- Each lab protocol retains its exact measurement mode, acoustic target,
  distance, horizontal/vertical angle and required repeat count.
- Only the currently safe acoustic-source modes may enter live-acquisition
  sessions: whole-speaker on-axis, whole-speaker off-axis and subwoofer
  near-field.
- Protected-driver and coherent mains/sub protocols remain representable by the
  capability layer but are rejected by the Slice 2 acquisition/session model.
- Protocol-major sequencing completes all stationary repeats before the user
  moves to the next geometry.
- Captures are bound to playback-system, routing, microphone, sample-rate,
  protocol, source and repeat identity.
- The persisted analysis keeps the deconvolved impulse response, transfer
  function and quality metadata needed for later lab analysis, but deliberately
  does not persist the raw sweep capture.
- Retry removes only the latest repeat from the selected protocol and makes that
  repeat pending again.
- Session persistence is separate from Speaker Optimizer baseline,
  characterization and verification stores.
- No live transport controller or UI is introduced yet; this slice establishes
  the durable guided-session/evidence contract.

## Planned follow-on slices

1. Live lab transport/controller for the currently safe acquisition modes.
2. Repeat-qualified response overlays and on-axis/off-axis directivity analysis.
3. Near-field subwoofer/port diagnostics and merge-safe low-frequency analysis.
4. Quasi-anechoic gated response tools with explicit reflection-window limits.
5. Distortion/nonlinearity diagnostics from bounded excitation where the current
   capture chain can support defensible metrics.
6. Crossover-preserving protected-driver excitation path.
7. Authenticated shared-clock reference capture for coherent relative timing and
   phase diagnostics.
8. Production Advanced Speaker Measurement Lab UI and export/reporting.
