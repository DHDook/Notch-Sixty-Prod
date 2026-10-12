# PR106 — Advanced Speaker Measurement Lab

Status: **SLICES 1–7 SOFTWARE VERIFIED — SLICE 8A CI PENDING**

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

## Slice 3 — Safe live lab acquisition controller

- Reuses the existing targeted calibration transport and measurement analyzer for
  the currently safe lab modes.
- Revalidates Playback System, routing, microphone, sample rate and PR106
  capability safety immediately before every sweep.
- A protocol that was safe when persisted cannot bypass a later active
  crossover or configured driver limiter.
- Persists analyzed impulse/transfer/quality evidence after each completed
  repeat and retains protocol-major guided sequencing.
- Protected-driver and coherent mains/sub modes remain blocked.

Slice 3 exact head `9c60b2200ae409c0175638814e2039dd560b4261`
passed push run 38212282109 and pull-request run 38211449534, including the
PR106/PR105 validators, Apple Silicon Debug build and full XCTest regression.

## Slice 4 — Repeat-qualified installed-room directivity comparison

- Requires a qualified whole-speaker on-axis reference and one or more qualified
  whole-speaker off-axis protocols for the SAME acoustic source.
- Reuses the PR103/PR105 repeated-sweep evidence evaluator, so clipping,
  incomplete sweeps, low SNR, unstable magnitude/timing/phase and insufficient
  common bandwidth fail closed before a trace is produced.
- Requires on-axis/off-axis protocols to use materially the same microphone
  radius (default tolerance: max of 2 cm or 3% of reference distance).
- Requires one shared finite frequency grid and computes the common qualified
  usable band across all compared captures.
- Reports off-axis minus on-axis magnitude curves, angular geometry, mean
  relative level and evidence confidence.
- Supports multiple off-axis protocols and sorts traces by angular offset for
  deterministic overlay rendering.
- Deliberately does NOT claim anechoic/free-field response, spinorama, sound
  power, beamwidth or polar accuracy. The curves are installed-room relative
  comparisons using user-entered geometry.
- Measurement-only: no correction design, deployment authority or DSP mutation.

## Slice 4 exact-head verification

Slice 4 exact head `aaca1c0daae3c4057cb174374d36868fe60943a1` passed both
GitHub Actions paths:

- push run 38215667150;
- pull-request run 38215670744.

Both paths passed PR106/PR105 validators, Apple Silicon Debug build, targeted
measurement-lab tests and full XCTest regression.

## Slice 5 — Repeat-qualified near-field LF component diagnostics

- A subwoofer near-field protocol may optionally identify the physical component
  as radiator, port, passive radiator or other and may retain an explicit
  effective radiating area for future physically justified splicing.
- Existing persisted Slice 2 sessions remain valid because component metadata is
  optional.
- Every selected near-field protocol must independently pass the inherited
  repeated-sweep quality gates before LF analysis is produced.
- Analysis is deliberately bounded to a configurable low-frequency ceiling
  (500 Hz default) and the common qualified usable band.
- Reports repeat-averaged local magnitude, circular-mean local phase, dominant
  local magnitude peak and component-relative magnitude/phase traces.
- Multiple protocols must measure the same physical subwoofer source.
- The merge assessment explicitly checks whether area metadata and phase are
  available, but `canSynthesizeFarFieldComposite == false` in this slice.
- The lab NEVER sums radiator/port magnitudes in dB. Separate near-field
  positions do not establish a far-field propagation/phase reference, and a
  listening/far-field anchor is still required before any component splice can
  represent system bass response.
- Near-field LF diagnostics remain measurement-only and cannot design/apply DSP.

## Slice 5 exact-head verification

Slice 5 exact head `6d5723bd58d7dc22ca2c6ea65e91c34c6a810be8` passed push run 38220002851 and pull-request run 38220006969, including PR106/PR105 validators, Apple Silicon Debug build, targeted lab tests and full XCTest regression.

## Slice 6 — Explicit reflection-window quasi-anechoic estimate

- New Lab sessions persist the selected microphone calibration curve so impulse-derived gated magnitude can reproduce calibrated transfer magnitude; legacy sessions remain readable.
- A calibrated legacy session without the persisted curve fails closed for this analysis.
- Whole-speaker on-axis/off-axis protocols use already stored deconvolved impulses; no new excitation path is added.
- The post-arrival reflection-free duration is an explicit assumption. Software does not claim automatic first-reflection detection.
- The report exposes direct arrival, assumed reflection boundary, window parameters, repeat traces and the gate-derived trust band.
- Default 6 ms / two-cycle settings imply a ~333 Hz low-frequency boundary before snapping to the measured grid; shorter windows raise it.
- Late energy outside the selected gate is excluded.
- Microphone calibration is reapplied to the gated impulse transform.
- Gated phase is not published; this remains magnitude-only and cannot become crossover/timing evidence.
- `isQuasiAnechoicEstimate == true`, `isAnechoic == false`, and `canDeploy == false` are explicit.

## Slice 6 exact-head verification

Slice 6 exact head `9c8e726a5d6ee5eadb289aea5917f2072341cefa` passed both
GitHub Actions paths:

- push run 38221077102;
- pull-request run 38221082494.

Both paths passed the PR106/PR105 validators, Apple Silicon Debug build,
targeted measurement-lab tests and full XCTest regression.

## Slice 7 — Bounded two-level transfer level-dependence diagnostic

- Lab protocols may optionally persist an explicit sweep excitation level.
  Explicit lab levels are bounded to -48...-12 dBFS; legacy protocols with no
  explicit level continue using the ordinary measurement-controller setting.
- Each capture persists the actual sweep-program level when known, and an
  explicit-level protocol rejects captures whose level provenance does not
  match.
- The live Lab controller uses the protocol's explicit level for acquisition
  and records the exact program level on the resulting capture.
- Level-dependence analysis currently requires two whole-speaker on-axis
  protocols for the same acoustic source and essentially the same geometry.
- Both protocols independently pass the inherited repeated-sweep SNR, clipping,
  repeatability, timing, phase and usable-band gates.
- The excitation step must be bounded (6–18 dB by default).
- Because each transfer function is deconvolved by its own exact excitation, a
  linear chain should produce the same normalized transfer at both levels.
  The report exposes high-minus-low normalized transfer, broadband transfer
  shift, shape-only level dependence, RMS shape change, localized compression
  and expansion diagnostics.
- Broadband shift is deliberately NOT certified as intrinsic loudspeaker
  compression because untracked playback-gain drift between protocol groups can
  produce the same symptom.
- The current capture model does not retain nonlinear harmonic slices needed
  for defensible harmonic/intermodulation distortion estimates. The report
  explicitly declares `isTHDMeasurement == false` and
  `isIMDMeasurement == false`.
- Excitation is digital dBFS, not calibrated acoustic SPL. No compression SPL
  threshold or loudspeaker defect certification is claimed.
- Measurement-only: `canDeploy == false`.

## Slice 7 exact-head verification

Slice 7 exact head `a5981be2049263eb85c4ca5436b9bdc57dda84d9` passed both
GitHub Actions paths:

- push run 38222284730;
- pull-request run 38222289440.

Both paths passed the PR106/PR105 validators, Apple Silicon Debug build,
targeted measurement-lab tests and full XCTest regression.

## Slice 8A — Exact protected-driver excitation compiler substrate

- Adds a control-plane C renderer that calls the SAME production speaker-bus
  splitter routine used by live playback and then the SAME production
  per-driver processor used for EQ/trim/polarity/delay/limiter protection.
- The C renderer accepts only split Low/Mid/High buses produced by Bi-Amp or
  Tri-Amp crossover snapshots. Full-range, Sub and Mains+Sub targets are
  rejected.
- The exact target driver bus must be enabled AND limiter-protected. A direct
  driver measurement cannot silently downgrade to crossover-only protection.
- The Swift compiler additionally requires a bounded input peak (-24 dBFS by
  default) and rejects empty, non-finite or silent programs.
- The input is padded with a bounded control-plane flush interval so configured
  driver delay and crossover/driver IIR ring-out are included rather than
  silently truncating the protected waveform.
- The result retains the exact Bass Management and per-driver configuration
  used to render the program so the later transport slice can detect any state
  drift before hardware output.
- Deterministic tests verify high-pass/low-pass isolation, Tri-Amp Mid support,
  limiter capping, limiter-required fail-closed behavior, target restrictions,
  hot/non-finite rejection and preservation of the existing Lab live block.
- IMPORTANT: Slice 8A does NOT unblock `.protectedDriverNearField`.
  The current raw physical-lane calibration transport remains blocked until
  Slice 8B binds this pre-rendered program to one exact physical route and
  revalidates the crossover/driver state immediately before playback.
- Measurement-only; no DSP mutation and `canDeploy == false`.

## Slice 8A exact-head verification

Slice 8A exact head `7ebf3f3dff74f757652e154457fae8a699992c4e` passed both
GitHub Actions paths:

- push run 38223410879;
- pull-request run 38223416865.

Both paths passed the PR106/PR105 validators, Apple Silicon Debug build,
targeted Lab tests and full XCTest regression.

## Slice 8B — Live crossover/limiter-preserving protected-driver acquisition

- The dedicated protected path never changes PR103's legacy raw-output planner;
  protected Low/Mid/High requests use a separate PR106 route binding.
- Live availability requires exactly one enabled physical route for the target
  Low/Mid/High bus, an active Bi-Amp/Tri-Amp crossover that produces that bus,
  and an enabled limiter on that exact driver-processing path.
- Direct-driver protocols require an explicit bounded excitation level no hotter
  than -24 dBFS. They cannot inherit a potentially hotter general Lab default.
- The exact upstream ESS is rendered offline through the production crossover
  and production driver EQ/trim/polarity/delay/limiter chain from Slice 8A.
- The existing bounded Core Audio measurement bridge plays only that
  pre-rendered protected waveform to one exact physical route while zeroing all
  other output lanes.
- The analyzer still deconvolves against the ORIGINAL upstream ESS. The
  crossover/driver protection transfer therefore remains part of the measured
  response rather than being divided away.
- The rendered flush extension becomes additional capture tail, preserving
  driver delay and IIR ring-out without changing the deconvolution reference.
- Immediately before hardware start, the controller re-reads and exactly checks
  Playback System identity, physical routing, crossover configuration, complete
  driver-processing configuration and selected reference output.
- Every protected capture persists exact bus/physical-route/crossover/limiter
  provenance. Repeats for one protocol must share the same provenance.
- The persisted acoustic source remains the parent Left/Right speaker for common
  Lab analysis, while protected provenance retains the exact Low/Mid/High bus.
- This remains measurement-only: no crossover, limiter, EQ or routing state is
  mutated and `canDeploy == false`.

## Planned follow-on slices

1. Authenticated shared-clock reference capture for coherent relative timing and
   phase diagnostics.
2. Production Advanced Speaker Measurement Lab UI and export/reporting.
