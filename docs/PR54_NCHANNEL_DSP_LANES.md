# PR54 — Generalized N-channel DSP lanes

## Purpose

PR54 is Phase 3 of the post-v1 headphone/multichannel train. It introduces the first realtime-capable processing primitive that is genuinely channel-count agnostic.

The new lane engine supports up to the PR52 maximum of 16 semantic channels and provides:

- independent per-channel gain;
- mute;
- polarity inversion;
- per-channel delay;
- up to 16 PEQ/biquad sections per channel;
- semantic channel groups for linked control-plane editing;
- per-channel peak/RMS/over-range meter accumulation; and
- explicit processing-latency declarations plus automatic compensation delay for coherent parallel lanes.

PR54 intentionally **does not insert the new lane engine into the shipping stereo callback yet**. The existing production DSP remains untouched while the N-channel primitive gets deterministic CI and ABI validation.

## Why this is separate from the existing stereo EQ

The shipping `N60RenderKernel` has mature stereo-specific behavior: stereo/Mid-Side EQ domains, linked dynamics, speaker spatial processing, stereo convolution slots, audition alignment, protection and stereo metering.

Trying to convert all of those concerns to 16 channels in one PR would make regression analysis unnecessarily difficult.

PR54 instead creates a narrow primitive that has one responsibility: process a set of independent semantic program lanes safely. Later integration can migrate appropriate DSP stages to this representation while stereo-specific algorithms remain explicitly stereo/group processors where that is the correct behavior.

## Lane snapshot

Each `N60ProgramLaneSnapshot` stores:

- `gainLinear`;
- `muted`;
- `polarityInverted`;
- `userDelayFrames`;
- `upstreamProcessingLatencyFrames`; and
- bounded per-lane `N60BiquadBandSnapshot` sections.

Coefficient design uses the existing independently implemented Notch Sixty biquad design path on the control plane. The realtime lane processor only consumes prepared coefficients.

## Channel groups

`N60ProgramChannelGroup` is a 16-bit semantic-channel mask compiled from channel roles in a validated PR52 layout.

The first helpers support linked gain and mute changes. The representation is intentionally generic rather than hardcoding Fronts/Surrounds/Heights into the DSP core; UI/product layers may define those conventional groups from semantic roles while still permitting custom groups.

## Delay and coherent latency

Two delay concepts remain distinct.

### Intentional user alignment delay

`userDelayFrames` is an intentional per-channel timing adjustment, such as speaker-distance alignment.

### Processing-latency compensation

`upstreamProcessingLatencyFrames` declares latency that a lane has **already incurred immediately upstream** of this stage. A future per-channel FIR/convolution stage can publish its latency here.

`N60ProgramLaneGraphFinalize` computes the maximum declared processing latency and adds compensation delay to faster lanes:

```text
compensation(channel) = maxDeclaredLatency - declaredLatency(channel)

effectiveLaneDelay(channel) = userDelay(channel) + compensation(channel)
```

This establishes the per-channel FIR/processing latency-coherence contract before long per-channel convolvers are introduced.

The finalizer refuses a configuration whose intentional plus compensation delay cannot fit in the fixed realtime delay ring.

## FIR infrastructure versus FIR processing

PR54 does **not** create sixteen new partitioned convolvers or duplicate the current stereo convolution implementation.

It establishes the lane-level latency contract that per-channel FIR will plug into. That separation matters because per-channel long-FIR processing needs its own memory/CPU budgeting and program-swap strategy and should not be smuggled into a per-channel trim/delay PR.

## Realtime behavior

### Allocation

`N60ProgramLaneRuntimeCreate` allocates the runtime and sixteen fixed-capacity delay buffers on the control plane.

`N60ProgramLaneProcessFrame` performs no allocation/free.

### Synchronization

No locks, atomics, tasks or blocking calls exist in the processing primitive. A later render-kernel integration will publish immutable lane snapshots using the production snapshot/transition architecture.

### Latency

- PEQ, gain, mute and polarity: zero algorithmic latency.
- User alignment delay: explicitly configured.
- Coherence compensation: explicitly derived from declared upstream processing latency.

### Sample rate

The graph stores its native sample rate. Millisecond delay design and PEQ coefficient design happen on the control plane. The realtime processor operates on prepared frame counts/coefficients.

### Channel count

1–16 channels are supported by the lane graph as long as the associated PR52 semantic layout is valid.

### Reset

`N60ProgramLaneRuntimePrepare` clears EQ and delay history and binds the runtime to a semantic layout. It is a control-plane operation and must not be called from the realtime callback.

### Runtime layout safety

The realtime primitive refuses a graph whose semantic layout does not match the layout for which the runtime was prepared. It never silently reinterprets retained filter/delay state as another speaker role.

## Metering

`N60ProgramLaneMeterAccumulator` provides bounded per-channel:

- peak;
- RMS; and
- over-range sample counts.

This is a DSP-side metering foundation only. Atomic publication/UI presentation remains an integration concern for the later live N-channel render path.

## Provenance / source of truth

Net-new proprietary implementation based on:

- the owner-approved PR52→PR59 architecture plan;
- PR52 semantic program layouts;
- PR53 semantic routing; and
- the repository's independently implemented `N60Biquad` primitive.

No historical GPL source, tests, type hierarchy or implementation expression was used.

## Validation

Permanent guard: `ci/validate_pr54_nchannel_lanes.py`.

It verifies:

- an 8-channel 7.1 graph processes all lanes independently;
- linked Front L/R group gain;
- per-channel polarity;
- mute;
- exact integer-frame delay behavior;
- declared upstream latency compensation;
- aligned arrival after compensation;
- per-channel PEQ isolation;
- multichannel meter values; and
- delay-ring overflow rejection.

The PR workflow runs the deterministic harness on both Ubuntu/Clang and the Apple toolchain, then builds the macOS app with the lane ABI visible through the Swift bridging header.

## Manual validation required

No new production UI or routing mode is activated by PR54. The later Mac test is therefore still a regression check: existing stereo playback should be bit-for-bit architecturally unaffected because the new lane processor is not invoked by `N60RenderKernelProcessStereoFrame*`.

## App Sandbox / App Store impact

None. No dependency, entitlement, permission, driver, helper, network access or new persistent storage is added.

## Next phase

PR55 / Phase 4 will build multichannel bass-management semantics on top of the PR52 layout, PR53 router and PR54 lane model: per-speaker high-pass policy, native LFE handling, redirected bass, multiple Sub N destinations, and explicit per-sub trim/delay/polarity/EQ/protection. Live transport activation remains gated on having a complete and testable route from semantic input layout through the N-channel graph to physical outputs.
