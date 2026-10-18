# PR108 Remote Software Closure

Status: **REMOTE SOFTWARE COMPLETE — PHYSICAL COHERENT ALIGNMENT ACCEPTANCE PENDING**

Branch: `feature/pr108-coherent-subwoofer-alignment`

Base: PR107 Speaker Optimizer FIR Deployment & Latency Coordination / GitHub PR #108.  
Implementation PR: GitHub #109.

## Final remote scope

PR108 converts PR106's reference-authenticated coherent Main/Sub Measurement Lab
evidence into a guarded production timing/polarity commissioning path.

Remote-complete capabilities:

1. Single-Sub bounded coherent delay/polarity proposal using measured relative
   phase directly, without double-counting relative arrival.
2. Safe signed-delay materialization: positive adjustment adds physical Sub
   delay; negative adjustment becomes one common delay on every non-LFE speaker.
3. Immutable commissioning identity binding the complete Playback System
   rollback snapshot, route, crossover, sample rate, physical Sub, evidence
   fingerprint and candidate fingerprint.
4. Explicit user-initiated, fingerprint-bound approval.
5. Engine-idle transactional single-Sub Apply and exact rollback.
6. Fresh post-Apply PR106 coherent verification with timestamp freshness,
   applied phase-signature tracking, stable relative crossover magnitude,
   measured coherent-summation improvement and bounded per-Main regression.
7. Persistent single-Sub PROVISIONAL / VERIFIED PR108 provenance that must
   exactly match live timing/polarity calibration.
8. Coordinated multi-Sub proposal solving every physical Sub together with the
   minimum common speaker latency:
   `C = max(0, -min(s_i)); D_i = C + s_i`.
9. Atomic multi-Sub commissioning, Apply, independent per-Sub polarity/delay,
   persistent provenance and exact rollback.
10. Fresh coordinated verification requiring one authenticated pair for every
    commissioned Main × physical-Sub combination; one rejected pair rejects the
    complete deployment.
11. Persisted verified coordinated provenance and verified-state rollback.
12. Guided production state machine covering review, explicit provisional
    Apply, fresh verification, verified finalization and automatic rollback on
    measured rejection.
13. SYSTEM → Measurement Lab commissioning UI exposing mode, physical Sub
    count, predicted crossover-coherence improvement, common speaker delay,
    per-Sub timing/polarity, Apply, fresh verification and rollback.
14. Relaunch/profile-reload ownership display for persisted PROVISIONAL or
    VERIFIED PR108 state. New commissioning is blocked while persisted PR108
    provenance owns the live timing/polarity calibration; the UI does not
    invent or reconstruct an old in-memory Apply receipt after relaunch.
15. Updated commercial roadmap through PR108 and an executable physical
    acceptance runbook in `docs/PR108_PHYSICAL_ACCEPTANCE.md`.

## Safety and ownership contracts preserved

- Raw single- and multi-Sub candidates remain preview-only.
- Apply requires engine idle, exact selected Playback System identity, unchanged
  bass-management crossover and explicit approval of the exact evidence/candidate.
- PR108 changes only speaker/Sub delay and physical Sub polarity.
- Speaker trim/EQ/polarity, Sub gain/EQ, crossover, Room Correction, Speaker
  Optimizer and unrelated Playback System state remain separately owned.
- Multi-Sub deployment is atomic. The single-Sub planner stays fail-closed when
  multiple physical Subs are assigned.
- Every single-Sub search is constrained by current realtime speaker/Sub delay
  capacity; the coordinated solve therefore remains within remaining delay
  headroom while preserving `D_i - C = s_i`.
- Apply remains PROVISIONAL until new reference-authenticated microphone
  evidence passes.
- Fresh verification capture timestamps must be after Apply and use new
  session/pair identities.
- One failed Main/Sub pair rejects a coordinated deployment.
- Qualified measured rejection automatically uses the immutable rollback
  snapshot.
- Rollback refuses to overwrite unrelated post-Apply edits.
- Persisted provenance becomes invalid if the live delay/polarity calibration
  drifts away from the owned values.
- Single- and coordinated-multi PR108 provenance are mutually exclusive.
- PR107 Speaker Optimizer FIR deployment closure is preserved by PR108 CI.

## Final verified pre-closeout head

Implementation/UI/roadmap head
`7d93e453c2a54a1651e7678bad42d64f66ac8f15` passed:

- push run **38263562739**; and
- pull-request run **38263566501**.

Both passed:

- PR108 structural/ownership validator;
- inherited PR107 FIR deployment validator;
- Apple Silicon Debug app build;
- the complete targeted PR108 suite (**46 tests, 0 failures**); and
- the complete retained XCTest regression suite.

The documentation/validator closeout commit created after this head must pass the
same exact-head workflow before this closure is treated as final.

## Physical coherent alignment acceptance still required

Remote closure does **not** certify:

- real microphone calibration accuracy;
- a physically safe electrical-reference connection;
- real same-ADC microphone/reference behavior;
- DAC/ADC/reference-path clock stability on the intended hardware;
- actual acoustic Main/Sub phase tracking after deployed delay/polarity changes;
- actual crossover-region summation improvement in the room;
- multi-device cross-clock timing behavior;
- amplifier, speaker or subwoofer electrical/thermal/mechanical safety;
- restart/rollback behavior with the representative physical audio chain; or
- subjective bass integration and listening benefit.

Physical execution is defined in
`docs/PR108_PHYSICAL_ACCEPTANCE.md`. In particular, never connect amplifier
speaker terminals or another power output directly to an ADC; coherent
commissioning requires a known-safe line-level reference path.

## Merge state

PR108 remains draft, open and unmerged until physical coherent-alignment
commissioning is completed or the owner explicitly chooses to merge the
remote-complete stack with physical acceptance deferred.
