# PR42 — Initial Parity / Release-Gap Matrix

Status: **HISTORICAL TRIAGE — SUPERSEDED BY `PR42_FINAL_PARITY_MATRIX.md`**

This file is retained only as review history. It is **not** the controlling PR42 closure ledger and must not be used to infer the current release status of a capability.

The controlling artifacts are:

- `docs/PR42_FINAL_PARITY_MATRIX.md`
- `docs/PR42_PARITY_PROVENANCE_CLOSURE.md`
- `docs/PR42_PROVENANCE_CLOSURE.md`
- `docs/PR42_INTERCHANGE_CLOSURE.md`

The initial audit established the domains that required final reconciliation: transport/device lifecycle, playback/audition, EQ/phase/FIR, dynamics/restoration/protection, metering/analysis, Room Correction, physical Active Crossover routing/synchronization, persistence, interchange, provenance/assets/dependencies, and bounded production-UI consistency.

It also identified the PR41 speaker-optimization questions that could not simply disappear from the commercial rewrite: arbitrary per-output EQ/trim/polarity/delay, per-output protection/metering, group-delay/summation analysis, crossover/per-output-EQ optimization, broadband driver alignment, polarity/acoustic-center diagnosis, baffle-step/resonance assistance, and combined-system verification.

Those questions are now resolved in the final matrix. Some capabilities are implemented or improved. Others are explicitly classified as deliberate 1.0 supersessions with a named post-1.0 enhancement path. **SUPERSEDED does not mean implemented.**

Earlier intermediate blocker labels and working tables were removed once the final ledger became authoritative so automated and human review cannot mistake stale triage for the release decision.
