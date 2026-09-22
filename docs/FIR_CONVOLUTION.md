# FIR / Convolution Foundation

PR #17 establishes the portable FIR engine that later linear-phase EQ and room-correction processors will use.

## Architecture

The production engine is a uniform partitioned convolution implementation written in portable C. It has no dependency on Core Audio, Swift, Accelerate, AppKit, or another Apple-only API.

Current constants:

- partition size: 256 frames
- FFT size: 512 points
- maximum impulse response: 32,768 taps
- maximum partitions: 128
- independent left/right impulse responses
- two preallocated program slots

FFT twiddle factors, bit-reversal tables, and frequency-domain impulse-response partitions are prepared outside the realtime render call. The render path performs no allocation, locks, trigonometry, logging, disk I/O, or network I/O.

## Graph placement

The stage is represented in `N60DSPGraphSnapshot` by a prepared program slot plus generation. An enabled graph is accepted only when the referenced program is actually prepared in that render kernel.

Current processing order is:

```text
input
  -> input preamp / headroom
  -> parametric EQ
  -> crossover / bass-management preview
  -> FIR convolution
  -> output gain
  -> output meter / transport
```

The final output-gain stage therefore remains authoritative after FIR processing.

## Latency

Uniform partitioning adds one 256-frame engine block of latency. The graph also records an independent `declaredLatencyFrames` value for the filter's intentional group delay.

Examples of engine-only latency:

- 48 kHz: 5.333 ms
- 96 kHz: 2.667 ms
- 192 kHz: 1.333 ms
- 384 kHz: 0.667 ms

For a linear-phase FIR, total reported graph latency is the convolution engine latency plus the filter's declared group delay, plus any latency contributed by future stages.

## Program lifecycle

Program preparation is control-plane work. A prepared program is immutable while used by the realtime path. Two preallocated slots establish the foundation for later prepare-inactive / atomically-publish / retire-old replacement.

PR #17 does not yet expose arbitrary IR import or live IR replacement in the production UI. Those capabilities should be added only with explicit ownership/lifetime rules for program slots.

## Performance direction

The portable implementation is the correctness/reference backend. The 32,768-tap capacity is an architectural ceiling, not a promise that the longest filter is the preferred realtime configuration at every sample rate.

Before shipping very long FIRs at 384 kHz, benchmark callback worst-case time as well as average CPU. If needed, add a platform-neutral backend interface so Apple can use an optimized FFT implementation while Windows/Android use equivalent optimized backends without changing DSP behavior or graph semantics. Non-uniform partitioning remains an available optimization for long room-correction filters.

## Provenance

The production implementation is net-new. The legacy `ConvolutionEngine` was treated only as a feature/provenance candidate: repository search found no corresponding upstream Equaliser symbol, and visible history is owner-authored. Its source body was not used as the implementation reference for this engine.
