# Claude Code instructions for Notch Sixty

## Start here

- The owner starts work with `/next` (or `/next E2`). That command holds the full workflow.
- Plan: `docs/PROGRAM_PLAN.md`. Per-epic plans and status: `docs/epics/E<n>.md`.
- Agents in `.claude/agents/`: epic-planner (Opus, plans a new epic), slice-builder (Sonnet,
  builds one slice in a fresh context), realtime-reviewer (Sonnet), and code-scout,
  build-test-runner, plan-tracker, pr-writer (Haiku). `/next` itself runs on Sonnet.

**Current focus:** E11 (measurement suite), slice 4 of 10: `e11/waterfall-spectrogram-gated` (low-risk)
<!-- plan-tracker keeps the line above current -->

@AGENTS.md

## Current program

All work follows the v1 program plan in `docs/PROGRAM_PLAN.md` (23 epics, E1–E23, in four phases with
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

1. **The main session coordinates; slice-builder builds.** Each slice is built by the
   slice-builder agent in its own fresh context, so the main conversation only collects short
   summaries and does not need compacting between slices.
2. **Plan only for a new epic** (epic-planner, Opus) or a slice whose approach isn't recorded
   yet; the plan goes to `docs/epics/E<n>.md` for approval. Otherwise build straight away.
3. **One branch per PR** named `e<n>/<slice>`, behind the epic's feature flag (add it to
   `FeatureFlag.all`; see `docs/FEATURE_FLAGS.md`). PRs aim for about 800–1,500 changed lines of
   product code: combine small slices, split only to separate risk classes. Never open a PR that
   only edits plans or records decisions (a new epic plan from epic-planner is the exception).
   The order of epics is the "Execution order" list in `docs/PROGRAM_PLAN.md`.
4. **Verify narrowly** (affected tests only; CI runs the full suite), and use
   `realtime-reviewer` for any engine or realtime change.
5. **Plan updates ride in the same PR** (plan-tracker). Epic files keep a Status of at most
   five lines; history goes in their `## Log` section, which agents only grep when needed.
6. **Merge policy:** low-risk PRs are merged by Claude with `gh pr merge --squash
   --delete-branch` once CI is green. PRs that touch the realtime engine, Core Audio transport,
   `AudioIOEngine.swift`, ANC / MIMO / protection code, `AGENTS.md`, `.claude/`, workflows,
   dependencies, the minimum OS, or remove a user-visible feature get the `needs-owner` label
   and wait for the owner.
7. **Keep going.** After a merge, or while a `needs-owner` PR waits, continue with the next
   slice that is independent of open PRs (branch from `main`, never stack). Stop after four PRs
   in a session, two open `needs-owner` PRs, a plan approval, bench work, or a phase gate.
8. **Bench work:** when a step needs physical hardware, write the steps as a checklist in
   `docs/epics/E<n>.md` under "Bench checks", tell the owner, and stop that slice there.

Ask the owner before: changing `AGENTS.md` policy, adding a third-party dependency, raising the
minimum OS, removing a user-visible feature, or enabling any live ANC or MIMO treatment path.

## Conserving tokens

- Opus is used only by epic-planner, for new epic plans. `/next` runs on Sonnet whatever model
  the session shows, slice-builder and realtime-reviewer use Sonnet, and the other helpers use
  Haiku. The project model is Sonnet; switch with `/model opus` only for a
  one-off hard question.
- Delegate: slice work to `slice-builder`; searching to `code-scout`; builds and tests to
  `build-test-runner`; plan updates to `plan-tracker`; PR text to `pr-writer`; engine reviews to
  `realtime-reviewer`. Any other subagent defaults to Haiku. Do not do these jobs in the main
  session.
- Never read whole large files: `AudioIOEngine.swift` (4,500+ lines), `N60RenderKernel.c`,
  `ProductProfiles.swift`, `docs/PROGRAM_PLAN.md`. Grep first, then Read a line range.
- Do not open `docs/PR*.md`, `docs/archive/`, `ci/validate_*.py` or per-PR workflows unless
  the task is about them.
- Keep replies short: what changed, test results, what needs the owner. No recaps of the plan.
- Never read full CI logs: `gh run view --log-failed | tail -60` for the failing step only.
- Context auto-compacts at 200k tokens (`autoCompactWindow`). Between unrelated tasks the owner
  can use `/clear`, which costs nothing; `/compact` itself reads the whole conversation.

## Compact instructions

When compacting, keep: the epic and slice in progress, branch names, PR numbers with their
status (open, merged, needs-owner), failing test names and the one-line cause, and decisions the
owner made in this session. Drop: file contents, diffs, build and test logs, and search results.

## Engineering rules for every slice

- DSP changes get deterministic XCTests and an acoustic reference-lab case at the standard
  rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
- Do not add new `ci/validate_*.py` source-text validators; write behavioural XCTests instead.
- List required bench/hardware checks in each PR; remote CI never substitutes for them.
