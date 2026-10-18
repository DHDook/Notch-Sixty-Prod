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
1. **Pick the slice.** Run `grep -n '^### E\|^- \[ \]' docs/PROGRAM_PLAN.md | head -80` and
   `grep -n 'Status' docs/epics/<EPIC>.md` for the target epic. Choose the first open slice
   whose dependencies are met; group two or three only if they are small, related and the same
   risk class. Say what you picked in one sentence.
2. **Build it in a fresh context.** Start the slice-builder agent with: the epic ID, the slice
   name(s), and one sentence of intent. Wait for its summary. Do not repeat its work.
   - "PLAN NEEDS APPROVAL": tell the owner the PR link and stop.
   - "BLOCKED": report the failure in two lines and stop.
3. **Merge or hand over.**
   - `needs-owner`: report the PR link and why it needs the owner, and stop.
   - `low-risk`: run `gh pr checks <number> --watch --fail-fast` (Bash timeout 600000). If
     green, `gh pr merge <number> --squash --delete-branch`. If red, run
     `gh run view <run-id> --log-failed | tail -60`, resume the same slice-builder (SendMessage
     to it) with the failing lines to fix and push, then wait again. At most two fix rounds.
4. **Continue.** After a merge: `git switch main && git pull --ff-only origin main`, then back
   to step 1. Stop after three merged PRs, or at a `needs-owner` PR, a plan approval, bench
   work, a phase gate, or a block.
5. **Report** at the end: one line per PR (number, title, merged or waiting) and anything the
   owner must do.

When the owner says a `needs-owner` PR is merged, sync and continue from step 1.
