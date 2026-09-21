# Realtime Rules

The audio render path is a hard realtime boundary.

## Forbidden in callback/render code
- heap allocation/deallocation
- blocking locks, semaphores, condition variables
- file or network I/O
- logging/printing
- Objective-C/Swift UI model mutation
- async/await, task creation, actor hops
- device enumeration/listeners
- graph construction/destruction
- JSON/plist parsing
- unbounded loops

## Required design
- preallocate buffers and state
- build processing states off-thread
- atomically publish render-ready snapshots
- use bounded lock-free structures where cross-thread transfer is required
- zero-fill deterministically on starvation
- count underrun/overrun/format events with atomics
- keep control-plane recovery outside realtime callbacks

## DSP graph publication

The production render kernel uses preallocated publication slots. Graph construction and publication happen on the serialized control plane; the audio callback never constructs, frees, or waits for a graph.

The output callback acquires one immutable graph generation at the beginning of a hardware buffer and releases it at the end. A hardware buffer therefore never renders partly with an old graph and partly with a newly published graph.

Realtime acquisition is bounded. If the snapshot cannot be acquired within the fixed attempt limit, the kernel uses sanitized pass-through for that buffer and increments a diagnostic counter rather than waiting.

The control-plane publisher is allowed to yield while waiting to reuse an inactive slot whose older realtime reader has not yet released it. This wait is never permitted from an audio callback.

See `docs/DSP_KERNEL.md` for the concrete kernel contract.

## DSP component contract
Every realtime DSP component must document:
1. input/output format
2. sample-rate dependency
3. channel assumptions
4. memory allocation policy
5. synchronization policy
6. algorithmic latency in frames
7. reset behavior
8. bypass behavior
9. denormal/NaN handling where relevant

## Acceptance targets

```text
RT allocations = 0
RT blocking locks = 0
RT disk/network I/O = 0
unexpected NaNs = 0
snapshot read misses = 0 under normal control-plane update rates
sustained callback overruns = 0 under supported load
```

Planned transition starvation during a deliberate graph/device rebuild must be diagnosed separately from established-stream underruns.
