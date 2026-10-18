# PR106 Remote Software Closure

Status: **REMOTE SOFTWARE COMPLETE — PHYSICAL LAB ACCEPTANCE PENDING**

Branch: `feature/pr106-advanced-speaker-measurement-lab`

Base: PR105 / GitHub PR #106.

## Final remote scope

PR106 delivers the Advanced Speaker Measurement Lab as a measurement and
diagnostic surface. It does not convert Lab evidence into automatic correction
or deployment authority.

Remote-complete capabilities:

1. Capability planner with explicit geometry and minimum-repeat requirements.
2. Persistent guided Lab sessions and safe live acquisition.
3. Whole-speaker on-axis/off-axis relative directivity analysis.
4. Near-field subwoofer component diagnostics with no false far-field splice.
5. Explicit-window quasi-anechoic magnitude estimates with bounded trust band.
6. Bounded two-level transfer level-dependence diagnostics.
7. Exact protected-driver excitation through production crossover and
   per-driver EQ/trim/polarity/delay/limiter processing.
8. Live protected Low/Mid/High acquisition bound to one exact physical route.
9. Simultaneous microphone + electrical reference capture on one ADC timeline.
10. Reference-aligned coherent Main/Sub relative timing/phase diagnostics.
11. Compact report/history/JSON/CSV export.
12. Production SYSTEM → Measurement Lab workflow and guarded protocol composer.

## Safety contracts preserved

- PR103 raw physical-lane behavior is unchanged.
- Protected-driver Lab acquisition uses only the dedicated PR106 protected path.
- Low/Mid/High capture requires an active crossover that produces the requested
  bus and an enabled limiter on that exact driver-processing path.
- Direct-driver excitation requires an explicit conservative level no hotter
  than -24 dBFS.
- Protected excitation is rendered through the same production crossover and
  driver-processing code used by live playback.
- Coherent Main/Sub diagnostics require simultaneous shared-time reference
  evidence and stable reference-path qualification.
- The current coherent implementation remains same-reference-output-device only;
  multi-device cross-clock phase is not certified.
- Installed-room, near-field and quasi-anechoic evidence are labeled according
  to their physical limits.
- Harmonic/intermodulation distortion is not claimed by the two-level transfer
  diagnostic.
- Lab reports remain measurement-only: `canDeploy == false` and no Lab UI
  exposes correction/apply controls.

## Final verified pre-closeout head

The full production UI integration head
`7111ad1edcf88eb8bd8428b2a709c3c8494575ba` passed:

- push run 38232865632;
- pull-request run 38232870524.

Both passed:

- PR106 measurement-lab validator;
- inherited PR105 guided-optimizer validator;
- Apple Silicon Debug build;
- full targeted PR106 Lab test suite; and
- full XCTest regression.

The documentation/validator closeout commit created after that head must pass the
same exact-head workflow before it becomes the final remote closure head.

## Physical acceptance still required

Remote closure does **not** certify:

- microphone distance/angle placement accuracy;
- actual room reflection timing;
- real crossover/limiter behavior under attached hardware loads;
- driver excursion/thermal/electrical safety;
- acoustic distortion/compression performance;
- coherent timing robustness on real DAC/ADC hardware;
- multi-device clock-domain behavior;
- subwoofer port/radiator physical splice validity in a real enclosure;
- subjective usefulness of the diagnostics; or
- release readiness of measurement presets/workflows on representative systems.

## Merge state

PR106 remains draft, open and unmerged until physical Lab commissioning is
completed or the user explicitly chooses to merge the remote-complete stack.
