# Epic files

One file per epic: `docs/epics/E<n>.md`. Written by epic-planner, kept up to date by slice PRs.

Sections, in order: Status (at most five lines), Goal, What exists today, Design note, Slices,
Feature flag, Bench checks, Open questions for the owner, `## Gaps`, `## Log`.

## Gap ledger (`## Gaps`)

Every epic has a `## Gaps` section (empty at creation). A gap is anything found while building
that is not finished or not proven: "not wired", "left for", follow-ups, verifier limits or
excluded ranges, skipped reviewer notes, weakened or replaced tests, unverified claims.

Entry format:

    - G<n> [state] description (found in <slice/PR>; owner slice: <slice or none>)

States:

- `open-question`: needs an owner decision. The question is written in the entry, with a
  recommendation.
- `scoped`: the answer is clear. The entry names the owning slice, which must have a matching
  unchecked plan item. Only that slice (or the owner, e.g. "fix G3") may fix it.
- `closed`: fixed or dropped, with the PR number.

Rules: a slice with an `open-question` gap is not ticked; a flag-graduation or ship slice needs every
gap in its epic `closed`. A gap whose only remaining work is a bench or owner acceptance check may be
closed as "moved to E22 item X" only when E22 (`docs/PROGRAM_PLAN.md`) holds a matching unchecked item.
Software gaps are never moved. (Owner confirmed 11 Nov 2026.) Numbers are never reused. See AGENTS.md section 12.

## Flag graduation (owner, 11 Nov 2026)

An epic's last slice is "graduate flag", not "remove flag": the flag stays in `FeatureFlag.all` with
`graduated: true` (defaults on, release builds too) once the software is done, wired through the UI
and tested, with every gap closed. Graduated means available, never armed (live ANC and MIMO keep
`LiveTreatmentArm`). Bench "is it good" acceptance belongs to E22. Removal of graduated flags is the
flag-cleanup phase (FC) after E22 and before E18. The registry and audit are in `docs/FEATURE_FLAGS.md`.

## Programme audit

Owner decision 6 Nov 2026: once E26 is done, audit every completed epic against AGENTS.md section 12
(`[x]` means reachable from the shipped UI, end-to-end tests through production wiring for ship
slices, no stale ticks or unrecorded gaps). Then repeat the audit after each epic completes. Findings
are recorded as gaps in the audited epic's `## Gaps`; the audit fixes nothing unprompted.

## ABI number reservation

Parallel slices that bump the graph ABI collide on the number. See `docs/ABI_NUMBERS.md`: claim the
next number there at slice start, and renumber only your own claim if another slice merges first.
Tests compare against `N60_GRAPH_ABI_VERSION` (and the other `N60_*_ABI_VERSION` macros), never a literal.
