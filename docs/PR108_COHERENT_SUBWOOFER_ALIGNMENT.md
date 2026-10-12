# PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization

Status: **IN PROGRESS — SLICES 1–2 PROPOSAL + COMMISSIONING IDENTITY**

Base: PR107 Speaker Optimizer FIR Deployment & Latency Coordination.

## Purpose

PR106 introduced an authenticated coherent Main/Sub measurement path using
simultaneous acoustic + electrical-reference capture. That path deliberately
stopped at measurement-only evidence.

The existing multichannel calibration engine can already estimate physical
subwoofer gain/delay/polarity from ordinary direct-arrival and multi-seat
measurements, but it does not consume PR106's stronger reference-authenticated
cross-source phase evidence as a dedicated crossover-alignment workflow.

PR108 closes that gap.

The intended sequence is:

PR106 coherent Main/Sub capture
→ authenticated reference-aligned crossover evidence
→ PR108 bounded delay/polarity proposal
→ explicit review
→ transactional calibration Apply
→ fresh coherent verification
→ accept or exact rollback

PR108 owns physical subwoofer timing/polarity alignment. It does not replace
Speaker Optimizer spectral correction, Room Correction, multi-sub low-frequency
EQ, or the bass-management crossover engine.

## Slice 1 — Coherent delay/polarity proposal

Implemented in CoherentSubwooferAlignment.swift.

The planner accepts one or more PR106
SpeakerMeasurementLabCoherentTimingReport values for different Main speakers
paired with the same physical Sub.

It requires authenticated shared-clock provenance, one Playback System/route/
microphone/sample rate, one physical Sub index, unique whole-speaker Main roles,
sufficient evidence confidence, active bass management, a mapped physical Sub,
and enough common response points around the active crossover.

### Phase model

PR106's existing tests prove that wrappedRelativePhaseRadians already carries
the measured Main/Sub timing phase: a Sub arriving 3 ms late produces
approximately -2πf·0.003.

PR108 therefore does **not** subtract relativeArrivalMilliseconds again.

For each bounded candidate it predicts:

phase_after =
    measured_relative_phase
    - 2π f * signed_relative_delay_adjustment
    + optional π polarity_toggle

The objective is normalized coherent Main+Sub summation around crossover.
0 dB represents ideal coherent summation after normalizing by |Main|+|Sub|;
more-negative values represent increasing cancellation.

### Signed delay materialization

The candidate uses one signed relative adjustment:

- positive — add delay to the physical Sub;
- negative — the Sub would need advancing, so a future Apply stage adds the
  opposite common delay to all non-LFE speaker lanes instead.

This avoids unsupported negative physical delay while preserving relative
timing. The proposal checks existing speaker/subwoofer realtime delay capacity.

### Polarity

The optimizer searches both current polarity and one physical polarity toggle.
The candidate reports both the toggle and resulting absolute Sub polarity.

### Multi-Main robustness

Multiple Main reports may be supplied for one physical Sub. The search optimizes
one shared setting across all included Main speakers rather than tuning a Sub
against only one channel and accidentally degrading another.

## Slice 1 safety state

- proposal only;
- previewOnly == true;
- canDeploy == false;
- no Output Device Profile mutation;
- no speaker or subwoofer calibration mutation;
- no crossover-frequency mutation;
- no EQ/gain mutation;
- no Speaker Optimizer/Room Correction mutation; and
- no claim of measured post-Apply improvement.

## Slice 2 — Commissioning identity and explicit approval

Implemented in CoherentSubwooferAlignmentCommissioning.swift.

Commissioning does not trust a caller-provided candidate. It re-runs Slice 1
from the supplied coherent reports and the current Playback System, then
requires exact candidate equality.

The proposal binds:

- Playback System ID and complete PlaybackSystemState rollback snapshot;
- Output Device Profile routing identity;
- active bass-management crossover;
- sample rate and physical Sub index;
- a stable fingerprint of every coherent report, including measured magnitude,
  phase and relative arrival evidence; and
- a stable fingerprint of the derived alignment candidate.

Any crossover change, Playback System mismatch, output-profile removal,
measurement mutation or hand-edited candidate invalidates commissioning.

Explicit approval is separately fingerprint-bound and requires a user-initiated
action. Slice 2 still has no mutation path: proposal canDeploy remains false.

## Planned follow-on slices

1. Transactional Apply / rollback — engine-idle mutation of only the required
   speaker-common delay and physical Sub delay/polarity.
2. Multi-sub coordination — avoid independent per-Sub choices that conflict
   with the existing multi-sub relationship.
3. Fresh coherent verification — repeat authenticated Main/Sub measurement
   after Apply and verify summation/timing improvement.
4. Guided production workflow/UI — capture, review, Apply, verify, rollback.
5. Physical commissioning handoff — real DAC/ADC/subwoofer timing, crossover
   summation, restart/rollback and subjective bass integration.

## Slice 1 validation

CoherentSubwooferAlignmentTests covers late-Sub/common-speaker-delay,
early-Sub/positive-Sub-delay, polarity recovery, robust Left/Right compromise,
already-coherent no-op blocking, and stale identity/bass-management failures.

PR108 CI also preserves the complete PR107 software contract and full retained
XCTest suite.


## Slice 2 validation

CoherentSubwooferAlignmentCommissioningTests verifies exact Playback System
snapshot binding, deterministic evidence/candidate fingerprints, candidate
regeneration, crossover-drift rejection, and mandatory explicit approval.
