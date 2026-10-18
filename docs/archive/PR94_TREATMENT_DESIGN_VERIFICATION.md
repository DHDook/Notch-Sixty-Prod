# PR94 — Physical Treatment Design & Verification

## Product boundary
PR94 lives under **TOOLS → Room Advisor**, an occasional-use offline advisory workflow.
Treatment plans are saved in project-scoped Advisor sidecars, never Content Preset or Playback System state.
No filter is generated, enabled or applied. No DSP, processing transport, active treatment or runtime state can be changed.

## Design
A plan specifies treatments on validated room surfaces: broadband porous absorbers, bass traps,
diffusion candidates or preserved/untreated surfaces. Define surface-local normalized center coordinates,
width, height, thickness and optional air gap. Show placements on a room sketch.
Validate wall/floor bounds and reject overlaps/geometry changes that invalidate the plan.

Recommend **placement first** for spatial nulls and likely SBIR; physical absorption only for
measured strong early reflections or excess decay. Prefer substantial LF treatment for LF ringing;
very thin panels cannot credibly solve deep bass modal decay. Never predict an exact decibel
change or RT60 improvement based solely on panel thickness or coverage.
If coefficients from a manufacturer become available in the future, treat those as evidence
with provenance—not as a guarantee of the in-room result. Do not recommend generic diffusion
unless there is space and reflection evidence; leave appropriate surfaces untreated.

The room model remains rectangular in PR94, as established in PR93.

## Verification
Choose a baseline and a follow-up Room Correction project captured with the same routing,
microphone/calibration, sweep configuration, and identical named listening positions.
Require usable signal quality and comparable sample rates. The tool measures:
- normalized low-frequency response changes at matching seats, including peaks/nulls;
- seat-to-seat LF spread;
- frequency-dependent T20-derived decay where both measurements pass fit gates;
- early-reflection energy relative to direct arrival where valid.

A before/after change is observational, not proof of causal treatment efficacy.
Unmatched, poor-quality, missing or low-confidence data must be labeled **not comparable**,
never silently reported as improvement. Report improvements and regressions, and preserve
a read-only side-by-side evidence view for reviewing physical changes.

## UX
A dedicated Treatment Design & Verification section, following Geometry & Placement:
1. Review measured issues and recommended treatment zones.
2. Add/edit/remove treatment placements, dimensions and air gaps.
3. Inspect a top-down surface sketch and notes on plausible useful frequency range.
4. Save the proposed plan separately from playback state.
5. Select an independent saved follow-up measurement project and run before/after comparison.
6. Review comparison confidence, improvements, regressions and next measurement actions.
