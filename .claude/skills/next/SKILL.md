---
name: next
description: Continue the Notch Sixty v1 program plan. The main session acts as a thin coordinator - each slice is built by the slice-builder agent in a fresh context, then merged here when CI is green if it is low-risk.
argument-hint: "[epic, e.g. E6]"
disable-model-invocation: true
---

Continue the v1 program plan. Target: $ARGUMENTS (if empty, use "Current focus" in `CLAUDE.md`).
The owner does not use git directly: do every git and GitHub step and explain anything that
needs their action in plain words.

You are the coordinator. Keep this conversation small: do not read source files, plans or logs
yourself beyond what the steps below name. All building happens in subagents.

0. **Sync.** If the current branch is `main` and `git status --porcelain` shows no tracked
   changes, run `git pull --ff-only origin main`. If that changed `CLAUDE.md` or `.claude/`,
   tell the owner to restart the session and stop. If not on `main`, report the branch and its
   last commit and ask whether to continue there or return to `main`.
1. **Pick the work.** Read the order with
   `sed -n '/^## Execution order/,/^## Phase 1/p' docs/PROGRAM_PLAN.md` (or use the epic in
   $ARGUMENTS). Take the first epic in that order with open slices whose dependencies are met,
   and read only its Status with `grep -n -A5 '^\*\*Status' docs/epics/<EPIC>.md`. Pick the
   next slice; slice-builder sizes the PR and may fold in the following small slice. Say what
   you picked in one sentence.
2. **Build it in a fresh context.** Start the slice-builder agent with: the epic ID, the slice
   name(s), one sentence of intent, and any owner decision from this session that affects it. Wait for its summary. Do not repeat its work.
   - "PLAN NEEDS APPROVAL": tell the owner the PR link and stop.
   - "BLOCKED": report the failure in two lines and stop.
3. **Merge or hand over.**
   - `needs-owner`: note the PR link and why it needs the owner, and do not wait. Go back to
     step 1 and pick the next slice that does not depend on any open `needs-owner` PR and will
     not touch the same files (look further down the Execution order if needed; branch from
     `main`, never from an unmerged branch). Stop when two `needs-owner` PRs are open.
   - `low-risk`: run `gh pr checks <number> --watch --fail-fast` (Bash timeout 600000). If
     green, `gh pr merge <number> --squash --delete-branch`. If red, run
     `gh run view <run-id> --log-failed | tail -60`, resume the same slice-builder (SendMessage
     to it) with the failing lines to fix and push, then wait again. At most two fix rounds.
4. **Continue.** After a merge: `git switch main && git pull --ff-only origin main`, then back
   to step 1. Stop after four PRs in this session (merged or waiting), two open `needs-owner`
   PRs, a plan approval, bench work, a phase gate, or a block.
5. **Report** at the end: one line per PR (number, title, merged or waiting) and anything the
   owner must do.

When the owner says a `needs-owner` PR is merged, sync and continue from step 1.
