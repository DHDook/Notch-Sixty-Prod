# PR111 — Automatic Per-Driver Speaker Optimization

**Status: Slices 1–2 remote CI passed; Slice 3 implemented, exact-head CI pending; physical commissioning deferred.**

**REMOTE SOFTWARE ONLY.** All existing PRs remain draft, open and unmerged;
no live Apply, hardware acceptance, App Store release or change to `main`.

PR111 is stacked directly on remote-verified PR110, GitHub PR #111. The
developer is away from physical Apple Silicon Mac, amps, isolated woofer/mid/
tweeter outputs and calibrated microphone. PR111 work therefore targets
deterministic offline analysis, fail-closed qualification and testable future
commissioning design without pretending bench validation took place.

## Feature architecture and authority

- PR41 implements stereo physical bus routing / required Bi-Amp or Tri-Amp
  protective crossover.
- PR43 implements bounded `SpeakerDriverBusProcessingConfiguration` with
  Low/Mid/High bus-specific PEQ, gain, polarity, alignment delay and optional
  limiter. A *limiter must be enabled* before PR106 direct-driver excitation.
- PR106 adds the separate protected-driver Lab measurement path, containing
  bus, physical endpoint, crossover, limiter and gain provenance. These captures
  can be analyzed only after `SpeakerMeasurementLabSession.validateStructure()`
  and an exact repeated provenance check.
- Whole-speaker PR103–107 optimizer and FIR remain **different owners** from
  the active Low/Mid/High bus stages. PR108 Sub timing/phase is likewise a
  separate system; PR111 must never alter it via a proposal.
- The user's current passive Klipsch RP-600M and Denon DRA-635R wiring does
  **not** expose independent woofer/tweeter signals. It cannot use real
  per-driver correction until safely converted to independently driven active
  hardware with protective channels and amplification.

## Slice 1 — Protected, bounded PEQ recommendation foundation

`ProtectedDriverPEQRecommendationAnalyzer` in the existing compiled
`SpeakerMeasurementLabProtectedExcitation.swift` source accepts exactly
one protected Near-Field Lab protocol, never an arbitrary whole-speaker or
unprotected capture. It requires:

- source identity and session integrity; same exact physical driver Low/Mid/High
  bus; only active Bi-Amp or Tri-Amp crossover with mode-valid driver bus;
- matching authenticated protected routing/driver/limiter provenance for
  **every** repeat;
- at least **three** complete, unclipped repeated sweeps, SNR ≥35 dB,
  and repeat magnitude stability within 0.85 dB over ≥90% of qualified
  passband bins;
- a finite, strictly increasing shared response grid and ≥24 stable bins
  in a crossover-guarded passband; no speculation outside measured
  usable frequency limits or near protective crossover boundaries.

Only a local, repeat-stable positive broadband feature relative to neighboring
octave-frequency samples may produce a *cut-only* PEQ **hypothesis**:
maximum three bands, maximum 2.5 dB attenuation per band,
Q ≤1.4, and ≥0.55 octaves separation. A smooth response yields zero
recommendations. There is no automatic boost, null filling, flat target
assumption, FIR filter, new realtime DSP stage or new hardware dependency.

Proposals include exact capture IDs, bus, routing, crossover, sample rate and
protected driver state. They explicitly encode:
`measurementOnly=true`, `canDeploy=false`,
`canChangeDelayOrPolarity=false`,
`canAlterCrossoverOrLimiter=false`, and
`requiresNewMeasuredVerification=true`.

**This does not yet compile EQBand objects or update existing per-driver
configuration.** Future, separately guarded approval and new real measurements
are necessary before deployment. Cut hypotheses based on near-field evidence
are not yet full-speaker frequency-response corrections and cannot establish
correct acoustic summation or stereo imaging.

## Planned follow-on slices

**Slice 2 — Per-driver measurement, protected evidence & report UI
(implemented, exact-head CI pending).** The existing Measurement Lab
`Analysis & Export` card now includes one read-only `protectedDriverOptimization`
analysis per protected Low/Mid/High Lab protocol, including incomplete ones.
For each qualified capture protocol, the analysis displays the exact bus,
crossover-guarded usable frequency range, number of repeat-qualified
captures, protection/limiter status, number of suggested cut-only peaks,
and each frequency, gain and Q value. The display explicitly reads
**REVIEW ONLY**, not `Applied`, and warns that per-driver near-field
measurements do not establish anechoic or aggregate whole-speaker response.

Failed PR106 provenance, insufficient repeats, invalid frequency samples,
clipping, low SNR or inadequate protected passband are shown as unavailable
with the underlying blocker; an absent qualified measurement never becomes
a neutral or flat driver response. Smooth, otherwise qualified data result
in **zero suggested cuts**, not manufactured correction. JSON and CSV
exports contain *compact measured diagnostics only*, never raw impulse,
capture grids, DSP program state, profile changes, live routing, or an
apply-able preset. The existing metric rendering uses adaptive columns so
several low/mid/high driver results remain readable on narrow windows;
the UI now shows all diagnostic caveats instead of hiding all but the first.

Additional XCTest checks qualified report status, cut metrics, no-op results,
incomplete repeats, unprotected limiter rejection, and the no-deploy
export boundaries. Full Apple Silicon application regression remains the
remote acceptance gate.

Future PR111 slices must still independently validate speaker source and
crossover summation, acoustic-center timing, explicit approval/rollback,
and physical speaker-safe capture. This Slice 2 does **not** authorize
filter compilation or deployment.

**Slice 3 — Acoustic-center timing and polarity hypotheses
(implemented, exact-head CI pending).** Adjacent protected-driver pairs can
now be analyzed only when every repeat includes a qualified simultaneous
electrical reference captured on the second input of the same ADC timeline.
The analyzer accepts Low↔High in Bi-Amp mode, or Low↔Mid / Mid↔High in
Tri-Amp mode, on the same speaker side only; Low↔High is explicitly rejected
as non-adjacent in Tri-Amp mode.

Both drivers must retain identical multi-output routing and Bass Management
crossover topology, exact per-repeat protected provenance, active limiter,
common sample/frequency grid, complete unclipped sweeps, SNR ≥35 dB and
measured coverage around the crossover. The shared reference itself must
remain stable across both driver protocols: arrival spread ≤0.25 ms,
magnitude-repeatability RMS ≤0.50 dB, and phase consistency ≥98%.
Independent-clock data, missing reference captures, mismatched routing or
unstable reference evidence produce no timing result.

The measured acoustic arrival is corrected by each sweep's simultaneous
electrical-reference arrival. If the adjacent drivers differ by 0.05–2.0 ms,
the report may hypothesize *additional delay on the currently earlier bus*;
larger offsets are reported without inventing a safe delay value. Residual
phase is calculated only after the acoustic and reference arrival terms have
already been removed. A ≥45° advantage is required before reporting either
**retain current polarity** or **compare inversion of the second driver**;
otherwise polarity remains inconclusive.

These values are visible in Measurement Lab → Analysis & Export with
crossover, relative arrival, bounded delay hypothesis, residual phase,
polarity hypothesis, reference stability, evidence confidence and
**Never · review only** deployment status. JSON/CSV remain compact diagnostics.
No delay, polarity, crossover, limiter, PEQ or live routing field is changed.

The polarity result is not a permission to invert a driver. The next slice
must evaluate actual combined-driver crossover summation, and a later guarded
Apply must require fresh real measurements and rollback. The electrical
reference authenticates relative per-sweep timing only; it does not certify
absolute DAC/ADC latency or exposed-driver hardware safety.

**Slice 4 — Combined-driver crossover summation verification.** Model and
eventually verify aggregate response with safely captured pairs and
protected drivers. Recommend adjustments, never weaken mandatory crossover
slopes or overdrive a raw driver. Explicit rollback on failed verification.

**Slice 5 — Guarded Apply/rollback, UI, persistence and remote closeout.**
Approval must be explicit, state-drift checked, and limited to verified
safe fields while retaining installed crossover/limiter and device mapping.
Independent before/after hardware capture must confirm changes. Never
treat CI as physical proof.

## Remote verification

A dedicated PR111 workflow builds arm64 Debug and unsigned Release app,
executes new recommendation tests plus prior protected-driver tests, reruns
PR106/PR109/PR110 structural safety guards, and executes full XCTest.
All hard-gated physical acceptance remains pending. A passing CI build does
not certify live amplifiers, individual exposed drivers, loudspeaker safety,
phase integration, clock coherence or acoustic improvement.
