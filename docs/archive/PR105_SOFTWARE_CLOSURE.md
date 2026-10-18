# PR105 Software Closure

Status: **REMOTE SOFTWARE COMPLETE — PHYSICAL ACCEPTANCE PENDING**

PR: roadmap PR105 / GitHub PR #106  
Base: PR104 / GitHub PR #105  
Branch: `feature/pr105-guided-speaker-characterization-verification`

## Completed remote scope

1. Geometry-bound whole-speaker characterization using the same calibrated
   movable microphone, with three stationary repeats and independent evidence
   identity.
2. Bounded early-window magnitude characterization, explicitly non-anechoic and
   magnitude-only.
3. Cross-domain classification of speaker-persistent vs room/seat-dependent,
   ambiguous and non-material deviations.
4. Classification-aware PEQ/FIR preview authority. Protected/unclassified
   regions cannot drive correction synthesis.
5. Guided SYSTEM → Speaker Calibration characterization and evidence comparison.
6. Immutable commissioning proposal, explicit user approval and complete
   Playback System rollback snapshot.
7. Separately owned live cut-only whole-speaker PEQ deployment stage.
8. Transactional PEQ Apply and guarded exact-state rollback.
9. Independent fresh post-Apply microphone verification.
10. Guided provisional Apply and fresh repeated-sweep verification UI.
11. Automatic rollback on qualified measured rejection and persisted
    receipt-bound verified status on measured acceptance.

## Verified safety boundaries

- Ordinary Speaker Calibration trim, delay, polarity and EQ remain separately
  owned and are not rewritten by Speaker Optimizer.
- Applied Speaker Optimizer PEQ is whole-speaker, cut-only and bounded by the
  realtime lane section ceiling.
- Apply requires explicit user action and exact proposal/candidate identity.
- Apply, verification finalization and rollback fail closed on unrelated
  Playback System state drift.
- A deployment is provisional until a fresh, qualified post-Apply microphone
  campaign passes independent measured acceptance.
- Qualified measured rejection automatically uses the immutable rollback
  snapshot. Unrelated later edits are never overwritten.
- Verified status is optional persisted metadata and does not alter physical
  routing identity or coefficients.
- Protected Low/Mid/High driver buses are still not directly swept.
- FIR deployment remains blocked because there is not yet a separately owned
  per-speaker FIR stage with channel/video latency coordination.
- Crossover timing/polarity deployment remains blocked because PR103 v1 saved
  measurements do not authenticate a shared cross-source playback/capture clock
  origin.

## Exact-head software evidence

Slice 11 code head `ea14277b9d8b840e351fd1529fe8603703a634eb` passed
pull-request run **38209669007**, including Apple Silicon Debug build, targeted
PR105 tests and full XCTest regression.

The exact closeout head created with this document must pass the same push and
pull-request workflows before this closure is treated as final.

## Not certified remotely

- Actual 0.75–2.0 m microphone-placement suitability for every speaker design.
- Actual first-reflection timing or whether the default 6 ms gate is optimal in
  a specific room.
- Physical microphone calibration accuracy.
- Acoustic benefit on real loudspeakers/subwoofers.
- Thermal/electrical speaker safety beyond existing software routing guards.
- Shared-clock timing provenance for coherent mains/sub timing or polarity
  action.
- Active-crossover protected-driver commissioning.
- Real-world A/V sync under future FIR deployment.
- Subjective listening benefit.
- App Store / marketplace release acceptance.

PR #106 remains draft, open and unmerged until physical acceptance or an
explicit merge decision.
