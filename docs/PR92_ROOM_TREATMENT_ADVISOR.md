# PR92 — Room Treatment Advisor

## Purpose

PR92 adds a separate, occasional-use acoustic advisory workflow that helps the
user decide whether a measured room problem is best addressed by physical room
treatment, speaker/listener placement, conventional DSP, active room treatment,
or Active Quiet Zone.

The Advisor is intentionally **not** Content Preset state and **not** Playback
System state. It is a read-only analysis tool over retained measurement projects.

## Product / UI boundary

The production sidebar gains a new category:

TOOLS
- Room Advisor

Room Advisor does not live under Playback or System.

While the Room Advisor workspace is selected:
- Content Preset and Playback System selectors are hidden from the toolbar;
- analysis may read any saved Room Correction measurement project directly from
  the project store without changing the selected Playback System;
- no recommendation is automatically applied;
- no live DSP graph is changed;
- no advisor state is persisted into Content Presets or Playback Systems.

The intended interaction is an occasional guided workflow:

1. **Measurements** — choose existing measurements or create them in the existing
   measurement workflow.
2. **Diagnose** — identify response, spatial, reflection and later decay problems.
3. **Actions** — explain which class of remedy is appropriate and why.
4. **Verify** — after a physical or placement change, re-measure and compare.

## PR92 first implementation slice

The first slice establishes the product boundary and immediately useful
measurement-derived recommendations.

### Independent project selection

Room Advisor enumerates saved Room Correction projects directly from
`RoomCorrectionProjectStore`. Selection is local to the Advisor session and does
not change the currently selected Playback System or Content Preset.

### Measurement readiness

The Advisor reports:
- retained measurement count;
- included measurement count;
- microphone identity/calibration availability;
- clipping and low-SNR warnings;
- whether analysis is single-position or multi-position.

One microphone moved between positions is the expected workflow. Simultaneous
microphone arrays are not required.

### Initial deterministic findings

The initial advisor is deliberately conservative and explainable.

1. **Low-frequency seat variation**
   - compares common response bins across included positions;
   - large seat-to-seat spread is classified primarily as a placement / spatial
     problem rather than something to fix with a large single-seat EQ boost;
   - the finding can point toward placement experiments or existing MIMO Active
     Room Treatment when appropriate.

2. **Deep low-frequency cancellation**
   - detects deep response valleys relative to the local low-frequency median;
   - warns against blindly boosting a likely acoustic cancellation;
   - with only one position, recommends nearby measurements before diagnosis is
     treated as spatially reliable.

3. **Strong early reflection**
   - uses the stored impulse response and measured direct-arrival timestamp;
   - reports reflection delay and level relative to the direct arrival;
   - recommends physical reflection/placement investigation rather than EQ.

These are advisory classifications, not claims that a wall, surface or room mode
has been uniquely identified without geometry/directional evidence.

## Recommendation classes

PR92 uses explicit remedy categories:

- **Measure More**
- **Placement**
- **Passive Treatment**
- **DSP Correction**
- **Active Room Treatment**
- **Active Quiet Zone**
- **No Action**

The UI explains *why* each category was selected. Later PR92 slices may add more
diagnostics, but must preserve the distinction between measured fact,
interpretation, and recommendation.

## Safety / truthfulness

- read-only with respect to playback state;
- no automatic filter generation or application;
- no automatic Room Treatment arming;
- no physical-treatment claim based only on frequency response;
- no unique reflection-surface claim without room geometry;
- no claim of RT60/EDT until the corresponding decay estimator is implemented
  and validated;
- low-confidence or incompatible measurement sets fail toward “measure more,”
  not aggressive recommendations.

## Planned follow-on within the new roadmap

PR93 will add optional room geometry and placement optimization.

PR94 will add treatment modeling and guided before/after verification.

Later ANC work remains separate:
- sequential multi-position Quiet Zone calibration;
- optional upstream feed-forward reference microphone;
- hybrid low-frequency ANC where causality and evidence permit.

No roadmap item requires an array of microphones around the listener’s head.
