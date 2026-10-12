# PR110 — Advanced Speaker & Subwoofer Placement Optimizer

**State: Slices 1–2 implemented; exact-head CI and all real-room validation pending.**

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

**Slice 3 — Measurement-aware toe-in and per-speaker ranking.**
Consume source-matched PR106 off-axis/on-axis relative measurements only when
angle, measurement radius, mic, routing and repeat/SNR evidence qualify.
Treat missing off-axis measurements as inconclusive, never as a flat directivity
response. Rank practical placement *experiments* with transparent tradeoffs and
uncertainties, not guaranteed numerical acoustic improvements.

**Slice 4 — Multi-seat and Sub placement.** Incorporate measured PR92 room
bass variation and qualified PR103/106 individual-sub captures. Explore
bounded physical Sub positions as a separate problem from PR108's independent
digital timing/polarity commissioning. Preserve physical-output topology and
clock constraints. Never confuse independent sub calibration with a line-level
Sub chained from stereo pre-out.

**Slice 5 — Measured physical before/after verification.** One actual physical
move per experiment, same matched microphone positions/settings/routing,
fresh captures, quality and identity gating, measured
improvement/regression/inconclusive outcome. Failed experiments can be
rejected without modifying the Playback System. Only measurements on real
hardware may confer physical acoustic acceptance.

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
