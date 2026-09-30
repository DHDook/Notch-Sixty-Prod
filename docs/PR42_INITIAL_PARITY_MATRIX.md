# PR42 — Initial Parity / Release-Gap Matrix

Status: **HISTORICAL TRIAGE — SUPERSEDED BY `PR42_FINAL_PARITY_MATRIX.md`**

This document records the initial PR42 audit triage and is retained for review history. It is **not** the controlling PR42 closure ledger and must not be used to infer the current release status of an item.

The controlling final dispositions are in:

- `docs/PR42_FINAL_PARITY_MATRIX.md`
- `docs/PR42_PARITY_PROVENANCE_CLOSURE.md`
- `docs/PR42_PROVENANCE_CLOSURE.md`
- `docs/PR42_INTERCHANGE_CLOSURE.md`

The initial audit established that PR42 needed to reconcile, rather than silently omit, the following domains:

- transport/device lifecycle and routing;
- EQ, phase, FIR and convolution;
- dynamics/restoration/protection;
- metering/RTA/analysis;
- Room Correction measurement/design/deployment;
- physical Active Crossover routing and synchronization;
- Content Presets / Playback System Profiles / session state;
- `.eqpreset`, REW, EasyEffects, CamillaDSP and other interchange questions;
- provenance, third-party notices and owner-authored assets;
- bounded production-UI consistency issues such as the Dynamics editor.

It also identified the PR41 follow-up speaker-optimization set for explicit classification:

- arbitrary per-output EQ;
- arbitrary per-output gain/polarity/delay;
- per-output limiting/metering;
- group-delay and acoustic-summation analysis;
- crossover/per-output-EQ optimization;
- broadband driver alignment and polarity/acoustic-center diagnosis;
- baffle-step/resonance recommendations;
- combined-system verification.

Those questions have now been resolved in the final matrix. Some capabilities are implemented/improved, while others are explicitly classified as deliberate 1.0 supersessions with a named post-1.0 enhancement path. `SUPERSEDED` does not mean implemented.

Historical working notes and earlier intermediate blocker labels were intentionally removed from this file once the final matrix became authoritative, so automated/documentary review cannot mistake stale triage for the release decision.
