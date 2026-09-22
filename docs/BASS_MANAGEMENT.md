# Bass management / crossover foundation

PR #16 introduces a clean-room, portable crossover processor for Notch Sixty's production DSP graph.

## Current product scope

The current macOS transport remains stereo-only. PR #16 therefore models bass management as logical DSP buses:

- stereo mains bus: high-passed left/right
- mono sub bus: `(L + R) / 2`, then low-passed
- stereo validation output: one of `recombined`, `mains only`, or `sub only`

The validation output is intentionally not presented as an independently routable physical subwoofer channel. A future routing/output layer may map logical buses to separate hardware channels or endpoints without changing the crossover math.

## Supported crossover topologies

- Linkwitz-Riley 24 dB/octave (LR4): two cascaded 2nd-order Butterworth sections per leg
- Linkwitz-Riley 48 dB/octave (LR8): two cascaded 4th-order Butterworth filters per leg

Both are designed off the realtime thread using precomputed biquad coefficients. At the crossover frequency each leg is approximately -6.02 dB; for correlated stereo material the recombined preview is approximately amplitude-flat.

## Realtime behavior

Crossover state is preallocated inside `N60RenderKernel`.

- no allocation in render
- no locks
- no logging or async work
- no coefficient design/trigonometry in render
- no added algorithmic latency
- live topology/frequency/monitor changes use a short dual-path crossfade rather than a hard state swap

The crossover runs after the global EQ and before DSP output gain. `Post-EQ` metering is therefore pre-crossover, while `DSP output` metering reflects the selected validation monitor path.

## Control-plane configuration

The application model exposes:

- enabled/bypassed
- crossover frequency (20-500 Hz)
- LR24 or LR48
- validation monitor mode
- sub gain (-24 to +12 dB)
- sub polarity inversion

The configuration is rebuilt into the graph snapshot and therefore survives stop/start, sample-rate rebuild, same-UID output recovery, and sleep/wake reconstruction.

## Portability

The crossover primitive depends only on the portable C DSP layer and has no Core Audio, Swift, AppKit, or macOS dependency. The logical-bus model is intentionally compatible with future Windows, iOS/Android endpoint processing, multi-sub, and multichannel routing work.

## Deliberately deferred

PR #16 does not add:

- independently routable physical sub output
- delay/time alignment
- variable phase/all-pass alignment
- multiple subs
- per-bus EQ
- FIR/linear-phase crossover
- room-correction integration

Those belong in later graph/routing and room-correction milestones rather than being hidden inside the foundational crossover processor.
