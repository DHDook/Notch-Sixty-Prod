# PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization

Status: **REMOTE SOFTWARE COMPLETE — PHYSICAL COHERENT ALIGNMENT ACCEPTANCE PENDING**

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

The single-Sub planner remains deliberately fail-closed whenever more than one
physical Sub is assigned. Independent sequential application could otherwise
accumulate common speaker delay and disturb an already aligned Sub.

Slice 6 adds a separate coordinated multi-Sub **proposal** path. It does not
relax the single-Sub commissioning/Apply/verification path, so multi-Sub
deployment remains unavailable until its own coordinated transaction and fresh
verification slices are complete.

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

## Slice 6 — Coordinated multi-Sub proposal

Implemented in CoherentMultiSubwooferAlignment.swift.

The planner requires one coherent evidence group for every assigned physical
Sub, and every group must share the same Playback System, physical route,
calibrated microphone, sample rate, crossover, and Main-role set.

Each Sub first receives its own bounded coherent optimum s_i from the guarded
single-Sub search, where positive means "delay this Sub" and negative means
"this Sub would need advancing."

Rather than independently adding speaker delay once per Sub, the coordinated
planner solves all Subs together:

```
D_i - C = s_i
C   = max(0, -min(s_i))
D_i = C + s_i
```

C is one shared nonnegative delay added to every non-LFE speaker lane. D_i is
the nonnegative added delay for physical Sub i. This is the minimum-latency
materialization that preserves every independently measured relative optimum.

The planner also:

- keeps polarity decisions per physical Sub;
- validates the shared speaker-delay and every per-Sub delay against current
  calibration and realtime frame limits;
- requires exactly one evidence group per assigned Sub;
- rejects duplicate Sub evidence deterministically;
- requires the same Main-role set for every Sub; and
- evaluates aggregate predicted crossover coherence across the coordinated set.

Slice 6 remains proposal-only: previewOnly is true and canDeploy is false.
The existing single-Sub commissioning/Apply/fresh-verification types do not
accept this multi-Sub candidate.

## Slice 7 — Coordinated multi-Sub commissioning identity

Implemented in CoherentMultiSubwooferAlignmentCommissioning.swift.

The multi-Sub commissioning planner treats the complete physical Sub set as one
atomic review object. It re-runs the Slice 6 planner from the current Playback
System and supplied evidence groups rather than trusting a caller-provided
candidate.

The proposal binds:

- the complete PlaybackSystemState rollback snapshot;
- Playback System, route, microphone, sample rate and crossover identity;
- the exact sorted set of assigned physical Sub indices;
- one stable fingerprint over every Sub evidence group; and
- one stable fingerprint over the complete coordinated candidate.

Evidence-group order does not change the fingerprint, but changing any measured
phase/magnitude/arrival data does. Existing single-Sub PR108 provenance blocks
multi-Sub commissioning so ownership cannot overlap silently.

Approval is explicit and fingerprint-bound. With Slice 8 present, the raw
multi-Sub candidate remains preview-only while the exact commissioned proposal
is Apply-capable.

## Slice 8 — Atomic coordinated multi-Sub Apply + provenance

Implemented in CoherentMultiSubwooferAlignmentApplyTransaction.swift and
CoherentMultiSubwooferAlignmentDeployment.swift.

The transaction requires DSP idle, exact Playback System snapshot equality,
unchanged bass-management crossover, explicit fingerprint-bound approval, and
no existing single- or multi-Sub PR108 provenance.

Apply materializes the coordinated solution in one Output Device Profile write:

- the shared non-LFE speaker delay is added exactly once;
- every physical Sub receives its own nonnegative delay addition;
- each Sub receives its own resulting polarity; and
- speaker trim/EQ/polarity, Sub gain/EQ, crossover, Room Correction, Speaker
  Optimizer, and unrelated Playback System state remain unchanged.

A separate optional coherentMultiSubwooferAlignment provenance record persists
the exact common speaker delay, each Sub's signed optimum/materialized delay,
expected final speaker delays, and every expected final Sub delay/polarity.
It is mutually exclusive with the single-Sub coherentSubwooferAlignment record.

The write is exact-state checked. Rollback restores the immutable commissioning
snapshot and refuses to overwrite unrelated post-Apply edits. The Apply receipt
remains provisional and requires fresh measured coordinated verification.

## Slice 9 — Coordinated fresh coherent verification

Implemented in CoherentMultiSubwooferAlignmentPostApplyVerification.swift.

Verification requires one fresh PR106 coherent pair for every commissioned
Main × physical-Sub combination. All selected captures must be newer than Apply,
use the same Playback System/route/calibrated microphone/sample rate, and use
new session/pair identities.

For each Main/Sub pair the verifier:

- re-runs the PR106 reference-authenticated coherent analyzer;
- checks measured phase delta against that physical Sub's own signed delay and
  polarity signature;
- requires relative crossover magnitude to remain stable; and
- blocks material per-pair coherence regression.

It then evaluates normalized coherent summation across the complete coordinated
set. Aggregate improvement and final coherence must clear the acceptance floors.

Acceptance is atomic: one rejected Sub/Main pair rejects the full coordinated
deployment and sets shouldRollback true. Modeled Slice 6 prediction cannot
satisfy this measured gate.

## Slice 10 — Verified coordinated provenance + finalization

CoherentMultiSubwooferAlignmentDeploymentRecord now carries an optional
verification record. Provisional/verified state therefore survives persistence
and relaunch without creating another DSP stage.

Accepted Slice 9 evidence can be finalized only when:

- the engine is idle;
- the report belongs to the exact coordinated Apply receipt;
- the current Playback System is still the exact provisional Apply state; and
- the persisted multi-Sub provenance still matches the receipt fingerprints.

The verification record persists the fresh Lab session ID, evidence confidence,
source count, worst phase/magnitude tracking, and measured before/after aggregate
coherence.

The verified write is exact-state checked. Rollback accepts either the exact
provisional state or a state that differs only by this verified marker; unrelated
post-Apply edits still block rollback.

## Slice 11 — Guided production commissioning workflow/UI

Implemented in CoherentSubwooferAlignmentGuidedWorkflow.swift and integrated
into ProductionSpeakerMeasurementLabWorkspace.swift.

The guided controller reuses the existing PR106 Measurement Lab session as the
only acquisition source. It creates no parallel measurement store and performs
no raw output mutation.

The production sequence is:

1. complete reference-authenticated coherent Main/Sub Lab evidence;
2. generate and review the bounded PR108 proposal;
3. explicitly approve and Apply provisionally while DSP is idle;
4. create a fresh verification Lab session with new session/pair identities;
5. remeasure the same approved coherent geometry/reference configuration;
6. verify the fresh session; and
7. finalize VERIFIED provenance on acceptance or automatically roll back on
   rejection.

The controller automatically selects the safe ownership path:

- one assigned physical Sub → single-Sub PR108 transaction;
- multiple assigned physical Subs → atomic coordinated multi-Sub transaction.

The Measurement Lab card exposes mode, physical Sub count, predicted crossover
coherence improvement, common speaker delay, provisional Apply, fresh
verification, measured result, and guarded rollback.

The UI never treats the proposal as measured proof. Fresh verification is
mandatory before the deployment becomes VERIFIED.

On profile reload/relaunch, the Measurement Lab card reads persisted single- or
multi-Sub PR108 provenance directly from the live Output Device Profile and
surfaces PROVISIONAL/VERIFIED ownership. New proposal generation is disabled
while that record owns the live timing/polarity calibration. The UI does not
invent or reconstruct an old in-memory Apply receipt/rollback snapshot after
relaunch.

## Planned follow-on slices

1. Physical commissioning handoff — real DAC/ADC/subwoofer timing, crossover
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


## Slice 6 validation

CoherentMultiSubwooferAlignmentTests verifies the minimum-latency shared-delay
solution, independent per-Sub polarity, duplicate/incomplete evidence rejection,
Main-role-set identity, and bounded coordination within remaining realtime delay capacity.


## Slice 7 validation

CoherentMultiSubwooferAlignmentCommissioningTests verifies atomic Playback System
snapshot binding, evidence-set order independence, candidate regeneration,
measurement-drift fingerprinting, and mandatory explicit fingerprint-bound
approval.


## Slice 8 validation

CoherentMultiSubwooferAlignmentApplyTransactionTests verifies one-time shared
speaker-delay materialization, simultaneous per-Sub delay/polarity application,
preservation of existing gain/EQ, provisional provenance identity, exact
rollback, engine-idle/current-snapshot gates, stale approval rejection, and
rollback state-drift protection.


## Slice 9 validation

CoherentMultiSubwooferAlignmentPostApplyVerificationTests verifies fresh
all-Sub acceptance, whole-system rejection when one Sub fails to follow its
applied phase signature, complete pair-set requirements, post-Apply timestamps,
baseline evidence fingerprint binding, and current-state drift rejection.


## Slice 10 validation

The coordinated fresh-verification acceptance test now also finalizes the
persistent verified record and proves exact rollback from verified state.


## Slice 11 validation

CoherentSubwooferAlignmentGuidedWorkflowTests verifies single-Sub review/Apply/
rollback, coordinated multi-Sub path selection, accepted single-Sub
verification/finalization with rollback, rejected coordinated verification with
automatic rollback, and exact assigned-Sub evidence coverage.

PR108 CI also validates the production Measurement Lab commissioning card and
runs the guided workflow test class in the targeted PR108 XCTest job.
