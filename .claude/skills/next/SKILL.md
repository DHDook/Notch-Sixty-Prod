---
name: next
description: Continue the Notch Sixty v1 program plan. Finds the next slice (or the epic given), builds it on its own branch, verifies it, opens a PR, merges it when CI is green if it is low-risk, and continues to the next slice.
argument-hint: "[epic, e.g. E2]"
disable-model-invocation: true
---

Continue the v1 program plan. Target: $ARGUMENTS (if empty, use "Current focus" in `CLAUDE.md`).
The owner does not use git directly: do every git and GitHub step yourself and explain anything
that needs their action in plain words.

0. **Sync.** If the current branch is `main` and `git status --porcelain` shows no tracked
   changes, run `git pull --ff-only origin main`. If that brought in changes to `CLAUDE.md` or
   `.claude/`, tell the owner to restart the session and stop. If the current branch is not
   `main`, report the branch and its last commit, and ask whether to continue there or return
   to `main`.
1. **Locate the epic without reading the whole plan.** Run
   `grep -n '^## \|^### E' docs/PROGRAM_PLAN.md` to get line numbers, then Read only the target
   epic's line range. If `docs/epics/<EPIC>.md` exists, read it too; it records approved plans
   and slice status.
2. **Pick the work.** The first unchecked slice whose dependencies are met. If the next two or
   three slices are small and related (together under about 400 changed lines, excluding
   generated or deleted files) and in the same risk class (step 7), do them as one PR. State
   what you picked in one sentence.
3. **Plan only when needed.** A new epic, or a slice whose approach is not already in
   `docs/epics/<EPIC>.md`: use code-scout to find the relevant files, write the plan to
   `docs/epics/<EPIC>.md` (goal, slices, files, tests, bench checks, flag name, status line),
   then stop and ask the owner to approve it. Otherwise go straight to building.
4. **Build.** Create branch `<epic-lowercase>/<slice-name>` from an up-to-date `main` and make
   the change.
5. **Verify locally, narrowly.** Use build-test-runner to build and run only the test classes
   and harnesses the change affects; CI runs the full suite, so do not run it locally unless
   the change is broad or CI failed. If the change touches the engine, `NotchSixty/Audio/Realtime`,
   or anything called from an audio callback, use realtime-reviewer and fix what it flags.
6. **Record progress in the same PR.** Use plan-tracker to tick the slice's boxes in
   `docs/PROGRAM_PLAN.md`, update `docs/epics/<EPIC>.md`, and update "Current focus" in
   `CLAUDE.md`, as part of this branch. Never open a separate plan-update PR.
7. **Ship.** Commit, push the branch, get the PR text from pr-writer, and run `gh pr create`.
   Then classify the PR:
   - **Owner review required** if it touches any of: `NotchSixty/Audio/Realtime/`, the engine
     core, `NotchSixty/Audio/CoreAudio/`, `AudioIOEngine.swift`, ANC / Quiet Zone / MIMO
     treatment code, protection or limiter code, `AGENTS.md`, `.claude/`, `.github/workflows/`,
     a new third-party dependency, the minimum OS, or removal of a user-visible feature.
     Add the PR label `needs-owner`, report, and stop.
   - **Otherwise low-risk.** Wait for CI with `gh pr checks <number> --watch --fail-fast`
     (Bash timeout 600000). If it passes, merge with `gh pr merge <number> --squash
     --delete-branch`. If it fails, read only the failing step's log, fix, push, and wait
     again (at most two fix rounds, then report and stop).
   If `gh` is missing or not signed in, give the owner the link
   `https://github.com/DHDook/Notch-Sixty-Prod/compare/main...<branch>?expand=1` and the PR
   text to paste, and stop. Never push to `main` directly.
8. **Continue or stop.** After a merge, switch to `main`, pull, and go back to step 1 for the
   next slice. Stop and report when: three PRs have merged in this session, a PR needs the
   owner, a plan needs approval, a step needs bench hardware (write the checklist in
   `docs/epics/<EPIC>.md` under "Bench checks"), or a phase gate is reached.
9. **Report** in at most five lines per PR: what changed, the PR link, merged or waiting, test
   results, and any bench checks the owner must do.

When the owner says a `needs-owner` PR is merged: switch to `main`, pull, delete the local
branch, and continue from step 1.
