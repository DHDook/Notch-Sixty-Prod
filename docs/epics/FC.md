# FC Flag cleanup

## Status

- FC1 done (flags-off nightly, G1 closed). Runs after E22 and before E18 (owner decision, 11 Nov 2026, flag graduation).
- Open owner decisions: none.
- Plan: `docs/PROGRAM_PLAN.md` (FC); registry and audit in `docs/FEATURE_FLAGS.md`.

## Goal

Epics end by graduating their flag (default on, stays in `FeatureFlag.all`), not by removing it. FC removes every
graduated flag and its dead branch after the E22 bench has judged the features, as a rolling set of small per-epic
PRs rather than one giant epic. Flags are removed only when the bench has no open item against the feature.

## Slices

### FC1 `fc/flags-off-ci` (needs-owner: workflows; before the first graduation)

- [x] `macos-full.yml` runs the full XCTest suite twice, graduated flags on (the default) and then with every graduated
  flag off through `-NotchSixtyFeatures -<id>`, so the flags-off path stays tested while flags exist (G1).
- [x] A behavioural XCTest that a release-style `FeatureFlags` resolves every `graduated` flag on and the
  launch argument turns each off.

### FC2 onward `fc/remove-<epic>-flags` (one small PR per epic, in the order below)

- [ ] For each epic with a graduated flag: delete the flag from `FeatureFlag.all` and `docs/FEATURE_FLAGS.md`, delete every
  check that reads it and its dead branch, keep tests that exercised the on path, and delete the flags-off tests.
- Order: E26, E28, E9, E13, E4 (non-live flags first, then live-output flags), E19, E7, E15, E17, E20, E21, E29;
  `e6.legacy-kernel` is removed by E23, not here.
- Never remove a flag that still has an open E22 bench item against its feature.
- Live ANC and MIMO: removing a flag never removes `LiveTreatmentArm` or the written authorisation path.

## Gaps

- G1 [closed, FC1 PR, 11 Nov 2026: `macos-full` runs the suite a second time with `TEST_RUNNER_NOTCHSIXTY_GRADUATED_FLAGS_OFF=1`, a debug-only env var that `FeatureFlags` maps to every graduated flag off] The nightly `macos-full` run does not yet run the suite with graduated flags off (found in the flag graduation policy PR, 11 Nov 2026; owner slice: FC1, which must land before the first epic graduates a flag)

## Log

- 11 Nov 2026: epic created by the flag graduation policy PR.
- 11 Nov 2026: FC1 built. The XCTest host cannot take launch arguments, so debug builds read `NOTCHSIXTY_GRADUATED_FLAGS_OFF=1` (forwarded by xcodebuild as `TEST_RUNNER_`-prefixed); release ignores it.
