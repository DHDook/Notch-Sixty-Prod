# PR111 — Automatic Per-Driver Speaker Optimization

**Status: Slice 1 implemented, exact-head CI pending; physical driver commissioning deferred.**

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

**Slice 2 — Per-driver protected measurement and crossover evidence.**
Expand qualified driver response characterization by woofer/mid/tweeter
bands and physically justified passbands. Show recommendations beside
current protection, with unsupported/unmeasured states explicit.

**Slice 3 — Acoustic center and timing recommendations.** Authenticate a
shared timing reference across each independently measured driver pair.
Require exact session, physical endpoint, shared ADC/timebase and limiter/
crossover topology matching. With independent-clock or absent timing
evidence, produce no delay or polarity recommendation. Keep phase at the
physical crossover in the verification loop.

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
