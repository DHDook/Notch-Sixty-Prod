# PR111 — Automatic Per-Driver Speaker Optimization

**Status: Slices 1–2 remote CI passed; Slices 3–5 implemented, exact-head CI pending; physical commissioning and Apply deferred.**

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

**Slice 4 — Reference-aligned crossover-sum model & verification gate
(implemented, exact-head CI pending).** The protected adjacent-driver
captures from Slice 3 are now combined mathematically in the complex domain
around their active crossover. Each driver transfer is normalized by its
simultaneous electrical reference before repeat averaging, preserving the
measured relative acoustic timing and phase while removing sweep/reference
path variation.

For the current protected state, the analyzer computes a **mean coherence
deficit**: the dB shortfall between the ideal magnitude sum of the two
measured drivers and their complex vector sum. This is a narrow cancellation
diagnostic around the crossover, not a target curve, SPL prediction,
anechoic response, or listening-quality score.

The model compares only hypotheses already bounded by Slice 3:
- retain current protected state;
- add the Slice-3 bounded delay to the measured earlier driver;
- compare inversion of the second adjacent driver *only when* Slice 3 found
  a strong residual-phase basis for that hypothesis;
- or the combined bounded-delay + inversion case.

A candidate must reduce modeled crossover coherence deficit by at least
0.25 dB before it is surfaced as the preferred model; otherwise the model
retains the current state. No arbitrary delay search, phase rotation, PEQ
application, crossover redesign, limiter change, or amplitude boost occurs.

The Measurement Lab report now shows current versus candidate modeled
deficit, modeled reduction, selected hypothesis, crossover and shared point
count. The status is **REVIEW ONLY / Never · model only** and always displays
**Combined-driver capture: REQUIRED · not yet verified**.

This slice deliberately does **not** claim true crossover verification:
the two drivers were measured independently. A later real capture with both
protected drivers reproducing the exact candidate state is still required
before any driver delay/polarity/PEQ field may change. `canDeploy=false`,
`combinedDriverCaptureVerified=false`, and
`requiresPhysicalCombinedDriverCapture=true` are hard model properties.

New tests cover modeled delay improvement, combined delay/polarity cases,
missing shared reference, large out-of-bound arrival mismatch, mismatched
complex grids, Lab report/export labeling and no-deploy behavior. Mandatory
crossover/limiter state remains authoritative throughout.

**Slice 5 — Hardware-blocked commissioning draft, rollback snapshot,
UI/persistence and remote closeout (implemented, exact-head CI pending).**

PR111 now creates a **commissioning draft**, not an Apply transaction.
The planner re-runs Slice 1 PEQ analysis and Slice 4 crossover-sum modeling
from the exact saved Lab session rather than trusting UI scalars. It binds
the resulting preview to the selected Playback System, session, routing
signature, sample rate, every source protocol/capture ID, the current active
Bass Management / routing / protected-driver state, and an exact
`PlaybackSystemState` rollback snapshot.

The preview can append only the already-bounded, cut-only peaking filters
from qualified protected-driver measurements. Existing trim, delay, polarity,
limiter enable/threshold, crossover topology and physical route stay unchanged.
If a measured bus has no remaining per-driver EQ capacity, draft generation
fails rather than replacing an existing band. Timing/polarity findings remain
separate **model-only** reviews and are not materialized into the preview.

The commissioning draft hard-codes:
- `readyForApproval=false`;
- `canApply=false`;
- `canDeploy=false`;
- `rollbackSnapshotAvailable=true`;
- `stateDriftCheckRequired=true`; and
- `requiresPhysicalCombinedDriverCapture=true`.

A state validator requires the selected Playback System to remain *exactly*
equal to the rollback snapshot. Any gain, routing, crossover, limiter,
driver-processing, room-correction or other system-state drift invalidates
future commissioning and requires regeneration. The draft persists atomically
in a dedicated Measurement Lab `PR111 Commissioning Drafts` sidecar and
reloads by Lab session identity.

Measurement Lab now has a **Per-Driver Commissioning Preview** panel with
Prepare Draft and Check Current State controls, affected buses, evidence
counts, model reviews and rollback status. Its state badge reads
**HARDWARE BLOCKED** and the only Apply status is **BLOCKED**. There is
intentionally **no Apply button or mutation API** in PR111's remote closeout.

This changes the previously planned boundary: the actual transactional Apply
and rollback executor is **deferred to PR112 hardware acceptance**, after a
safe real combined-driver crossover capture exists. That future transaction
should follow the already proven PR108 pattern: engine idle, explicit user
approval, exact state/fingerprint match, atomic mutation, post-write state
verification, fresh measured verification, and automatic/explicit rollback.
It must never weaken mandatory crossover/limiter protection.

Additional tests cover cut-only preview generation, no-Apply invariants,
exact Playback System state drift, routing/crossover/limiter drift, exhausted
PEQ capacity, model-only timing records and atomic persistence/schema gates.
Remote CI still cannot certify amplifier wiring, raw-driver safety or acoustic
benefit.

## Remote verification

A dedicated PR111 workflow builds arm64 Debug and unsigned Release app,
executes new recommendation tests plus prior protected-driver tests, reruns
PR106/PR109/PR110 structural safety guards, and executes full XCTest.
All hard-gated physical acceptance remains pending. A passing CI build does
not certify live amplifiers, individual exposed drivers, loudspeaker safety,
phase integration, clock coherence or acoustic improvement.
