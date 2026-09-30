# PR42 — Formal Parity, Provenance, and Release-Gap Closure

Status: **KICKOFF / AUDIT IN PROGRESS**

Starting point: PR41 clean combined head `c168f55367112750b0cb58adf5a1d8493202b6a4`.

PR42 is intentionally stacked on PR41 while PR40/PR41 await their combined real-Mac physical acceptance and merge sequence. It must not rewrite or destabilize the accepted PR34–PR41 DSP/transport architecture merely to satisfy historical structure.

## Purpose

Close the commercial rewrite parity and provenance gate before production hardening.

PR42 will produce a source-backed disposition for every externally observable legacy capability and every material commercial rewrite obligation. Each item must end in exactly one of:

- **PARITY** — equivalent user-observable capability exists in the proprietary product;
- **IMPROVED** — capability exists with intentionally improved product behavior or architecture;
- **PORT VERIFIED** — later owner-authored clean candidate was deliberately reused after provenance and quality review;
- **SUPERSEDED** — the historical capability is intentionally replaced by a better production mechanism;
- **BLOCKED** — release-blocking gap remains and must be implemented before closure.

There may be no unexplained omission at PR42 exit.

## Source-of-truth / clean-room rule

The legacy GPL repository may be used only to inventory externally observable behavior and feature surface. It is not an implementation template.

Commercial implementation work must continue to come from:

- the existing proprietary Notch Sixty architecture and accepted PR1–PR41 behavior;
- independently written product requirements;
- Apple platform documentation and public APIs;
- public DSP/acoustics specifications and literature where DSP math is required;
- explicitly provenance-cleared owner-authored material recorded in `docs/PROVENANCE.md`.

No historical GPL source expression, tests, scripts, assets, project structure, or configuration should be copied into production.

## Audit workstreams

### A. Product capability matrix

Reconcile the existing parity audits and the shipping production UI against the legacy externally observable feature set.

Minimum domains:

- transport / selected-device behavior / lifecycle;
- stereo playback controls and audition modes;
- EQ, phase modes, FIR and convolution workflows;
- dynamics, restoration, protection and conditioning;
- metering / RTA / analysis;
- Room Correction measurement, multi-position workflow, target/design/deployment;
- bass management and Active Crossover;
- physical speaker routing and synchronization;
- persistence, Content Presets, Playback System Profiles and session state;
- import/export/interchange obligations;
- permissions, recovery and App Sandbox behavior;
- production UI and accessibility-visible capabilities.

### B. Deferred loudspeaker optimization classification

PR41 deliberately deferred the larger speaker-optimization suite. PR42 must classify each deferred item as either required for legacy parity / launch or a documented post-1.0 enhancement.

Items to classify include:

- arbitrary per-output parametric EQ;
- arbitrary per-output gain / polarity / broadband delay beyond current Sub controls;
- per-output limiting and metering;
- group-delay analysis/correction;
- measured acoustic-summation overlays;
- crossover-frequency / per-output-EQ optimization;
- broadband driver time alignment;
- automated polarity / acoustic-center diagnosis;
- baffle-step / diaphragm-resonance recommendations;
- automated combined-system verification.

No PR41 parity claim is retroactively expanded without implementation and validation evidence.

### C. Persistence / interchange gap audit

Confirm the final commercial disposition of:

- versioned state migrations;
- `.eqpreset` import/export and legacy migration semantics;
- REW interoperability;
- AutoEQ interoperability if still product-relevant;
- CamillaDSP interoperability if still product-relevant;
- EasyEffects interoperability if required by parity;
- resource-backed FIR / Speaker IR / Room Correction assets.

Anything not required for 1.0 must be explicitly reclassified rather than silently dropped.

### D. Provenance and third-party review

Reconcile:

- `docs/PROVENANCE.md`;
- `THIRD_PARTY_NOTICES.md`;
- committed source/assets;
- any generated or imported resources;
- Apple-framework-only assumptions;
- cleared owner-authored reuse.

Exit requires no unexplained production source or asset origin and no unresolved GPL/AGPL dependency.

### E. Production UI consistency audit

PR42 includes a bounded current-platform UI consistency pass where an existing production surface visibly lags the established macOS design language without requiring product/DSP behavior changes.

First identified item: the Dynamics selected-processor editor. Its controls are current SwiftUI, but the editor uses a manually composed parameter-row layout and a fixed quaternary rounded background rather than the newer semantic form/labeled-content structure used by current SwiftUI guidance. The goal is a native current-macOS inspector/form presentation while preserving all PR38 controls, grouping, telemetry demand isolation, and parameter semantics.

UI polish must not become a broad visual redesign of accepted PR36–PR41 surfaces.

## Realtime / architecture impact

The audit itself has no realtime impact.

Any discovered implementation gap that touches audio must preserve the existing rules:

- no allocation/free, locks, logging, file/device/UI work, or task creation in the realtime callback;
- immutable/preallocated state prepared off-callback;
- existing Processed / Reference / Delta and raw Global Bypass contracts;
- PR35 parking and demand-gating semantics;
- PR40/PR41 Room Correction / speaker-routing ownership boundaries.

UI-only work must not alter DSP snapshots or publication cadence except through already-existing bindings.

## Validation strategy

PR42 will add a permanent parity-closure validator that fails if the controlling disposition matrix contains unclassified items or unresolved BLOCKED entries at final closure.

As implementation gaps are closed, retain the relevant PR34–PR41 regression gates and add focused deterministic coverage.

Final software gate should include:

- retained PR34–PR41 validators;
- PR42 parity/provenance validator;
- Debug and Release Performance builds;
- full XCTest;
- realtime benchmarks;
- App Sandbox validation;
- Release app / DMG packaging.

Manual validation is required only for PR42 changes whose user-observable behavior cannot be established deterministically, plus a final production UI smoke pass.

## Exit criteria

PR42 closes only when:

1. every externally observable legacy capability has a documented final disposition;
2. every release-relevant deferred PR41 speaker item is either implemented/validated or explicitly classified as post-1.0;
3. persistence/interchange obligations are explicit;
4. provenance and third-party notices are reconciled;
5. no unresolved `BLOCKED` item remains;
6. bounded UI consistency findings are closed;
7. exact-head CI is green.

After PR42, the roadmap advances to production hardening rather than another broad parity-development phase.