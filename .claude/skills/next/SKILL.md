---
name: next
description: Continue the Notch Sixty v1 program plan. Finds the next slice (or the epic given), plans it, builds it on its own branch, verifies it with the helper agents and opens a PR.
argument-hint: "[epic, e.g. E2]"
disable-model-invocation: true
---

Continue the v1 program plan. Target: $ARGUMENTS (if empty, use "Current focus" in `CLAUDE.md`).

0. **Sync.** If the current branch is `main` and `git status --porcelain` shows no tracked
   changes, run `git pull --ff-only origin main`. If that brought in changes to `CLAUDE.md` or
   `.claude/`, tell the owner to restart the session and stop. If the current branch is not
   `main`, report the branch and its last commit, and ask whether to continue there or return
   to `main`.
1. **Locate the epic without reading the whole plan.** Run
   `grep -n '^## \|^### E' docs/PROGRAM_PLAN.md` to get line numbers, then Read only the target
   epic's line range. If `docs/epics/<EPIC>.md` exists, read it too; it records approved plans
   and slice status.
2. **Pick the slice.** The first unchecked item (or approved-plan slice) whose dependencies are
   met. State it in one sentence.
3. **Plan if needed.** For an epic with no `docs/epics/<EPIC>.md`, or a slice touching more than
   a few files: use the code-scout agent to find the relevant files, write the plan to
   `docs/epics/<EPIC>.md` (goal, slices, files, tests, bench checks, flag name, status line),
   then stop and ask the owner to approve it.
4. **Build.** Create branch `<epic-lowercase>/<slice-name>` from an up-to-date `main` and make
   the change.
5. **Verify.** Use the build-test-runner agent to build and run the affected tests (full suite
   only if the change is broad). If the change touches the engine, `NotchSixty/Audio/Realtime`,
   or anything called from an audio callback, use the realtime-reviewer agent and fix what it
   flags.
6. **Ship.** Commit, push the branch, use the pr-writer agent for the PR text, then
   `gh pr create`. If `gh` is missing or not signed in, give the owner the link
   `https://github.com/DHDook/Notch-Sixty-Prod/compare/main...<branch>?expand=1` and the PR
   text to paste. Never push to `main`.
7. **Report** in at most five lines: the slice, the PR link, test results, and any bench checks
   the owner must do. Then stop.

After the owner says the PR is merged: switch to `main`, pull, delete the local slice branch,
then use the plan-tracker agent to tick the boxes and update "Current focus" in `CLAUDE.md`,
and commit that on a `docs/plan-update` branch with a PR. The owner does not use git directly;
do all git steps yourself and explain any that need their action in plain words.
