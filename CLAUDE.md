# Claude Code instructions for Notch Sixty

## Start here

- The owner starts work with `/next` (or `/next E2`). That command holds the full workflow.
- Plan: `docs/PROGRAM_PLAN.md`. Per-epic plans and status: `docs/epics/E<n>.md`.
- Helper agents in `.claude/agents/`: code-scout, build-test-runner, plan-tracker, pr-writer
  (Haiku) and realtime-reviewer (Sonnet).

**Current focus:** E4 (`docs/epics/E4.md`). S2–S7, S9a and S9b1 merged (#157–#164); S9b2 (feed-forward survey flow) in review (needs-owner); S9c (shadow wiring) next. Bench work (S8, S10, E3) is deferred to E22. E19 still needs a plan.
<!-- plan-tracker keeps the line above current -->

@AGENTS.md

## Current program

All work follows the v1 program plan in `docs/PROGRAM_PLAN.md` (21 epics, E1–E21, in four phases with
gates G1–G4). Read the relevant epic there before planning any change, and name the epic ID in
every branch, commit and PR (for example `e2/macos26-deployment-target`).

Owner decisions of 17 Oct 2026. `AGENTS.md` records the trunk, macOS 26, feature-flag,
behavioural-test and three-workflow rules (E1 S6). Where the rest conflicts with `AGENTS.md`, these
win until E21 updates `AGENTS.md`:

- `main` is the trunk. Use short-lived branches and PRs, one slice each, behind the epic's
  feature flag. Do not build stacked draft chains.
- Minimum macOS is 26.
- Speaker ANC (Quiet Zone) is the flagship differentiator; never enable live ANC or live MIMO
  room treatment outside their written authorisation paths.
- Every feature must work at every device rate up to 384 kHz.
- The engine core moves to C++20/23 behind one versioned C interface (E21). New engine code goes
  in C++; existing C migrates file by file as E6 rewrites each stage. Swift stays for the macOS
  app shell, Core Audio control and UI.
- Nothing in the engine core may depend on an Apple framework; use the FFT abstraction (vDSP on
  Apple, a BSD-licensed FFT elsewhere). No GPL dependencies.
- Performance architecture: whole-buffer processing, multirate low-frequency paths, multiple
  realtime threads (Audio Workgroups), SIMD via a portable layer, best-in-class algorithms.
- v1 ships only when every scoped epic is complete.

## Session protocol

The owner already has a local test build of `main`; do not rebuild a baseline unless asked.

`/next` holds the full step-by-step workflow; follow it. In short:

1. **Orient cheaply** from the target epic's section of `docs/PROGRAM_PLAN.md` and
   `docs/epics/E<n>.md`.
2. **Plan only for a new epic** or a slice whose approach isn't recorded yet; save it to
   `docs/epics/E<n>.md` and get approval. Otherwise build straight away.
3. **One branch per PR** named `e<n>/<slice>`, behind the epic's feature flag (add it to
   `FeatureFlag.all`; see `docs/FEATURE_FLAGS.md`). Small related slices may share one PR.
   E1 and E2 do not need flags.
4. **Verify narrowly** (affected tests only; CI runs the full suite), and use
   `realtime-reviewer` for any engine or realtime change.
5. **Plan updates ride in the same PR** (plan-tracker); never open a separate plan-update PR.
6. **Merge policy:** low-risk PRs are merged by Claude with `gh pr merge --squash
   --delete-branch` once CI is green. PRs that touch the realtime engine, Core Audio transport,
   `AudioIOEngine.swift`, ANC / MIMO / protection code, `AGENTS.md`, `.claude/`, workflows,
   dependencies, the minimum OS, or remove a user-visible feature get the `needs-owner` label
   and wait for the owner.
7. **Keep going** to the next slice after a merge; stop after three merged PRs, or at a
   `needs-owner` PR, a plan approval, bench work, or a phase gate.
8. **Bench work:** when a step needs physical hardware, write the steps as a checklist in
   `docs/epics/E<n>.md` under "Bench checks", tell the owner, and stop that slice there.

Ask the owner before: changing `AGENTS.md` policy, adding a third-party dependency, raising the
minimum OS, removing a user-visible feature, or enabling any live ANC or MIMO treatment path.

## Conserving tokens

- The project model is `opusplan`: Opus plans, Sonnet executes. For design-heavy slices (E4
  adaptive ANC, E6 graph design, E10 mixed-phase, E19 MIMO), the owner may switch to
  `/model opus` for that session.
- Delegate searching to `code-scout`, builds and tests to `build-test-runner`, plan updates to
  `plan-tracker` and PR text to `pr-writer` (all Haiku). Use `realtime-reviewer` (Sonnet) for
  engine reviews. Do not do these jobs in the main session.
- Never read whole large files: `AudioIOEngine.swift` (4,500+ lines), `N60RenderKernel.c`,
  `ProductProfiles.swift`, `docs/PROGRAM_PLAN.md`. Grep first, then Read a line range.
- Do not open `docs/PR*.md`, `docs/archive/`, `ci/validate_*.py` or per-PR workflows unless
  the task is about them.
- Keep replies short: what changed, test results, what needs the owner. No recaps of the plan.
- Up to three PRs per session; if the session is getting long, ask the owner to run `/compact`
  before the next slice. Do not re-read files already read in this session unless they changed.
- Never read full CI logs: `gh run view --log-failed` for the failing step only.

## Engineering rules for every slice

- DSP changes get deterministic XCTests and an acoustic reference-lab case at the standard
  rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
- Do not add new `ci/validate_*.py` source-text validators; write behavioural XCTests instead.
- List required bench/hardware checks in each PR; remote CI never substitutes for them.
