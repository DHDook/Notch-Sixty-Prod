# PR42 — Formal Parity, Provenance, and Release-Gap Closure

Status: **CLOSURE GATE — FINAL MATRIX / PROVENANCE COMPLETE; EXACT-HEAD CI REQUIRED**

Starting point: PR41 clean combined head `c168f55367112750b0cb58adf5a1d8493202b6a4`.

PR42 remains intentionally stacked on PR41 while PR40/PR41 await their combined real-Mac physical acceptance and merge sequence. It does not rewrite the accepted PR34–PR41 realtime/DSP architecture merely to resemble historical structure.

## Purpose

Close the commercial rewrite parity and provenance gate before production hardening.

Every externally observable legacy capability and material commercial rewrite obligation must have exactly one final disposition:

- **PARITY** — equivalent user-observable capability exists in the proprietary product;
- **IMPROVED** — capability exists with intentionally stronger product behavior or architecture;
- **PORT VERIFIED** — owner-authored clean material was deliberately reused after provenance/quality review;
- **SUPERSEDED** — historical behavior is intentionally not reproduced because the commercial product uses a different mechanism or a deliberately narrower 1.0 workflow;
- **BLOCKED** — release-blocking gap. PR42 cannot close while one remains.

There may be no unexplained omission at PR42 exit.

## Final controlling artifacts

- `docs/PR42_FINAL_PARITY_MATRIX.md` — final capability-by-capability commercial disposition ledger.
- `docs/PR42_PROVENANCE_CLOSURE.md` — PR34–PR42 implementation/source/asset/dependency reconciliation.
- `docs/PR42_INTERCHANGE_CLOSURE.md` — `.eqpreset`, REW, EasyEffects and CamillaDSP compatibility contract.
- `THIRD_PARTY_NOTICES.md` — release-time dependency/notice result.
- `ci/validate_pr42_parity_closure.py` — permanent machine guard against unclassified or release-blocking matrix drift.

`docs/PR42_INITIAL_PARITY_MATRIX.md` remains as historical triage only; it is no longer the controlling closure ledger.

## Source-of-truth / clean-room rule

The historical GPL repository may be used only to inventory externally observable behavior, data-format compatibility, known defects and reachability. It is not an implementation template.

Commercial implementation sources remain:

- the proprietary Notch Sixty architecture and accepted PR1–PR41 behavior;
- independently written product requirements;
- Apple platform documentation and public APIs;
- public DSP/acoustic specifications/literature where mathematics is required;
- explicitly provenance-cleared owner-controlled material.

Historical GPL source expression, tests, scripts, project structure and configuration are not permitted production implementation sources.

## Workstream closure

### A. Product capability matrix — CLOSED

The final matrix reconciles transport/device behavior, playback/audition, EQ/phase/FIR, dynamics/restoration/protection, metering/analysis, Room Correction, physical routing/crossover, persistence/interchange, production UI and release provenance.

The matrix makes a critical distinction: **SUPERSEDED does not mean implemented**. It records an intentional 1.0 product decision and replacement/boundary. Future speaker-optimization and advanced acoustic-analysis opportunities remain listed explicitly as post-1.0 work.

### B. Deferred loudspeaker optimization classification — CLOSED FOR 1.0

PR41's deliberately deferred driver-specific EQ/trim/delay/protection/metering and measurement-assisted optimizer/diagnostic suite are not falsely claimed as current capability. The final matrix records the bounded 1.0 routing/crossover product and retains the larger suite in a named post-1.0 enhancement register.

Known audited legacy no-ops remain intentionally excluded, including the optimizer slope/delay toggles and ambiguous Apply-All delta-vs-absolute behavior.

### C. Persistence / interchange — CLOSED

PR42 implements/control-plane-validates:

- one-way legacy `.eqpreset` v1/v2 migration;
- Pause Gate semantic timing translation;
- supported legacy EQ/dynamics-state migration with explicit warnings for unrecoverable fields;
- REW filter-text import/export;
- EasyEffects EQ import/export with ownership-safe input/output gain handling;
- CamillaDSP content-EQ/FIR YAML export;
- App Sandbox user-selected read/write access for explicit import/export.

The commercial Content Preset / Playback System ownership split remains authoritative. Machine-specific private HAL speaker routing is intentionally not serialized as though it were a portable foreign-runtime configuration.

### D. Provenance / third-party — CLOSED

`docs/PR42_PROVENANCE_CLOSURE.md` reconciles PR34–PR42 implementation areas, app artwork, Apple-platform dependencies and interchange code. No unresolved GPL/AGPL production dependency or bundled third-party production component is identified.

The Notch Sixty icon artwork is project-owner-approved/controlled material. The final light/dark raster pair is retained as the visual source of truth and generated asset-catalog slots are raster-preserving resamples only—no crop, mask, redraw or reinterpretation is applied.

### E. Production UI consistency — CLOSED SUBJECT TO USER SMOKE TEST

The Dynamics selected-processor editor now uses semantic `LabeledContent`, native rounded editable values and an adaptive material/border surface instead of the old fixed-column/fixed-quaternary treatment. Existing bindings, processor grouping, ranges, Pause Gate semantics, telemetry demand and realtime behavior are unchanged.

`ci/validate_pr42_dynamics_ui_style.py` retains this contract.

## Realtime / architecture impact

PR42's substantive additions are control/UI/file-interchange work. They do not add file parsing, allocation, locks, logging, device work or UI work to the physical-output realtime callback.

The accepted rules remain:

- immutable/preallocated state prepared off-callback;
- existing Processed / Reference / Delta and raw Global Bypass contracts;
- PR35 parking/demand-gating semantics;
- PR40 Room Correction ownership;
- PR41 physical speaker-routing/crossover safety boundaries.

## Validation strategy

The final PR42 software gate requires:

- retained PR34–PR41 validators;
- `ci/validate_pr42_dynamics_ui_style.py`;
- `ci/validate_pr42_interchange.py`;
- `ci/validate_pr42_parity_closure.py`;
- `ci/validate_pr39_app_identity.py`, including raster-preserving final icon treatment;
- realtime benchmarks;
- Debug build;
- Release Performance build;
- full XCTest;
- App Sandbox validation;
- Release app / DMG packaging.

The closure validator must fail if the final matrix has an invalid/unclassified row, a `BLOCKED` disposition, a superseded row without rationale, missing key audited capabilities, or an incomplete provenance/third-party result.

## Manual acceptance remaining

No Mac-only test is required to establish the documentary classifications themselves. Before PR42 is marked ready/merged, the user should perform the already-planned combined PR40/PR41 real-hardware acceptance and a brief PR42 production UI/interchange/icon smoke pass when a Mac is available.

The PR42 smoke pass should include:

- confirm the approved light/dark Notch Sixty icon appears correctly in Finder/Dock/system surfaces;
- Dynamics editor appearance/control editing;
- import a representative `.eqpreset` and inspect migration notes;
- import/export representative REW and EasyEffects EQ files;
- export a CamillaDSP YAML and inspect/open it as text;
- verify Content Preset import does not change Playback System routing/output trim;
- ordinary playback plus Processed / Reference / Delta / Global Bypass regression smoke.

## Exit criteria

PR42 reaches software closure when:

1. every audited capability has a final disposition in `PR42_FINAL_PARITY_MATRIX.md`;
2. no matrix row has `BLOCKED` disposition;
3. post-1.0 items are explicitly identified and are not claimed as current implementation;
4. interchange obligations are explicit and validated;
5. provenance/third-party notices are reconciled;
6. Dynamics UI consistency and final icon treatment are structurally guarded;
7. exact-head CI and packaging are green.

After PR42, new broad parity discovery stops. Remaining work moves to production hardening, real-hardware acceptance and App Store/commercial release preparation.

## Application shell enhancement

PR42 restores the legacy-observable menu-bar convenience through a fresh production implementation: Content Preset switching, processing start/stop, main-window access, Settings, and quit. The Settings scene reports version/build and persists System/Light/Dark appearance plus Dock/Menu Bar/Both presence. The only legacy artifact reused is the project-owner-controlled `TrayIcon` vector asset, recorded separately as `PORT VERIFIED`.

