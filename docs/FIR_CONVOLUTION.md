# FIR / Convolution Foundation

PR #17 establishes the portable FIR engine that later linear-phase EQ and room-correction processors will use.

## Architecture

The stereo engine (`N60Convolution.c`) is a **non-uniformly partitioned** convolver in C using Accelerate/vDSP real FFTs. (Earlier revisions were a uniform, portable-C engine capped at 32,768 taps; the product targets macOS on Apple silicon, so the FFT now uses vDSP directly. A platform backend interface can be reintroduced if another platform is ever targeted.)

The impulse response is split into three segments of increasing block size:

| Segment | Block | Taps | Partitions |
|---|---|---|---|
| 0 | 256 | 0 – 1,024 | 4 |
| 1 | 1,024 | 1,024 – 5,120 | 4 |
| 2 | 4,096 | 5,120 – 262,144 | up to 63 |

Each segment with block B starts at a tap offset of at least B − 256, so its output is ready before it must be emitted: the engine latency stays one 256-frame base block regardless of filter length. Older-partition multiply-accumulates of the larger segments are spread evenly across their block period, so a boundary tick only adds one FFT, one partition multiply and one inverse FFT per segment.

Current constants:

- base block / engine latency: 256 frames
- maximum impulse response: 262,144 taps (0.68 s at 384 kHz; the same time span as 32,768 taps at 48 kHz)
- maximum partitions: 71 (`N60ConvolutionPartitionCountForTapCount`)
- independent left/right impulse responses (right may share the left kernel)
- three preallocated program slots

All buffers and the vDSP FFT setup are allocated at create; prepare and reset are control-plane only, and reset clears only the state the prepared program can read. The render path performs no allocation, locks, trigonometry, logging, disk I/O, or network I/O.

Measured on Apple silicon (stereo, per convolver, `-O2`): 32,768 taps 44 ns/sample (old uniform engine: 176 ns); 262,144 taps 80 ns/sample, about 3 % of one core at 384 kHz, with a worst single tick of ~57 µs against a 667 µs tick period at 384 kHz.

The multichannel semantic program FIR (`N60ProgramFIRRuntime.h`) is a separate uniformly partitioned runtime with its own `N60_PROGRAM_FIR_MAX_TAPS` (32,768) budget.

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

The engine adds one 256-frame base block of latency, independent of filter length. The graph also records an independent `declaredLatencyFrames` value for the filter's intentional group delay.

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

Long filters are now cheap enough for 384 kHz room correction; the remaining hardware check is worst-case callback time with all three FIR stages (EQ FIR, room correction, Speaker IR) at full length on the slowest supported Mac, alongside the rest of the graph.

## Provenance

The production implementation is net-new. The legacy `ConvolutionEngine` was treated only as a feature/provenance candidate: repository search found no corresponding upstream Equaliser symbol, and visible history is owner-authored. Its source body was not used as the implementation reference for this engine.
