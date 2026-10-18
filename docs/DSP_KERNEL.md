# Realtime DSP Kernel

This describes the stereo render kernel as it is on `main` (`NotchSixty/Audio/Realtime/N60RenderKernel.c`)
and the N-channel render core beside it. `docs/ARCHITECTURE.md` explains where the kernel sits in the
transport. Epics E6, E20 and E21 replace this kernel (see "Where it goes next").

## Shape

- **Stereo, per frame.** `N60RenderKernelProcessStereoFrame` runs once per sample frame. Only the
  convolvers work in blocks internally (partitioned FFT). There is no explicit SIMD yet.
- **Two halves.** The *playback* half processes program audio. The *system* half applies speaker,
  room, output and protection processing. The Audio Unit rack sits between them, outside the kernel:
  the host passes the rack's output in as `rackLeft`/`rackRight`.
- **Format.** 32-bit float at the render boundary, at the device's native nominal rate. There is no
  transport SRC (see `ARCHITECTURE.md` for the adaptive clock bridge, which corrects drift only).

## Stage order

Playback half (`N60RenderKernelProcessStereoPlaybackFrameInContext`):

1. Sanitize the input (NaN/Inf and subnormals to zero, counted).
2. Reference delay for A/B audition.
3. Input meter.
4. Input gain × headroom gain.
5. Pre-EQ dynamics (`N60DynamicsProcessPreEQStereoFrame`).
6. Spectral denoiser (`N60SpectralDenoiser`).
7. Mid/side encode (when enabled).
8. Parametric EQ biquad bands, with band transitions.
9. Program convolution (`N60PartitionedConvolverProcessSample`).
10. Mid/side decode.
11. Dynamic EQ (`N60DynamicsProcessDynamicEQStereoFrame`).
12. Post-EQ meter.

*Audio Unit rack (outside the kernel).*

System half (`N60RenderKernelProcessStereoSystemFrameInContext`):

1. Crossover and bass management, including the subwoofer path.
2. Room-correction convolver.
3. Speaker impulse-response convolver.
4. Ambient compensation (three biquad bands, then ambient level gain).
5. Core dynamics with master gain (`N60DynamicsProcessCoreStereoFrameWithMasterGain`).
6. Symmetry balance, speaker crossfeed, crosstalk cancellation.
7. Balance and output gain.
8. Headphone DSP (when the headphone path is active).
9. Pause gate.
10. Active Quiet Zone signal added (`N60ActiveQuietZone`; only when its authorisation path allows it,
    see `ARCHITECTURE.md`).
11. Protection: limiter and true-peak guard (`N60ProtectionProcessStereoFrame`).
12. Audition output select (reference, delta or processed).
13. Inter-channel delay (skipped when bypassed).
14. Master gain.
15. ANC reference capture.
16. Final sanitize and output meter.

Fractional delay (`N60FractionalDelay.h`) and dither are not in the stereo kernel. Feed-forward ANC
timing, preview FIR and reference transport live in the `N60FeedForward*` bridges.

## Smoothing and bypass

- Gains and EQ ramp linearly (`N60SmoothedGain`) over 5 ms, clamped to 32–4096 frames. Crossover
  changes ramp over 8 ms, clamped to 64–8192 frames. Frame counts scale with the sample rate.
- Smoothed values: input, headroom, output, master, balance, symmetry, crossfeed, crosstalk amount and
  head-shadow, and ambient level. Dynamic EQ uses its own 5 ms transition.
- A disabled EQ or ambient band keeps running until its fade-out finishes, then its state is cleared
  and it is skipped. There is no separate "parked" state. Graph bypass is a snapshot flag;
  sanitizing still applies when bypassed.

## Sample rates

- Any finite positive device rate is accepted. Every filter frequency must sit below Nyquist.
- Coefficients are computed off the realtime thread when a snapshot is prepared for its rate.
- Explicit upper limits are 384 kHz: protection (`N60_PROTECTION_MAX_SAMPLE_RATE`), the spectral
  denoiser (8–384 kHz) and dynamic EQ.
- Protection oversamples 1×, 2× or 4× (4× when the limiter and true-peak guard are both on), adding
  32 frames at 2× and 48 frames at 4×.
- The audition delay holds up to 131,072 frames.

Every stage must work at the eight standard rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8 and
384 kHz). DSP changes need deterministic XCTests and an acoustic reference-lab case at those rates.

## FIR and convolution

| Runtime | Max taps | Notes |
|---|---|---|
| `N60Convolution` (program, room, speaker) | 262,144 | Non-uniform partitions, first partition 256 frames (FFT 512), three segments, 3 program slots |
| `N60ProgramFIRRuntime` (N-channel) | 32,768 | |
| `N60MIMOFIRRuntime` | 4,096 | 256-frame partitions |
| `N60BinauralRenderer` | 8,192 | |

Convolver latency is the declared filter latency plus the partition latency. FFTs use Apple vDSP
(`vDSP_create_fftsetup`). No CPU budget is enforced in code yet; E20 adds one.

## Graph publication

- The kernel keeps two preallocated snapshot slots (`N60_SNAPSHOT_SLOT_COUNT`). The control plane
  fills the inactive slot and publishes it with a C11 atomic swap. It may wait for an old reader to
  release a slot; the realtime side never waits.
- `N60RenderKernelBeginRender` acquires one snapshot per hardware buffer and `EndRender` releases it,
  so a buffer never mixes two graph generations. If acquisition keeps failing under publication churn,
  the buffer passes sanitized audio through and `snapshotReadMisses` counts it.
- Graph latency is reported from the snapshot, one authoritative value for UI and A/V sync.
  Device and transport buffering are not DSP latency.

## Realtime guarantees

The render functions do no heap allocation, take no locks, do no I/O, logging, UI, async or device
work, and never build or destroy filters (see `docs/REALTIME_RULES.md`). State lives in fixed arrays
and preallocated buffers. Telemetry, meters and reader counts are C11 atomics.

Diagnostics exposed: frames rendered, non-finite samples sanitized, denormals flushed, snapshot-read
misses, graph generation, latency, sample rate, channel count and bypass state. In normal operation
the sanitize and miss counters stay at zero.

`N60RenderKernelReset` clears counters only. Stateful stages reset when their snapshot is rebuilt.

## N-channel render core

`N60LiveNChannelRenderCore.h` processes program layouts of up to 32 channels
(`N60ProgramLayout.h`) to up to 40 physical channels. Per frame: optional program FIR, then the lane
engine (`N60ProgramLaneEngine.h`, per-lane EQ and delay compensation to a common latency), then
optional multichannel bass management, then the output map. It is a separate path from the stereo
kernel; `ARCHITECTURE.md` explains how one is chosen.

## Where it goes next

- **E6** replaces the stereo kernel and the N-channel core with one N-channel graph.
- **E20** moves to whole-buffer processing, multirate low-frequency paths, multiple realtime threads
  (Audio Workgroups), portable SIMD and an enforced CPU budget.
- **E21** moves the core to C++20/23 behind one versioned C interface. The core may not depend on an
  Apple framework, so `N60Convolution.c`'s direct `Accelerate` include moves behind the FFT
  abstraction (vDSP on Apple, a BSD-licensed FFT elsewhere).
