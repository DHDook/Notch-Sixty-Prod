# PR107 — Speaker Optimizer FIR Deployment & Latency Coordination

Status: **IN PROGRESS — SLICES 1–2 LATENCY + REALTIME SUBSTRATE**

Base: PR106 Advanced Speaker Measurement Lab / GitHub PR #107.

## Purpose

PR104 can already synthesize bounded, classification-aware linear-phase FIR
candidates from qualified Speaker Optimizer measurements. PR105 deliberately
refuses to install those taps because the Playback System has no separately
owned per-speaker FIR stage with explicit latency/headroom ownership.

PR107 closes that gap without reusing Room Correction, Speaker IR, ordinary EQ,
or Speaker Calibration as a hidden deployment path.

The stage must:

- remain separately owned Speaker Optimizer state;
- run per whole-speaker semantic program role;
- use the production partitioned-convolution implementation;
- preserve channel coherence when only some roles receive FIR;
- count convolution-engine latency and FIR group delay exactly once;
- retain intentional Speaker Calibration delays;
- reserve/validate digital headroom before any boosted candidate can run;
- expose added audio latency to A/V policy rather than pretending system video
  has been delayed;
- support exact transactional Apply/rollback identity; and
- remain provisional until fresh microphone verification accepts the deployed
  acoustic result.

Physical subwoofer timing/polarity optimization remains a separate PR108 concern.

## Slice 1 — Exact FIR latency and lane-coherence contract

Implemented in `SpeakerOptimizerFIRDeployment.swift`.

The existing N-channel program-lane engine already has an explicit
`upstreamProcessingLatencyFrames` contract intended for channel-specific
processing such as a future per-channel FIR. `N60ProgramLaneGraphFinalize`
finds the maximum upstream latency and inserts the difference into faster lanes.

PR107 Slice 1 formalizes how Speaker Optimizer FIR uses that mechanism.

For an odd linear-phase FIR:

```
declared group delay = (tapCount - 1) / 2
added FIR latency    = convolution engine latency + declared group delay
```

The current production partitioned convolver has a fixed 256-frame engine
latency. Therefore the default PR104 2049-tap candidate at 48 kHz is:

- group delay: 1024 frames / 21.33 ms;
- convolution engine: 256 frames / 5.33 ms;
- total added audio latency: 1280 frames / 26.67 ms.

That 1280-frame upstream value is attached to roles that actually execute the
FIR. Roles without FIR receive 1280 frames of coherence compensation in the
existing program-lane delay stage. Existing user Speaker Calibration delay is
retained on top of that relationship rather than normalized away.

The planner fails closed when:

- the Output Device Profile is invalid/disabled;
- sample rate or tap count is invalid;
- declared group delay does not exactly match the odd linear-phase tap count;
- no whole-speaker role is selected;
- a role is duplicated, not mapped, or is semantic LFE;
- upstream FIR latency exceeds the lane delay budget; or
- coherence compensation plus an existing calibration delay would overflow the
  realtime delay buffer.

### A/V boundary

Slice 1 explicitly reports `requiresAVSyncCoordination == true` whenever the
FIR adds latency. Notch Sixty processes audio; this contract does **not** claim
that macOS/system video is correspondingly delayed.

The later PR107 A/V policy slice must decide how FIR is presented for cinema/TV
use (for example, bounded low-latency candidates, explicit user warning, or a
known external player/device compensation path). No unsupported video-delay
claim is allowed.

### Slice 1 safety state

- `canInstallLiveFIR == false`;
- no Playback System persistence is changed;
- no FIR taps are attached to the live N-channel graph;
- no headroom is mutated;
- no Speaker Calibration, Room Correction or Speaker IR state is reused; and
- PR105's existing FIR commissioning block remains in force.

## Slice 2 — Sparse per-program-channel FIR realtime substrate

Implemented in `N60ProgramFIRRuntime.h`.

Speaker Optimizer FIR is a diagonal correction problem: each selected semantic
speaker receives its own FIR, and no corrected speaker should receive filtered
content from a different program channel. Reusing the PR74 MIMO runtime would
therefore introduce unnecessary cross-coupling machinery and retain a four-
channel ceiling that does not match the N-channel Playback System.

Slice 2 introduces a dedicated sparse diagonal runtime:

- supports the full existing `N60_MAX_PROGRAM_CHANNELS` semantic layout;
- accepts an explicit active-channel bit mask;
- stores taps in ascending active-channel order;
- allocates transformed kernels and history only for active corrected channels;
- shares one FFT/twiddle table and one scratch/accumulator across channels;
- uses the same 256-frame partition size and 32768-tap ceiling as the production
  partitioned-convolution foundation;
- reports exact engine and declared latency separately;
- passes inactive program channels through unchanged in the standalone stage;
- sanitizes non-finite input to zero; and
- processes realtime frames without allocation/free, locks, logging,
  trigonometry, file/network I/O or filter construction.

Inactive channels are intentionally *not* delayed inside the FIR runtime.
Slice 3 will place this runtime immediately upstream of
`N60ProgramLaneEngine`, set `upstreamProcessingLatencyFrames` on FIR-active
lanes, and let the existing lane finalizer insert exact coherence compensation
on faster inactive lanes. This keeps latency ownership in one place and avoids
double delay.

The standalone C harness verifies sparse routing, independent kernels, exact
256-frame engine latency, inactive passthrough, reset behavior, non-finite
sanitization, invalid-program rejection, and that a 32-channel layout with one
corrected speaker consumes kernel/history proportional to **one** active
channel rather than 32.

### Slice 2 safety state

- no FIR stage is yet attached to `N60LiveNChannelRenderCore`;
- no bridge/session creates or owns a live optimizer FIR program;
- no Output Device Profile persists active optimizer FIR taps;
- PR105 commissioning still reports the dedicated FIR stage unavailable; and
- `canInstallLiveFIR == false` remains unchanged.

## Planned follow-on slices

1. **Live graph compiler integration** — bind role-specific prepared programs to
   the N-channel render graph and feed exact upstream latency into the existing
   lane-coherence finalizer.
2. **Persistent Speaker Optimizer FIR ownership** — versioned Output Device
   Profile configuration that cannot be silently ignored by live compilation.
3. **Headroom + transactional Apply/rollback** — validate candidate identity,
   reserve required digital headroom, mutate only while engine-idle, and verify
   exact post-write state.
4. **A/V latency policy** — expose total latency and fail closed for modes whose
   synchronization policy cannot tolerate/compensate it.
5. **Fresh measured FIR verification** — receipt-bound microphone campaign,
   acoustic filter tracking, speaker-persistent improvement and guarded rollback.
6. **Guided production UI** — FIR proposal review, latency/headroom disclosure,
   explicit approval, provisional state, verification and rollback.
7. **Remote software closure + physical handoff**.

## Slice 1 tests

`SpeakerOptimizerFIRDeploymentTests` verifies:

- exact 2049-tap / 48 kHz latency accounting;
- engine latency is not omitted or double counted;
- unfiltered lanes get exact coherence compensation;
- existing calibration delay remains intentional;
- group-delay identity is exact;
- invalid/even taps, duplicate roles and LFE targets fail closed; and
- FIR compensation cannot overflow the existing realtime lane delay buffer.

Physical A/V sync, real convolution CPU cost, subjective benefit and acoustic
verification remain outside Slice 1.


## Slice 2 portable validation

`ci/validate_pr107_program_fir_runtime.c` is compiled and executed on both
Ubuntu clang and Apple clang. The PR107 workflow continues to preserve the
entire PR106 contract, build the Apple Silicon app, run targeted Swift tests and
run the complete retained XCTest regression.
