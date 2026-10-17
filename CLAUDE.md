# Claude Code instructions for Notch Sixty

@AGENTS.md

## Current program

All work follows the v1 program plan in `docs/PROGRAM_PLAN.md` (21 epics, E1–E21, in four phases with
gates G1–G4). Read the relevant epic there before planning any change, and name the epic ID in
every branch, commit and PR (for example `e2/macos26-deployment-target`).

Owner decisions of 17 Oct 2026. Where they conflict with `AGENTS.md`, these win until E1/E21
update `AGENTS.md`:

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

## How to work an epic

1. Plan first: produce a plan for one epic (or one slice of it), get it approved, and save it as
   `docs/epics/E<n>.md` before editing code.
2. Build in slices with deterministic tests; DSP changes also get an acoustic reference-lab case
   at the standard rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz).
3. Do not add new `ci/validate_*.py` source-text validators; write behavioural XCTests instead.
4. List required bench/hardware checks in each PR; remote CI never substitutes for them.
5. When a slice lands, tick its box in `docs/PROGRAM_PLAN.md`.
