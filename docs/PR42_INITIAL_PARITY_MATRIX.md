# PR42 — Initial Release-Gap Parity Matrix

Status: **INITIAL TRIAGE — NOT FINAL CLOSURE MATRIX**

This file records the first PR42 reconciliation pass across the accepted commercial PR34–PR41 work and the previously documented later-milestone parity obligations. It is intentionally conservative: an item is not marked closed merely because adjacent infrastructure exists.

The final PR42 matrix will expand this into one row per externally observable legacy capability and will allow only PARITY / IMPROVED / PORT VERIFIED / SUPERSEDED / BLOCKED as final dispositions.

## 1. Domains already substantially closed

| Domain | Initial PR42 disposition | Evidence / remaining note |
| --- | --- | --- |
| Current stereo EQ / phase / FIR / spatial controls | **IMPROVED** | PR34 closed the current-stereo DSP parity gate, including Band Pass, Constant-Q, Linkwitz, high-order slopes, Tilt, Mid/Side, per-band FIR, Mixed Phase, Symmetry Balance, speaker crossfeed/crosstalk cancellation, Sub phase alignment, and independent Speaker IR runtime. |
| Realtime architecture / parking / performance readiness | **IMPROVED** | PR35 established immutable snapshot ownership, bounded realtime transitions, computational parking, gated metering, and performance diagnostics. |
| Production shell / Equalizer / Dynamics | **PARITY / IMPROVED** | PR36–PR38 replaced engineering placeholders with production UI while preserving accepted DSP semantics. PR42 retains only a bounded current-platform presentation consistency pass. |
| Production metering / RTA / stereo analysis | **PARITY / IMPROVED** | PR39 provides production Levels/Dynamics information, dual Input/Output RTA, phase correlation, goniometer, and demand-gated analysis infrastructure. |
| Commercial internal Content Preset / Playback System persistence | **IMPROVED** | PR39 introduced separate versioned commercial profile layers with transactional ownership and atomic archive persistence. This does **not** by itself satisfy legacy file/interchange parity. |
| Core Room Correction measurement/design/deployment workflow | **IMPROVED** | PR40 provides microphone permission/device/calibration, ESS measurement, deconvolution/analysis, multi-position weighting, target design, bounded correction FIR generation, project persistence, and deployment through the dedicated runtime. |
| Physical speaker routing / active crossover core | **IMPROVED** | PR41 provides persistent 2–8 routes, same-device and multi-device HAL Aggregate Device output, Mains+Sub/Bi-Amp/Tri-Amp, LR24/LR48, reference clock/drift compensation, and driver-safe crossover behavior under Global Bypass. |
| Legacy Software PLL | **SUPERSEDED** | PR41 deliberately replaces the legacy custom PLL concept with Core Audio Aggregate Device clocking and HAL drift compensation. |
| Proven legacy no-op transport/crossover toggles | **SUPERSEDED** | Hardware Sync Buffer, Music/Movie latency state, and known no-op crossover optimiser slope/delay toggles are not recreated. |
| Headphone-only / headphone AutoEQ workflow | **SUPERSEDED** | Outside the approved speaker-focused product definition unless a future speaker-oriented interchange requirement is separately established. |

## 2. Confirmed release-gap candidates

These were explicitly documented as later parity milestones and are not present as complete shipping workflows in PR41.

### A. Native preset compatibility / interchange

Initial disposition: **BLOCKED** until implemented or a final source-backed superseding decision is approved.

Confirmed obligations from the persistence audit:

- one-way legacy `.eqpreset` v1 migration;
- one-way legacy `.eqpreset` v2 migration;
- legacy Pause Gate Attack/Release semantic translation during migration;
- preservation of supported stored Dynamic EQ / dynamics state;
- safe documented defaults for missing newer fields;
- explicit warning rather than silent substitution for unsupported imported state;
- REW filter-text import;
- EasyEffects EQ import/export;
- CamillaDSP export from the new commercial graph;
- resource-backed FIR / Speaker IR import and persistence where the source format/resource workflow requires it.

Commercial native profile persistence already exists and should be reused rather than replaced by the historical schema.

### B. Room Correction advanced parity

Initial disposition: **BLOCKED / REQUIRES CLASSIFICATION**.

PR40 intentionally shipped a bounded magnitude-focused correction FIR and explicitly did not claim aggressive excess-phase correction. Earlier parity work assigned the following to the later Room Correction milestone:

- IIR room correction;
- measurement-derived excess-phase correction;
- individual-vs-combined verification depth beyond the current deployment preview;
- impulse / step / energy-decay / group-delay diagnostic views.

PR42 must re-check actual legacy reachability and product value for each item. Required observable capabilities must be implemented or given an explicit SUPERSEDED rationale; infrastructure adjacency is not enough.

### C. Speaker optimization beyond PR41

Initial disposition: **BLOCKED / REQUIRES CLASSIFICATION**.

PR41 explicitly deferred and did not claim parity for:

- arbitrary per-output parametric EQ;
- arbitrary per-output gain / polarity / broadband delay beyond implemented Sub controls;
- per-output limiter / protection controls;
- per-output metering;
- group-delay analysis/correction;
- measured acoustic-summation overlay;
- automatic crossover-frequency optimization;
- per-output EQ optimization;
- broadband driver time alignment;
- automated polarity / acoustic-center diagnosis;
- baffle-step recommendations;
- diaphragm-resonance recommendations;
- automated combined-system verification.

PR42 must distinguish genuinely reachable legacy product behavior from historical no-op/unfinished optimizer UI. Proven no-op/unfinished behavior remains SUPERSEDED rather than creating false commercial debt.

### D. Advanced CamillaDSP export

Initial disposition: **BLOCKED**.

The audited legacy export surface is broader than ordinary EQ export and includes devices, filters, mixers, pipeline ordering, per-channel EQ, FIR, crossover definitions, output delay/gain/polarity/all-pass state, output matrix routing, and sample rate. PR41 now provides enough physical-routing foundation to design this exporter against the proprietary graph instead of the historical writer.

## 3. Items that need explicit PR42 verification before classification

Do not assume these are blockers until source-backed reachability and current commercial behavior are reconciled:

- whether every legacy Room Correction diagnostic view was actually reachable/meaningful enough to require 1.0 parity;
- whether legacy IIR correction and excess-phase modes were production-usable versus partially implemented experimental surfaces;
- exact per-output EQ/gain/delay/polarity reachability in the legacy Active Crossover UI;
- which legacy optimizer recommendations performed real calculations versus placeholder/no-op behavior;
- whether Dither had any valid user-observable terminal conversion boundary in the realtime application rather than only historical internal state;
- any import/export path not explicitly covered by the legacy persistence audit;
- production settings/permission/recovery UI details not already represented by the PR36–PR41 production shell.

## 4. Dynamics UI consistency finding

Initial disposition: **IMPROVED candidate — UI only**.

The PR38 Dynamics workspace is functionally complete, but its selected-processor control surface still uses a manual fixed-column parameter layout and fixed quaternary rounded card. Current SwiftUI provides semantic Form / LabeledContent structures that adapt macOS control metrics and alignment automatically.

PR42 should modernize the selected processor editor without changing:

- processor grouping or discoverability;
- any parameter range/default/step;
- telemetry demand gating;
- Enable/Reset semantics;
- Pause Gate naming/semantics;
- control-plane mutation paths;
- DSP/realtime behavior.

Liquid Glass should remain reserved for appropriate controls/navigation rather than turning the entire content card into custom glass.

## 5. Immediate PR42 execution order

1. finish the source-backed legacy capability ledger by reconciling PR34 audits with PR36–PR41 implementations;
2. implement the bounded Dynamics editor presentation cleanup;
3. implement the confirmed preset/interchange blockers in independent reviewable slices;
4. resolve Room Correction advanced-parity classifications;
5. resolve speaker-optimization classifications and implement only the genuinely required reachable behavior;
6. reconcile provenance / third-party notices;
7. add the permanent machine-readable parity-closure validator;
8. run exact-head software/DMG gates plus focused manual UI/audio acceptance where behavior changed.
