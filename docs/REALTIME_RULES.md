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
sustained callback overruns = 0 under supported load
```

Planned transition starvation during a deliberate graph/device rebuild must be diagnosed separately from established-stream underruns.
