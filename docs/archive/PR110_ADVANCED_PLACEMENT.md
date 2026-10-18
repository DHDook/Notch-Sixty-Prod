# PR110 — Advanced Speaker & Subwoofer Placement Optimizer

**State: Slices 1–5 implemented; Slice 5 exact-head CI and all real-room validation pending.**

**REMOTE SCOPE ONLY:** no acoustic, physical, release or merge acceptance is implied.

## Purpose

Extend the existing PR93 Room Advisor geometry model and PR103–106 Speaker
Measurement Lab evidence to guide physical speaker and subwoofer placement,
including independently movable left/right speakers, toe-in, speaker height,
subwoofer placement, and multiple listening positions. Every change is an
experiment that a user physically makes and remeasures; no automated move,
acoustic-result claim or DSP filter deployment is permitted.

The project remains clean-room proprietary, Apple Silicon and macOS only.
PR110 is stacked on draft PR109; PR109 and all earlier PRs stay draft/open and
unmerged while the owner is away from the Mac.

## Design principles

- **Read-only hypotheses** are the only output of the initial geometric search.
  A better geometric score, shorter path or on-axis aim does not prove improved
  bass response, imaging or speech clarity.
- Geometry, measurement identity and follow-up verification belong to
  Room Advisor/Measurement Lab project data, NOT a Content Preset or Playback
  System correction stage.
- Source-specific, geometry-matched microphone evidence must be independently
  qualified before acoustic scoring. Whole-speaker listening/near-field/
  directivity evidence must not be silently treated as a validated per-driver
  or subwoofer-coherent measurement.
- A modeled physical Sub position does not imply Notch Sixty has a separately
  controllable Sub output; conventional passive speakers and receiver line-level
  Sub connections may still participate in physical placement experiments.
- Invalid coordinates, missing device/mic identities and unsupported
  geometries fail closed. Rectangular boundaries are only approximations for
  rooms with open halls, alcoves or missing walls.
- Live speaker-connected ANC remains unauthorized. No PR110 placement score
  may arm ANC or alter a playback route, crossover, PEQ, FIR or limiter.

## Slice 1 — Bounded physical experiment generator

Reuses **PR93 `RoomGeometryModel`** without changing its persisted schema.
Adds `RoomAdvancedPlacementState` as optional project-scoped analysis state,
`RoomAdvancedPlacementExplorer` and
`RoomAdvancedPlacementExperiment` inside the existing compiled
`RoomGeometryPlacement.swift`. No new application target registration or
realtime callback code is required.

Proposed bounded **single-variable physical trials**:

| Dimension | Trial step | Boundary |
| --- | --- | --- |
| Left speaker x/y | ±15 cm independently | All positions in modeled room; L/R ordering and ≥30 cm separation retained |
| Right speaker x/y | ±15 cm independently | Same constraints |
| Left/right height | ±10 cm independently | Floor/ceiling room bounds |
| Left/right toe-in | ±5° independently | Finite configured angle within ±80° |
| Physical Sub 1…4 x/y | ±30 cm independently per modeled position | Each modeled Sub position inside room |
| Listening geometry | Primary seat + up to seven optional secondary seats | All coordinates inside room |

The only exposed numerical context is a *geometric* maximum difference
between left and right direct-path distances across all modeled seats. It is
**not an SPL prediction, acoustic-rank score, or correction recommendation**.
Candidates are deterministic and retain the original project's identity;
neither the original room state nor any playback state is modified.

The Slice 1 tests verify independent source moves, no invented subwoofer,
toe-in/height isolation, invalid-geometry exclusion, hard limits, stable
enumeration and multi-seat path metrics. A portable PR110 guard rejects
accidental Live Audio / DSP / Content Preset / Playback System ownership inside
the proposal-only extension. Apple Silicon CI builds the entire app and runs
both the retained and new PR110 XCTest suites.

## Remaining PR110 slices

**Slice 2 — Project persistence and UI (implemented, CI pending).**
The versioned `advisor-advanced-placement-v1.json` sidecar lives in the
selected Room Correction project directory. Its exact project ID and
coordinate validity are checked before load/save; missing files are treated
as optional, while malformed/unsupported files fail closed without touching
PR93's `advisor-geometry-v1.json`. The legacy room JSON and Playback System
are not migrated or rewritten.

Room Advisor → Geometry & Placement now exposes toe-in in degrees, up to
seven extra named-by-order listener seats, and up to four physical Sub
locations, with m/ft coordinate editing, explicit advanced Save/Revert,
unsaved warnings, and independent speaker/height/toe-in/Sub proposal cards.
Every **Inspect** action is display-only: no save, change to actual
geometry, DSP or output device. Editing a hypothetical pose does not assert
the hardware has moved. Saving advanced positions requires the actual room
geometry to be saved and structurally valid.

Controller and persistence XCTest check reload, project isolation,
corruption, unsupported versions, preview-only behavior, unsaved geometry
blocking, and clearing sidecar with geometry. The PR110 CI job runs these
tests and cumulative application regressions before any remote acceptance.

**Slice 3 — Measurement-aware toe-in (implemented; CI pending).**
Adds `RoomAdvancedToeInEvidenceAnalyzer` using the existing PR106
`SpeakerMeasurementLabDirectivityAnalyzer`, which requalifies every Lab
session's on-axis/off-axis captures (same source, route, microphone, radius,
sample rate, common grid, repeat count, SNR, clipping and arrival/phase gates).
A derived report from an arbitrary external caller is **not** accepted as
qualified by the production entry point.

The Room Advisor action **Inspect Latest Qualified Lab Directivity** looks
through recent Measurement Lab sessions matching the selected project's
Playback System and processes only whole-speaker `frontLeft/frontRight`
protocols with qualifying on-axis and off-axis groups. Before inspection the
user must explicitly confirm the speakers and angles physically match the
recorded setup; the project geometry and advanced settings must both be
saved and unchanged. This is an essential human attestation because the
PR106 Lab capture does not cryptographically bind physical pose to PR93
geometry. No unqualified source is used; no Lab session modifies DSP.

For only **±5° toe-in trial comparisons**, the analyzer computes signed
speaker-to-center-seat azimuth from room geometry, subtracts the stated
signed physical toe-in, and uses *only* qualified on-axis reference plus
same-side horizontal off-axis traces. It requires adequate 1–8 kHz
bandwidth, matched frequency grids, confidence, and no interpolation over
more than 20° of measured angular separation; no angular extrapolation or
cross-sign guesswork. An eligible result compares mean absolute spectral
deviation *from the measured on-axis reference*, with a transparent
directional indicator. It **does not predict SPL, perceived imaging,
listening-position EQ, acoustic improvement or a correction to apply**.
Missing signs, sparse angular evidence or mismatched identity produce
`inconclusive`, with a visible reason and no numeric ranking.

Moving either speaker in x/y, changing height, changing subwoofer position,
and multi-seat score remain purely unranked geometric experiments in Slice 3.
Physical listener-position verification remains a later required gate.

New negative tests exercise cross-project / cross-speaker evidence rejection,
clipping, low SNR, missing repeats, mismatched radius, unmeasured signed
angles, insufficient angular resolution, and explicit human confirmation.
The targeted XCTest group and cumulative macOS regression must pass at the
same exact PR110 commit before Slice 3 is remotely accepted.

**Slice 4 — Multi-seat and physical Sub A/B evidence (implemented,
CI pending).** Existing PR110 geometry search generates unranked physical Sub
movement experiments. The new `RoomAdvancedSubPlacementComparisonAnalyzer`
takes two independently captured PR103 measurement sets, explicitly marked
baseline and candidate, from the SAME Playback System, physical Sub source,
route, microphone/calibration, sample rate, and two to eight stable named/ID
listening seats. Each seat requires at least three stable, qualified sweeps in
each set. The candidate sweeps must postdate all baseline captures, with no
shared capture ID, and the user explicitly attests that **only the physical
Sub position changed**—not DSP, crossover, gain, phase, or mic seats.

Importantly, PR106 Sub *near-field* sweeps cannot stand in for in-room,
seat-matched bass measurements: near-field data characterize the source,
not room response at the listener. PR108 electrical-reference-timed digital
delay and polarity optimization remain separately owned and are never
reconfigured by PR110.

Only **after both positions have actually been measured** does the offline
analyzer compute frequency-aligned, per-frequency, across-seat magnitude
variation (RMS spread in dB) over mutually qualified 35–160 Hz samples,
requiring >=12 bins. It removes each frequency's common seat-average level,
so a global volume/gain change cannot masquerade as less inter-seat
variation. It does not assert target-curve accuracy, acoustic summation,
absolute SPL, dialogue clarity or listener preference. Positive
`reductionInInterseatSpreadDB` means only that seat-to-seat variation was
lower in the *measured A/B evidence*. Negative changes are retained as
regressions. Unmeasured proposed Sub locations stay unranked.

In Room Advisor the reviewer selects an inspected Sub trial and two local
Speaker Optimizer measurement archives, then confirms unchanged seats and
signal chain. Results are labeled **measurement only** and cannot deploy
anything. Identity, freshness, missing group repeats, clipped/noisy
captures, incompatible frequency grids, no physical Sub move or unsupported
hardware routes block a result. The UI resets pose confirmation and stale
results on switching projects, geometry, trial or capture pair.

The app cannot independently verify physical Sub/microphone pose from old
capture metadata alone. The explicit human attestation is therefore
necessary but does NOT confer physical acoustic certification. Later PR112
hands-on listening and measurement review remains outstanding. The source
sets' routing signature must not be mistaken for a cryptographically
verified unchanged DSP graph.

The source/test CI coverage includes A/B gain-shift invariance, measured
regression, positive comparison, wrong source/project/route/mic/seat,
clipping/missing repeats, clock/capture order and LF-band comparability.
This is a **physical-Sub-only** initial measurement bridge; generalized
multi-seat re-ranking of every *unmeasured* speaker height/placement trial
is deliberately withheld rather than invented.

**Slice 5 — Placement verification and review history (implemented;
exact-head CI pending).**

The Room Advisor now maintains an independent append-only project-sidecar
`advisor-placement-review-history-v1.json`, limited to 100 review records.
Every review captures a stable experiment ID, the actual baseline geometry,
the hypothetical target geometry, both advanced-placement snapshots, the
Playback System identity, a timestamp, measurement capture-set IDs (when
available), the precise evidence status, and an explanatory note. It does
not overwrite the geometry, treatment plan, Playback System, Content Preset
or any DSP stage. Records remain in the selected project even if the current
draft geometry changes. On corruption or unsupported schema, the archive
fails closed and refuses to overwrite damaged content.

**Before recording:** select a concrete physical placement experiment,
save unchanged reference room/advanced geometry, and explicitly attest the
physical move was performed. On a physical Sub trial, the optional separate
`fixedMicrophoneSeatsAndSignalChainConfirmed` attestation allows the
existing PR110 Slice 4 evaluator to recompute A/B evidence from independently
qualified PR103 capture sets at review time. The source, routing, microphone,
capture IDs, freshness, compatible LF bins and seat identities must pass.
The reviewer cannot manufacture a score from an unmeasured trial or trust an
old UI scalar. If the selected captures fail, the resulting review is
**INCONCLUSIVE** and its attempted capture IDs and blocker are retained.

Review status is deliberately narrow: positive qualified reduction in
**measured inter-seat 35–160 Hz magnitude variation** is displayed as
`Lower measured inter-seat LF variation` (improved on that diagnostic);
negative qualified reduction means `Higher measured inter-seat LF
variation` (regressed). A change within ±0.25 dB (an informational display
deadband, **not** a perceptual or statistical significance threshold), or
missing/unqualified evidence, is **INCONCLUSIVE**. Other speaker height,
position, and toe-in changes have no new verified before/after listening-seat
comparator in PR110 and are always recorded as inconclusive. This does not
claim absolute SPL, phase integration, target-curve compliance, listening
preference or an acoustically superior move.

The review card displays the record status, before/after IDs, observed
diagnostic, recorded date and explicit warning that neither hardware
acceptance nor DSP deployment occurred. The records are append-only:
historical entries have no edit/delete or apply action, and damaged histories
cannot be silently reset. Exact-head Apple Silicon CI must pass the new
history/persistence/controller regression plus all inherited suites.
Physical acceptance will remain separate at PR112.

**Explicit limitation:** app-side historical capture metadata cannot prove
that a person physically moved a Sub or kept a microphone at precisely the
same coordinates. The attestations and offline evaluator establish a
traceable **software review**, not authenticated physical acoustic proof.


## Remote vs physical acceptance

Remote CI can test the bounds, proposal determinism, geometry math, ownership,
persistence compatibility and UI wiring. Remote CI cannot move a loudspeaker,
measure actual reflections, confirm a preferred toe-in angle, authenticate a
microphone or calibrate a real Sub's room response.

Do **not** claim a physical improvement, complete real hardware acceptance,
authorize release or merge this PR based on software CI.

The target PR remains draft/open/unmerged. PR109 software acceptance also
remains independently bound to its own exact-head CI outcome; PR110's success
must not be used to retroactively declare PR109 complete.
