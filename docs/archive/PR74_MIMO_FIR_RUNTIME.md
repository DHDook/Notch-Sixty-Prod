# PR74 — MIMO Room-Treatment FIR Compiler and Standalone Runtime

## Purpose

PR74 converts a software-accepted PR73 low-frequency MIMO room-treatment plan into an immutable causal FIR matrix and proves that matrix in a standalone realtime-safe runtime.

PR74 is **not live activation**. It does not insert room treatment into the production speaker graph and exposes no user-facing apply/deploy path.

The sequence is now:

```text
PR58/64 complex source × seat measurements
    -> PR73 bounded robust MIMO frequency-domain plan
    -> PR74 causal finite matrix FIR program
    -> PR74 standalone realtime-safe matrix runtime
    -> future hardware-gated live graph integration
```

## Initial runtime scope

The first runtime is deliberately bounded to **four treatment actuators**.

This matches the existing four-physical-subwoofer ceiling and gives a realistic initial low-frequency active-room-treatment topology without pretending that a scalar reference implementation is ready to process an arbitrary 32 × 32 FIR matrix.

PR73 may still simulate larger source sets. PR74 refuses to compile more than four sources into this realtime program.

A future SIMD/Accelerate-optimized runtime can expand the actuator ceiling after profiling on real Apple Silicon hardware.

## FIR compiler

`MIMORoomTreatmentFIRCompiler` consumes `MIMORoomTreatmentPlan`.

Production defaults:

- 4096 FIR taps per matrix path;
- power-of-two tap count required;
- 20–150 Hz treatment plan inherited from PR73;
- 15 Hz smooth treatment-strength taper toward identity at both band edges;
- Hermitian spectrum construction for a real time-domain impulse;
- half-FIR circular delay to provide a causal finite window;
- short edge taper to reduce circular-window truncation artifacts.

The compiler produces `MIMORoomTreatmentFIRProgram` with taps flattened as:

`[output physical source][input target lane][tap]`.

## Causality and latency

An arbitrary complex MIMO correction can contain both positive- and negative-time energy when represented around zero time.

PR74 does not silently discard the negative-time portion. It circularly shifts the complete finite impulse by half of the FIR length.

At the default 4096 taps:

- declared FIR causal delay: 2048 frames;
- partitioned-convolution engine latency: 256 frames;
- total treatment latency: 2304 frames.

At 48 kHz this is 48 ms.

This latency is not active in the shipping graph in PR74. A future live integration must publish it to the existing transport/latency system and verify A/V behavior before activation.

## Dense post-compile safety verification

PR73 already bounds its frequency-domain design points, but FIR interpolation, finite-window realization and tapering can alter the realized response.

PR74 therefore performs a second safety pass over the **actual compiled FIR response**.

It measures on the dense DFT grid:

- maximum individual matrix coefficient magnitude;
- maximum per-target column power;
- maximum per-physical-source row/effort power;
- maximum time-domain energy fraction near the causal window edges.

Compilation fails closed if realized overshoot exceeds the configured allowance.

Default numerical overshoot allowance is 0.35 dB for coefficient, column-power and source-power checks. This is a numerical realization tolerance, not extra acoustic boost authority.

The underlying PR73 plan remains unity-bounded.

## Edge-energy / truncation guard

The compiler measures how much energy remains near the beginning/end of each causal FIR path after shifting and tapering.

Excessive edge energy indicates that the chosen finite window is a poor representation of the requested complex correction.

The default maximum is 12% for the worst matrix path. A violation rejects compilation rather than silently truncating a potentially non-causal or poorly represented filter.

This metric should be tightened after real-room datasets establish realistic distributions.

## Standalone matrix runtime

`N60MIMOFIRRuntime.h` implements a fixed bounded partitioned-convolution reference runtime.

Limits:

- up to 4 input target lanes;
- up to 4 output treatment actuators;
- 4096 taps per input/output path;
- 256-frame partitions;
- 512-point FFT;
- maximum 16 partitions.

The immutable program stores pre-transformed FIR partitions.

The runtime stores only:

- current input blocks;
- overlap/output blocks;
- input-spectrum partition history;
- precomputed bit-reversal/twiddle tables;
- fixed FFT scratch/accumulator buffers.

The audio processing function performs no:

- allocation/free;
- locks;
- logging;
- trigonometry;
- file/network I/O;
- device discovery;
- filter design.

Non-finite input samples are sanitized to zero.

## Why a separate runtime instead of reusing N60Convolution

The existing production `N60PartitionedConvolver` is a stereo diagonal convolver: Left is filtered by a Left kernel and Right by a Right kernel.

MIMO room treatment needs full cross-coupling:

`y_s = Σ_t C[s,t] * x_t`

where every output actuator may receive filtered contributions from every input target lane.

PR74 therefore introduces a separate matrix runtime rather than overloading the proven stereo convolver with incompatible semantics.

## Memory model

With four channels and the maximum 4096 taps:

- 16 matrix paths;
- 16 FIR partitions per path;
- 512 complex bins per partition.

Kernel and runtime-history storage are allocated on the control plane.

Large matrices are never copied through realtime stack frames.

## Validation

Portable C validation covers:

- exact 2 × 2 matrix impulse routing;
- cross-channel FIR contribution timing;
- 256-frame engine latency;
- runtime reset;
- non-finite input sanitization;
- invalid-program rejection;
- maximum 4 × 4 / 4096-tap finite processing;
- a generous worst-case CPU regression ceiling.

Swift/XCTest validation covers:

- exact identity PR73 plan -> centered diagonal FIR impulse;
- compiler-declared and engine latency;
- bounded cross-coupled plan -> FIR -> standalone C runtime;
- dense realized-response safety metrics;
- >4 actuator rejection;
- unsafe realized matrix rejection;
- invalid tap-count rejection.

CI retains PR73 MIMO design validation, builds the arm64 app, runs dedicated PR74 tests and the complete retained XCTest suite.

## Explicit non-goals

PR74 does not:

- add room treatment to `N60LiveNChannelRenderCore`;
- alter bass management;
- activate treatment on speakers or subs;
- publish treatment latency to live transport;
- crossfade treatment programs;
- persist an enabled treatment program;
- expose a UI Apply button;
- claim physical excursion/thermal safety;
- implement continuous adaptive ANC or FxLMS.

## Next hardware-gated step

A future live-integration PR should only proceed after the following are available:

1. real Mac and multichannel/subwoofer hardware;
2. measured PR73 plans from an actual room;
3. physical source selection policy;
4. driver/subwoofer excursion and thermal constraints;
5. final limiter/protection placement;
6. re-measurement verification protocol;
7. latency/A-V acceptance.

That PR should integrate a prepared immutable program behind an explicit arm/fade/bypass state machine and must fail to identity/silence safely on any confidence or runtime fault.

## Provenance

PR74 is clean-room proprietary work using the existing proprietary Notch Sixty DSP architecture and standard FFT partitioned-convolution techniques. It adds no third-party DSP library, private API, driver, helper process, entitlement or network dependency.
