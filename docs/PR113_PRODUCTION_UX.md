# PR113 — Production UX, Preferences & Reference

## Status

PR113 is the active remote production-polish milestone, stacked on the exact
remote/software-complete PR112A head
`0df13292ba02ea5d21c094fabeb48894d94c2b1d`.

Slices 1–4 are implemented. Slice 5 is the remote closeout/CI gate.

PR113 is deliberately presentation/control-plane work. It does **not** establish
PR112 physical H01–H08 evidence, release acceptance, live feed-forward ANC
authorization, or permission to merge the stacked PRs.

## Product goals

PR113 turns Notch Sixty's broad DSP and measurement feature set into a product
that is easier to learn, safer to operate and easier to audit without reducing
advanced capability.

The UX rules are:

1. Explain a feature where the user already is.
2. Use one vocabulary for Preview, Apply, Verify, Revert, Rollback and Deploy.
3. Expose implementation math without forcing it into the basic workflow.
4. Distinguish equations, diagnostic models, software evidence and physical
   acceptance.
5. Keep documentation read-only: opening help can never mutate DSP, routing,
   profiles, acceptance evidence or live audio.
6. Improve accessibility and responsive layout without moving DSP/analysis work
   onto the UI thread.

## Slice 1 — Preferences & Reference foundation

The former single scrolling Settings surface is now **Preferences & Reference**
with three destinations:

- **General** — About, Appearance, Volume Keys, App Presence, Startup,
  Permissions and Support.
- **User Guide** — searchable task/workflow documentation.
- **DSP Reference** — searchable equation/algorithm reference for advanced use.

The User Guide catalog is data-driven with stable article, section and formula
identifiers. Every production sidebar workspace has an explicit article:

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

Additional reference articles cover Getting Started, Preferences & App Behavior,
Workflow & DSP Glossary, and recurring DSP notation.

## Slice 2 — Implementation-audited math & contextual help

Every math card is explicitly classified as:

- **Core equation** — the mathematical operation itself.
- **Implementation relationship** — a compact relationship used by the feature,
  with surrounding implementation constraints documented.
- **Diagnostic / model definition** — a metric/model used for reasoning, not an
  acceptance claim.

Current audited coverage includes:

- linear amplitude ↔ dB and the −18 dBFS VU reference;
- IIR biquad transfer functions;
- FIR convolution and linear-phase EQ group delay;
- compressor/expander steady-state mappings;
- the exact one-pole dynamics coefficient
  `a = exp(-1 / (tau * sampleRate))`;
- RMS, crest factor and stereo correlation;
- Linkwitz–Riley construction and delay/phase;
- binaural/HRTF convolution;
- Speaker Optimizer bounded measured target error and measured before/after
  diagnostics;
- Measurement Lab transfer-function, impulse-response and SNR relationships;
- bounded Room Correction target error;
- **Room Correction's actual causal minimum-phase FIR construction via the real
  cepstrum** — specifically not a symmetric linear-phase room-correction FIR;
- feed-forward causality budget; and
- PR110's frequency-normalized multi-seat LF spread metric, which removes common
  level before scoring seat-to-seat variation.

Every main production workspace has a contextual `?` entry point that opens its
User Guide article. High-value parameter links currently jump directly into DSP
Reference for Equalizer Q/biquad math and compressor/expander ratio/time
constants.

The reference navigator is product-owned and carries only navigation state.
Opening documentation cannot start/stop audio, Apply DSP, edit a profile,
record evidence or authorize anything.

## Slice 3 — Workflow consistency & glossary

PR113 defines one product vocabulary:

- **Preview** — calculate/display a proposal without changing saved or live
  playback state.
- **Apply** — make an explicit state change; measurement-driven Apply may be
  provisional until fresh verification.
- **Verify** — collect/evaluate fresh evidence after a change.
- **Revert** — discard uncommitted editor/draft changes before a live Apply.
- **Rollback** — restore the retained pre-Apply state after a change has already
  occurred.
- **Deploy** — move a reviewed offline design into the selected Playback System.

The in-app glossary also defines dBFS, dBTP, headroom, IIR, FIR, Q, phase,
latency, coherence, confidence and evidence authority. It explicitly states that
confidence or software/model evidence cannot upgrade itself into physical
acceptance.

Existing specialized workflows retain useful qualifiers such as
**Approve & Apply Provisionally**, **Start Verification**, and **Rollback**
where those qualifiers convey real state/authority differences rather than
cosmetic wording.

## Slice 4 — Accessibility, responsiveness & visual polish

- Preferences & Reference now uses a responsive minimum/ideal window size rather
  than a fixed 960-point width.
- Contextual reference buttons expose explicit VoiceOver accessibility labels
  and hover help.
- Guide/DSP Reference sidebars use native selectable Lists, searchable fields
  and stable navigation identities.
- Formula text is selectable; targeted deep links automatically expand and
  scroll to the requested formula.
- Existing production workspace construction remains compatible because the
  contextual reference dependency is optional outside the product root.
- The main production navigation remains unchanged; documentation is not added
  as another DSP/workspace destination.

## Slice 5 — Remote UX closeout

The PR113 workflow performs:

- portable PR113 structure/authority audit;
- inherited PR112A, PR111, PR110 and PR109 safety-contract audits;
- Apple Silicon arm64 Debug build;
- targeted `ProductionInformationArchitectureTests`;
- unsigned arm64 Release build;
- full cumulative XCTest regression; and
- publication of `pr113-remote-ux-readiness.json`.

The readiness artifact may assert:

- `remoteUXSoftwareComplete=true`
- `preferencesAndReferenceAvailable=true`
- `userGuideCoverageComplete=true`
- `dspReferenceAvailable=true`
- `contextualReferenceLinksAvailable=true`
- `workflowVocabularyStandardized=true`

It is hard-coded to:

- `physicalAcceptanceComplete=false`
- `releaseAcceptanceComplete=false`
- `liveFeedForwardANCAuthorized=false`
- `mayMergeIntoMain=false`
- `physicalEvidenceSuppliedByCI=false`

## Safety and evidence boundaries retained

- CI/software PASS is not physical acceptance.
- Hardware Acceptance retains separate remote software, physical hardware and
  independent physical review authority classes.
- H05 whole-speaker Measurement Lab acceptance remains mandatory.
- Protected split-driver work requires genuinely independent, crossed-over and
  limited outputs.
- Coherent Main/Sub timing requires a valid common time reference.
- Never connect speaker-level amplifier output directly to a line-level ADC.
- Feed-forward ANC remains physically gated.
- A complete PR113 remote UX pass cannot merge the stack or satisfy PR112.

## Stack / merge boundary

**Base:** `feature/pr112a-remote-hardware-acceptance-infrastructure` at
`0df13292ba02ea5d21c094fabeb48894d94c2b1d`.

Leave PR113, PR112A and every ancestor **OPEN, DRAFT and UNMERGED**. Do not
merge/rebase/close them or modify `main` from this work.
