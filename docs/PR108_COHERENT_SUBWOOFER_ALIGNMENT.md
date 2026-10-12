# PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization

Status: **IN PROGRESS — SLICES 1–5 THROUGH VERIFIED PERSISTENT PROVENANCE**

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

### Multi-Sub boundary

Slices 1–4 are deliberately single-Sub. If more than one physical Sub is
assigned, the single-Sub planner fails closed with multiSubCoordinationRequired.
Independent sequential application could otherwise accumulate the shared
speaker-delay compensation and disturb an already aligned Sub. A dedicated
coordinated multi-Sub slice must solve all Sub relative delays together.

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
action. The raw Slice 1 candidate remains preview-only; once Slice 3 is present,
the exact commissioned proposal reports canApply/canDeploy true.

## Slice 3 — Transactional Apply and exact rollback

Implemented in CoherentSubwooferAlignmentApplyTransaction.swift.

Apply requires:

- DSP engine idle;
- explicit fingerprint-bound approval;
- exact selected Playback System identity;
- exact complete PlaybackSystemState equality with the commissioning snapshot;
- unchanged bass-management state/crossover; and
- the target physical Sub still present.

The transaction changes only calibration timing/polarity:

- positive signed adjustment adds physical Sub delay;
- negative signed adjustment adds the opposite common delay to every non-LFE
  speaker calibration;
- the selected Sub receives the candidate's resulting physical polarity.

Existing speaker trim/EQ/polarity, Sub gain/EQ, crossover settings, Room
Correction, Speaker Optimizer state and all unrelated Playback System fields
remain untouched.

Every changed calibration is revalidated at the candidate sample rate. The
Output Device Profile is then validated as a whole before mutation.

The write is engine-idle and exact-state verified. Rollback restores the
immutable pre-Apply Output Device Profile and refuses to overwrite unrelated
post-Apply edits.

Apply receipts remain provisional and require fresh measured verification.

## Slice 4 — Fresh coherent post-Apply verification

Implemented in CoherentSubwooferAlignmentPostApplyVerification.swift.

Verification consumes the actual post-Apply Advanced Speaker Measurement Lab
session plus linked coherent pair IDs. It does not trust caller-supplied
post-Apply reports.

The verifier requires:

- the current Playback System still exactly equals the provisional Apply state;
- baseline coherent reports still match the receipt's approved evidence
  fingerprint;
- the verification session uses the same Playback System, physical route,
  calibrated microphone and sample rate;
- new session/pair identities rather than the baseline session;
- every selected capture timestamp is later than Apply; and
- exactly one fresh coherent pair for every commissioned Main role.

It re-runs the PR106 coherent analyzer and checks two independent outcomes:

1. **Applied-filter tracking.** Since PR108 changes only timing/polarity, measured
   relative phase must track
   `-2πf·signedDelay + π when polarity toggles` within the configured RMS
   tolerance. Relative crossover magnitude is expected to remain stable.
2. **Acoustic benefit.** Normalized coherent Main+Sub summation around crossover
   must improve by the required amount, no included Main pair may materially
   regress, and final coherence must clear the acceptance floor.

Rejected verification sets `shouldRollback == true`. Modeled proposal quality
cannot satisfy this gate.

## Slice 5 — Persistent provisional/verified provenance + finalization

Implemented in CoherentSubwooferAlignmentDeployment.swift and the existing Apply
transaction.

PR108 now persists its own optional Output Device Profile provenance record
rather than overwriting the ordinary MultichannelCalibrationDeploymentSummary.

At provisional Apply the record stores:

- Apply/proposal/Playback System identities;
- route, sample rate, crossover and physical Sub identity;
- evidence and candidate fingerprints;
- the signed relative adjustment and its physical materialization;
- exact post-Apply delay for every non-LFE speaker;
- exact target Sub delay and polarity; and
- no verification marker yet.

Output Device Profile validation proves the provenance still matches the actual
speaker/Sub calibration. If those live delay/polarity values are edited later,
the stale PR108 record becomes invalid rather than silently claiming ownership
of different settings.

Accepted Slice 4 evidence can then be finalized into a verification record with
the fresh Lab session ID, evidence confidence, worst phase/magnitude tracking,
and measured before/after coherence. The verified write is engine-idle,
state-drift guarded, and exact-state checked.

Rollback remains possible from either provisional or verified state: the
rollback checker normalizes away only the verification marker before proving the
state is otherwise the exact Apply state.

The persisted field is optional, so older Output Device Profiles with no PR108
key continue to decode with no alignment provenance.

## Planned follow-on slices

1. Multi-sub coordination — solve all physical Sub relative delays together
   without accumulating incompatible common speaker delay.
2. Guided production workflow/UI — capture, review, Apply, verify, rollback.
3. Physical commissioning handoff — real DAC/ADC/subwoofer timing, crossover
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


## Slice 3 validation

CoherentSubwooferAlignmentApplyTransactionTests verifies late-Sub common speaker
delay, early-Sub physical delay, isolated polarity mutation, engine-idle/exact
snapshot gates, stale-approval rejection, exact rollback and rollback state-drift
protection.


## Slice 4 validation

CoherentSubwooferAlignmentPostApplyVerificationTests uses complete synthetic
PR106 Measurement Lab sessions to verify accepted measured timing correction,
rejection when the acoustic phase does not follow Apply, mandatory post-Apply
capture timestamps, baseline-evidence binding and current-state drift rejection.


## Slice 5 validation

The retained Apply/verification tests now also cover provisional record identity,
verified finalization, rollback from verified state, stale-provenance rejection
after manual calibration drift, and backward-compatible decoding of profiles
that predate the optional PR108 field.
