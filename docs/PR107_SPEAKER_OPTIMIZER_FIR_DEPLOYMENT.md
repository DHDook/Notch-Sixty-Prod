# PR107 — Speaker Optimizer FIR Deployment & Latency Coordination

Status: **REMOTE SOFTWARE COMPLETE — PHYSICAL ACCEPTANCE PENDING**

Base: PR106 Advanced Speaker Measurement Lab / GitHub PR #107.
Implementation PR: GitHub #108.

## Purpose

PR104 already synthesized bounded, classification-aware linear-phase FIR
candidates from qualified Speaker Optimizer measurements. PR105 intentionally
blocked FIR Apply because the Playback System did not yet own a dedicated
per-speaker FIR stage with explicit latency, headroom, persistence, rollback
and verification semantics.

PR107 closes that software gap without reusing Room Correction, Speaker IR,
ordinary EQ or Speaker Calibration as hidden ownership.

The resulting FIR path is:

```
qualified PR103/104 measurement evidence
    -> classification-aware FIR preview
    -> representability + commissioning review
    -> exact latency / A-V disclosure
    -> explicit user approval
    -> atomic engine-idle Apply
    -> persisted Speaker Optimizer FIR ownership
    -> automatic whole-program headroom reserve
    -> sparse per-program-channel realtime convolution
    -> existing semantic lane coherence compensation
    -> fresh post-Apply microphone campaign
    -> measured accept OR guarded rollback
```

Physical subwoofer timing/polarity optimization remains a separate PR108
concern.

## Slice 1 — Exact FIR latency and lane-coherence contract

`SpeakerOptimizerFIRDeployment.swift` establishes the latency contract.

For an odd linear-phase FIR:

```
declared group delay = (tapCount - 1) / 2
added FIR latency    = convolution engine latency + declared group delay
```

The production partitioned convolver uses 256-frame partitions. Therefore the
default PR104 2049-tap candidate at 48 kHz contributes:

- linear-phase group delay: 1024 frames / 21.33 ms;
- convolution-engine latency: 256 frames / 5.33 ms;
- incremental FIR latency: 1280 frames / 26.67 ms.

The existing N-channel `N60ProgramLaneEngine` already owns an
`upstreamProcessingLatencyFrames` contract. FIR-active lanes declare their
physical upstream latency; faster lanes receive exactly the required coherence
compensation during lane finalization. Intentional user Speaker Calibration
delay remains on top of that relationship.

Planning fails closed on invalid sample rate/tap count/group delay, invalid or
duplicate roles, semantic LFE, invalid profiles and delay-buffer overflow.

A validated latency plan now reports `canInstallLiveFIR == true`; live
installation still requires all later commissioning, persistence, headroom,
approval and state-identity gates.

## Slice 2 — Sparse per-program-channel FIR realtime substrate

`N60ProgramFIRRuntime.h` implements a sparse diagonal FIR runtime for the full
semantic program-channel ceiling.

Key properties:

- supports `N60_MAX_PROGRAM_CHANNELS`;
- accepts an explicit active-channel bit mask;
- allocates transformed kernels/history only for corrected channels;
- keeps inactive channels as passthrough inside the FIR stage;
- uses the production 256-frame partition size and convolution tap ceiling;
- stores immutable prepared kernels on the control plane;
- performs no allocation/free, locking, logging, trigonometry, filter design,
  file/network I/O or device discovery in realtime processing; and
- sanitizes non-finite input to zero.

The portable C harness verifies sparse routing, independent kernels, exact
engine latency, reset, non-finite sanitization, invalid-program rejection and
memory scaling by active channels rather than full layout width.

## Slice 3 — Live semantic graph integration

`N60LiveNChannelRenderCore.h` and `N60LiveNChannelBridge.h` integrate the
sparse FIR immediately before the existing semantic program-lane stage:

```
semantic input
    -> optional Speaker Optimizer FIR
    -> speaker lane trim / delay / polarity / EQ
    -> optional bass management
    -> physical outputs
```

The render graph binds exact FIR metadata to active semantic lanes and reuses
the lane finalizer for coherence compensation. Semantic LFE cannot receive this
speaker FIR.

The N-channel latency reporter was corrected to count:

```
physical upstream FIR latency + effective program-lane delay
```

so an all-FIR layout cannot under-report latency merely because lane
compensation itself is zero.

The live C harness proves a filtered and unfiltered speaker emerge
sample-aligned after compensation.

## Slice 4 — Persistent ownership and automatic headroom

`OutputDeviceProfileConfiguration` now has optional
`speakerOptimizerFIR` state. Legacy persisted profiles decode with the field
absent.

`SpeakerOptimizerFIRDeploymentConfiguration` owns:

- proposal/baseline/characterization identity;
- routing signature and sample rate;
- aggregate candidate fingerprint;
- exact odd tap count and group delay;
- per-role candidate fingerprint and Float taps;
- modeled maximum positive gain;
- per-role recommended headroom;
- required whole-program headroom reserve; and
- optional fresh measured verification record.

Validation rejects non-finite/asymmetric/empty taps, wrong roles, stale routing,
wrong sample rate, inconsistent headroom, wrong group delay and unsupported
latency.

Speaker Optimizer PEQ and FIR are mutually exclusive deployment stages. A
profile containing both fails validation rather than stacking two optimizer
corrections accidentally.

The N-channel graph compiler automatically subtracts the persisted FIR's
required headroom from whole-program gain. This does not depend on a Content
Preset having enough manual attenuation.

The Core Audio N-channel session binds the persisted FIR to the live bridge
before callbacks start. Any preparation failure destroys the bridge and fails
activation closed; an enabled persisted FIR can never be silently ignored.

## Slice 5 — Commissioning and atomic Apply / rollback

`SpeakerOptimizerCommissioningPlanner` now marks a FIR source
`availableDedicatedSpeakerOptimizerFIRStage` only when the exact candidate is
representable by the dedicated live stage.

Representability proves:

- whole-speaker semantic role, never LFE/subwoofer;
- accepted preview with nonempty taps;
- exact persistent route/sample-rate identity;
- supported odd tap count and group delay;
- finite symmetric taps;
- valid headroom metadata; and
- latency/coherence fit inside the realtime delay budget.

`SpeakerOptimizerFIRApplyTransaction` requires:

- engine-idle state;
- exact selected Playback System identity;
- exact immutable commissioning snapshot;
- exact user-approved aggregate candidate fingerprint; and
- exact post-write Playback System state.

Apply mutates only separately owned `speakerOptimizerFIR` state. Ordinary
Speaker Calibration, Room Correction, Speaker IR and Content Preset headroom
are not repurposed.

Rollback restores the immutable pre-Apply Output Device Profile and refuses to
overwrite unrelated later edits. After measured verification, rollback remains
allowed only when the verification record is the sole post-Apply state change.

## Slice 6 — Explicit A/V synchronization policy

`SpeakerOptimizerFIRAVSyncPolicy` makes the video boundary explicit.

Notch Sixty processes audio and does **not** claim to delay macOS/system video.

- Audio-only playback may use a valid FIR after normal commissioning.
- Synchronized-video playback is blocked when no verified external video-delay
  path is declared.
- A declared player/AVR/display compensation path must have at least the exact
  reported program-path delay capacity.
- The decision reports both incremental FIR latency and total program-path
  latency, including intentional speaker-calibration delay.

For the default 2049-tap FIR at 48 kHz with no additional speaker delay, the
minimum external video delay needed for program-path alignment is 26.67 ms.

This policy is a capability/acceptance contract; PR107 does not claim that an
arbitrary player, AVR or display actually implements or applies the requested
video delay correctly.

## Slice 7 — Fresh measured FIR verification

`SpeakerOptimizerFIRPostApplyVerifier` independently verifies the deployed
FIR using fresh microphone evidence.

It does not trust the preview's modeled response cache. Expected filter tracking
is recomputed from the **exact persisted Float FIR taps** at the classified
measurement frequencies.

Measured acceptance retains the PR105 PEQ standards:

- verification captures must be new and later than Apply;
- baseline and verification must preserve Playback System, route, microphone,
  sample rate, positions and planned-source identity;
- both campaigns must remain optimizer-ready evidence;
- observed acoustic delta must track the deployed filter;
- speaker-persistent spectral error must improve;
- no listening position may regress beyond the configured limit; and
- protected room/seat-dependent regions may not regress beyond their limit.

An accepted report can be finalized into
`SpeakerOptimizerFIRVerificationRecord`, bound to the exact Apply receipt.
A rejected report recommends rollback.

## Slice 8 — Guided FIR review and verification workflow

`SpeakerOptimizerGuidedFIRController` exposes the complete user-facing state
machine:

```
idle
  -> reviewReady
  -> appliedPendingVerification
  -> measuredAccepted
       or
     measuredRejected -> rolledBack
```

Review exposes:

- candidate tap count;
- required automatic headroom;
- incremental FIR latency;
- total program-path latency; and
- A/V synchronization decision.

Explicit user approval remains mandatory. A synchronized-video context cannot
Apply until its declared external video-delay capacity satisfies the A/V
policy.

`SpeakerOptimizerFIRVerificationController` is a separate fresh-capture
controller rather than a generalization of the mature PEQ controller. It:

- requires the exact provisional FIR Playback System state;
- requires the same calibrated microphone/input identity as baseline;
- creates or resumes a receipt-bound verification archive;
- generates the normal protected measurement sweep;
- rebuilds the live route from the provisional Output Device Profile so the
  sweep traverses the exact FIR under test;
- records compact fresh measurement evidence; and
- invokes the FIR verifier only after the campaign is complete and
  optimizer-ready.

The verification campaign factory rejects reused pre-Apply captures.

## Validation

PR107 CI preserves the full PR106 closure and adds:

- portable structural-contract validation;
- Ubuntu clang sparse FIR runtime harness;
- Ubuntu clang live FIR render/coherence harness;
- Apple clang versions of both C harnesses;
- Apple Silicon Debug app build;
- targeted FIR latency/persistence tests;
- commissioning/representability tests;
- atomic Apply/rollback tests;
- A/V synchronization policy tests;
- fresh measured FIR verification tests;
- guided FIR workflow tests; and
- the complete retained XCTest regression suite.

## Physical / hardware handoff

The remaining work is physical validation, not another hidden software
deployment path.

On real Apple Silicon hardware with the user's actual output chain, verify:

1. realtime CPU margin and absence of XRuns with representative tap counts and
   multichannel layouts;
2. measured impulse timing against the reported FIR + coherence latency;
3. automatic headroom reserve and no clipping on boosted candidates;
4. real-room acoustic improvement with fresh Speaker Optimizer verification
   sweeps;
5. rollback/restart behavior with the physical output device;
6. A/V behavior in any player/AVR/display combination used for cinema/TV,
   including independent confirmation that the external video-delay mechanism
   applies the required delay; and
7. subjective transition/startup behavior before declaring production-ready
   hardware acceptance.

PR107's exact software head is CI-green. The executable physical commissioning
checklist is recorded in `docs/PR107_PHYSICAL_FIR_ACCEPTANCE.md`.

PR107 should remain a draft until the roadmap's chosen hardware acceptance
checkpoint is recorded or the owner explicitly chooses to merge with physical
acceptance deferred. PR108 remains responsible
for dedicated physical subwoofer timing/polarity optimization.
