# PR107 — Physical FIR Commissioning & Acceptance

Status: **PREPARED — PHYSICAL ACCEPTANCE NOT YET CLAIMED**

Software checkpoint: `ce4e13467ff157e94231720bc9fdaf1ea8755395`

PR107's software path is complete and CI-green at the checkpoint above. This
runbook records the remaining physical work required before roadmap PR107 can
be accepted as production-ready on real hardware.

## Acceptance vocabulary

Record every item as exactly one of:

- **PASS** — executed on representative hardware and met the stated gate.
- **FAIL** — executed and did not meet the stated gate.
- **BLOCKED** — could not be executed because required hardware/software was not
  available.
- **N/A** — legitimately outside the tested playback use case.

Do not convert BLOCKED into PASS based on simulation or CI.

## P0 — Preflight and identity

Record:

- tested PR107 commit/build;
- Mac model / Apple Silicon generation;
- macOS version;
- physical output device / DAC;
- Playback System and Output Device Profile;
- sample rate;
- program layout;
- FIR tap count and corrected semantic roles;
- declared FIR group delay;
- reported convolution-engine latency;
- required automatic headroom reserve;
- measured/declared total program-path latency;
- measurement microphone/input identity and calibration;
- whether the test is audio-only or synchronized-video playback.

**PASS:** the live profile exactly matches the approved FIR receipt and no stale
route/sample-rate/profile warning is present.

## P1 — Baseline audio-only activation

Use the smallest representative configuration first: stereo or the actual
two-channel listening profile, one conservative accepted FIR candidate, normal
playback level, video not involved.

Verify:

1. engine starts successfully;
2. persisted FIR is not silently bypassed;
3. both channels remain present and correctly routed;
4. no startup burst, mute latch, obvious level collapse, or unstable transition;
5. stop/start preserves the exact deployment state; and
6. rollback returns to the captured pre-Apply state.

**PASS:** repeated start/stop and Apply/rollback cycles are stable and route
identity remains exact.

## P2 — Realtime performance / XRun margin

Test representative FIR lengths, including the normal/default candidate and the
largest tap count intended for production. Exercise the actual program layouts
that will be supported.

Collect, where available:

- CPU utilization;
- render failures / XRuns / underruns;
- callback overruns;
- thermal behavior during an extended playback session;
- memory growth across repeated start/stop cycles.

Use normal music plus a difficult broadband signal or test program. Do not infer
realtime safety from a short silent run.

**PASS:** no audible dropout, render failure, runaway CPU, or unbounded memory
growth, with practical operating margin on representative Apple Silicon.

## P3 — Impulse timing and channel coherence

Measure the physical acoustic impulse response at a fixed microphone position.

For the tested deployment compare:

- expected FIR incremental latency =
  convolution engine latency + declared group delay;
- expected total program-path latency including intentional Speaker Calibration
  delay;
- measured left/right or multi-channel relative timing;
- an uncorrected channel, if using a sparse FIR deployment, against a corrected
  channel.

The uncorrected channel must emerge aligned by the program-lane coherence
compensation rather than arriving early.

**PASS:** measured timing is consistent with the reported latency within the
measurement system's repeatability, and sparse corrected/uncorrected channels
remain coherently aligned.

## P4 — Automatic headroom and clipping

Use a candidate with nonzero modeled positive gain so the automatic FIR headroom
reserve is exercised.

Test:

- a near-full-scale broadband signal at a safe amplifier level;
- representative music with high crest factor;
- repeated bypass/Apply comparisons.

Confirm that:

- the automatic whole-program reserve is actually present;
- the FIR does not introduce digital clipping/over-range events;
- headroom does not depend on the selected Content Preset;
- bypass/removal restores the expected gain relationship.

**PASS:** no digital clipping is observed and measured level change agrees with
the deployment's automatic headroom reserve.

## P5 — Fresh post-Apply acoustic verification

Run the PR107 guided fresh verification campaign after provisional Apply.

Requirements:

- use the same calibrated microphone/input identity as baseline;
- use the planned measurement geometry/positions;
- do not reuse pre-Apply captures;
- rebuild the live route from the provisional FIR Playback System;
- complete all required sweeps.

Record:

- measured filter-tracking RMS error;
- speaker-persistent improvement;
- worst listening-position regression;
- protected-region regression;
- final accepted/rejected result.

**PASS:** the PR107 verifier accepts the fresh campaign and finalization persists
a receipt-bound FIR verification record.

If verification rejects, confirm guarded rollback restores the immutable
pre-Apply state.

## P6 — Restart and persistence fault checks

With a provisionally or fully verified FIR deployment:

1. quit/relaunch the app;
2. stop/start DSP several times;
3. change away from and back to the Playback System;
4. disconnect/reconnect the output device where safe;
5. test a wrong sample-rate or stale route condition.

**PASS:** valid state restores correctly; stale/wrong hardware identity fails
closed; no enabled FIR is silently omitted.

## P7 — Synchronized-video / A-V acceptance

PR107 does not delay macOS/system video itself.

For every cinema/TV workflow that will claim FIR support, identify the real
external compensation mechanism (player, AVR, display, or other verified path)
and its usable video-delay range.

Measure or independently verify:

- PR107-reported total program-path audio latency;
- configured external video delay;
- actual lip-sync result.

If no external video-delay path exists, mark synchronized-video FIR use
**BLOCKED**. Audio-only FIR may still pass.

**PASS:** the external path demonstrably supplies at least the required delay and
lip sync is acceptable/repeatable.

## P8 — Subjective transition / production behavior

After objective gates pass, listen to representative music and, where P7 is
supported, video content.

Check:

- startup/stop behavior;
- FIR Apply and rollback transitions;
- no clicks, bursts, channel swaps, or unexpected gain jumps;
- no obvious tonal discontinuity beyond the intended correction;
- acceptable perceived delay for the intended use case.

This is a production-quality gate, not a substitute for P3-P5 measurements.

## STOP / FAIL conditions

Stop the run and record FAIL if any of the following occurs:

- audible burst, sustained instability, or unexpected full-scale output;
- FIR-enabled state starts playback without the FIR actually active;
- digital clipping despite the required automatic headroom reserve;
- corrected and uncorrected program channels lose relative timing;
- route/sample-rate mismatch is silently accepted;
- fresh verification uses stale/pre-Apply evidence;
- rejected verification cannot restore the exact rollback snapshot; or
- synchronized-video use is presented as supported without a real delay path.

## Acceptance threshold

### Remote software acceptance

Already satisfied when the exact PR107 head has:

- portable validator PASS;
- Ubuntu sparse FIR runtime PASS;
- Ubuntu live FIR render/coherence PASS;
- Apple clang equivalents PASS;
- arm64 app build PASS;
- targeted PR107 XCTest groups PASS; and
- full retained XCTest regression PASS.

### Physical acceptance

At minimum, P0-P6 and P8 must be assessed. P7 may be **BLOCKED/N/A** only if the
supported product claim is audio-only FIR. If PR107 is to claim cinema/TV FIR
support, P7 must PASS on a representative real video path.

PR107 should remain draft until the acceptance record is attached or the owner
explicitly chooses to merge with physical acceptance deferred.

## Commissioning record

Copy this block into the final acceptance note:

```
PR107 commit:
Mac / macOS:
Output device / DAC:
Sample rate:
Program layout:
FIR tap count:
Corrected roles:
Required headroom:
Reported FIR latency:
Reported total program-path latency:
Mic / input / calibration:
Audio-only result:
Realtime/XRun result:
Impulse/coherence result:
Headroom/clipping result:
Fresh verification result:
Restart/persistence result:
A/V result:
Subjective transition result:
Overall: PASS / FAIL / PARTIAL
Notes:
```
