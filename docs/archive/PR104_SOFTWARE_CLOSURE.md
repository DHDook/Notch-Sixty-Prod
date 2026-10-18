# PR104 — Speaker Optimization Engine Remote Software Closure

Status: **REMOTE SOFTWARE COMPLETE — PHYSICAL ACCEPTANCE PENDING**

Parent: PR103 measurement foundation (GitHub #104).
This PR: roadmap PR104, GitHub [#105](https://github.com/DHDook/Notch-Sixty-Prod/pull/105).
Next: PR105 guided apply, rollback and physically measured verification.

## Exact-head CI evidence

Before this closure-only documentation commit:
- [PR104 push run 38178753709](https://github.com/DHDook/Notch-Sixty-Prod/actions/runs/38178753709) **PASS** on 2026-10-11 for commit `c49b884e409c90a0016b1fac7774328728d52058`.
- [PR104 pull-request run 38178757011](https://github.com/DHDook/Notch-Sixty-Prod/actions/runs/38178757011) **PASS** for that same commit.

Both covered portable PR104 safety contracts, inherited PR103 measurement
foundation and disconnected ANC checks, Apple Silicon Debug app build,
targeted optimizer, PEQ, FIR, mains/sub crossover and candidate-comparison
XCTests, plus the full application XCTest regression.

**Important:** This closure-document commit creates a NEW exact branch head.
Its own push/PR workflows must also pass before the remote software handoff
can be considered fully verified. No physical acoustic testing occurred.

## Completed source and safety coverage

1. Only requalified PR103 baseline measurements: repeated captures, signal/noise
   and confidence gates, stable microphone/routing/source/seat identities.
2. Seat-weighted, bounded, spectral-reference magnitude preview, limited to
   each source's common usable frequency band.
3. Candidate digital PEQ with normalized coefficients, Q/gain/headroom and
   out-of-band restrictions; no realtime installation.
4. Minimum-risk, independent linear-phase FIR synthesis from measured evidence,
   actual-tap spectrum audit, fixed group-delay reporting, and fail-closed
   latency/headroom/worst-seat constraints; no realtime installation.
5. Mains/sub crossover-band modeled sum, arrival and polarity feasibility,
   with explicit warnings about absent authenticated common-clock provenance
   and independent limiter/headroom requirements.
6. Independent PEQ, FIR and bypass *per-source* ranking with predicted
   improvement, seat regression, delay, complexity and headroom tradeoffs.
   Visual-only magnitude A/B; no live-audio switching.
7. Clock-origin perturbation stress test for crossover proposals, where both
   baseline and candidate see the same assumed unknown offset. A model passing
   assumed timing uncertainty does NOT authenticate the source clock.

All PR104 design outputs explicitly advertise preview-only/no-deploy.
Predictions are never mislabeled as verification captures.

## Mandatory PR105 boundaries

- Acquire a shared, verifiable source/capture clock and loopback or equivalent
  reference BEFORE permitting any coherent timing/polarity action.
- No silent application: require informed user approval, immutable routing
  snapshot, restore and immediate abort/rollback.
- Physical audio safety: aggregate DSP headroom, FIR/channel timing,
  crossover+limiter persistence, bus ownership, pop-free transitions,
  end-to-end processing latency, clipping and device changes.
- New **physically measured** candidate and post-apply verification sets;
  independently check benefit and failure, not old synthetic predictions.
- Protected Low/Mid/High driver-bus transport remains blocked until a
  crossover-preserving verified excitation pipeline exists.

## Explicitly not certified remotely

Real microphone calibration, physical acoustic correction, actual cross-source
clock coherence, thermal/electrical speaker safety, safe active-driver
commissioning, subjective audible benefit, AV lip-sync and marketplace release.

This branch remains draft, open and unmerged pending stacked PR review and
later physical acceptance.
