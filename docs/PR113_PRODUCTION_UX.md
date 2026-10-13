# PR113 — Production UX, Workflow Polish & In-App User Guide

## Status

**Slice 1 is in implementation on top of the exact remote/software-complete PR112A head `0df13292ba02ea5d21c094fabeb48894d94c2b1d`.**

PR113 is a remote-friendly production-polish milestone. It must not reinterpret
PR112A software readiness as physical hardware acceptance, release acceptance,
live feed-forward ANC authorization, or permission to merge the stacked PRs.

## Product goals

PR113 turns the very broad Notch Sixty feature set into a product that is easier
to understand and safer to operate without reducing the power of the DSP.

The UX work is organized around five principles:

1. **Explain the product where the user already is.**
2. **Use one vocabulary for preview, apply, verify, rollback and evidence.**
3. **Expose advanced math without forcing it on users who only need the workflow.**
4. **Keep measurement/model/software claims visually distinct from physical acceptance.**
5. **Polish responsiveness and accessibility without moving DSP work onto the UI thread.**

## Slice 1 — Settings information architecture & comprehensive guide foundation

### Settings

The macOS Settings window becomes a two-tab production surface:

- **General** — preserves the existing About, Appearance, Volume Keys, App
  Presence, Startup, Permissions and Support controls.
- **User Guide** — a dedicated searchable guide workspace.

The larger Settings window is intentional: the guide uses a sidebar/detail
layout suitable for a comprehensive manual, while the General tab keeps its
existing compact card width.

### Guide catalog

The guide is data-driven instead of a pile of unrelated SwiftUI text. It
contains stable article/section/formula identifiers and explicit coverage for
every `ProductionSection`:

- Dashboard
- Equalizer
- Dynamics
- Meters
- Speakers
- Headphones
- Speaker Calibration
- Measurement Lab
- Room Correction
- Active Acoustics
- Room Advisor
- Hardware Acceptance
- Plug-ins

It also includes Getting Started, Settings & App Behavior and a Math & DSP
Reference.

Search spans article titles, summaries, workflow text, keywords, equations and
math explanations.

### Math & DSP details

Where useful, articles include expandable math cards. Every card is classified
as one of:

- **Core equation** — the mathematical operation itself.
- **Implementation relationship** — a compact relationship used by the feature,
  with text explaining additional smoothing, bounds, coefficient generation,
  buffering or qualification.
- **Diagnostic / model definition** — the metric or physical model used for
  reasoning, not an acceptance claim.

Initial math coverage includes:

- amplitude ↔ dB and the −18 dBFS VU reference;
- IIR biquad transfer functions;
- FIR convolution and linear-phase group delay;
- compressor/expander mappings and detector time constants;
- RMS, crest factor and stereo correlation;
- Linkwitz–Riley construction and delay/phase;
- binaural/HRTF convolution;
- Speaker Optimizer target error and before/after verification;
- Measurement Lab transfer-function deconvolution, impulse response and SNR;
- bounded room-correction target error;
- feed-forward causality budget; and
- the PR110 frequency-normalized multi-seat LF placement-variation metric.

The equations are deliberately accompanied by implementation notes so a compact
formula is never presented as the whole algorithm.

### Safety and evidence language

The guide must retain the established product boundaries:

- CI/software PASS is not physical acceptance.
- Hardware Acceptance keeps remote software, physical hardware and independent
  physical review as separate authority classes.
- Protected split-driver work requires genuinely independent crossed-over and
  limited outputs.
- Coherent timing requires a valid common time reference.
- Speaker-level amplifier output must never be connected directly to a
  line-level ADC input.
- Feed-forward ANC remains physically gated.

## Planned follow-on slices

### Slice 2 — Implementation-audited math & contextual help

- Audit feature math against the exact implementation and tests.
- Add equations/definitions for remaining mathematically meaningful controls.
- Add context links from production workspaces into the matching guide article.
- Add glossary and cross-references for shared concepts such as dBFS, dBTP, Q,
  FIR, IIR, latency, phase, coherence, confidence and evidence authority.
- Keep heuristic/model-based quantities labeled as such.

### Slice 3 — Workflow consistency

- Standardize Preview / Apply / Verify / Revert / Rollback language.
- Standardize blocking, warning, informational and success states.
- Review destructive or hardware-sensitive actions for confirmation quality.
- Reduce duplicated explanation when a guide deep-link is more useful.

### Slice 4 — Accessibility, responsiveness & visual polish

- Keyboard navigation and focus order.
- VoiceOver names/values/hints for custom controls and charts.
- Dynamic layout/window-size review.
- Avoid expensive analysis or redraw work on the main thread.
- Audit empty/loading/error states and long-running measurement feedback.

### Slice 5 — Remote UX closeout

- Production information-architecture regression.
- User-guide coverage/search/math tests.
- Apple Silicon Debug/Release builds.
- Full cumulative XCTest regression.
- Remote UX acceptance report.

Physical PR112 H01–H08 execution remains a separate hands-on campaign.

## Stack / merge boundary

**Base:** `feature/pr112a-remote-hardware-acceptance-infrastructure` at
`0df13292ba02ea5d21c094fabeb48894d94c2b1d`.

Leave PR113, PR112A and every ancestor **OPEN, DRAFT and UNMERGED**. Do not
merge/rebase/close them or modify `main` from this work.
