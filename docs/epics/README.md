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

Rules: a slice with an `open-question` gap is not ticked; a flag-removal or ship slice needs every
gap in its epic `closed`. Numbers are never reused. See AGENTS.md section 12.
