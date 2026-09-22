# Live minimum/linear EQ switching

PR #19 turns the linear-phase designer from PR #18 into a live EQ mode while preserving the existing minimum-phase path.

## One EQ model, two render modes

Notch Sixty keeps one 64-band EQ configuration. The phase mode controls how those bands are compiled:

- **Minimum phase**: enabled bands become realtime biquad sections.
- **Linear phase**: enabled bands are combined by `N60LinearPhaseEQ` into one symmetric FIR and the realtime IIR band list is empty.

Presets and the future production UI therefore do not need separate sets of bands for the two modes.

## DSP order

Linear-phase FIR is an EQ implementation, so it occupies the same logical position as minimum-phase EQ:

```text
input gain / headroom
        ↓
EQ (minimum-phase biquads OR linear-phase FIR)
        ↓
post-EQ meter
        ↓
bass management / crossover
        ↓
output gain
```

PR #17 originally placed its generic convolution stage after crossover because it was only an engine foundation. PR #19 moves that stage to the EQ position. Future room-correction convolution will be modeled as a separate graph stage rather than sharing the linear-EQ slot.

## Safe FIR program replacement

The convolver owns two preallocated program slots. `N60PartitionedConvolverPrepareProgram` refuses to overwrite the slot currently consumed by the realtime path. Live linear-phase edits therefore use this lifecycle:

1. design the new FIR on the control plane;
2. prepare the inactive convolution slot;
3. fade the transport's dedicated graph-transition gain to silence;
4. atomically publish a graph referencing the newly prepared slot;
5. ramp the transition gain back to unity in the realtime callback;
6. on the next redesign, reuse the now-inactive former slot.

The user/master volume is not used for this transition.

## Why fade through silence

Minimum-phase and linear-phase graphs have different algorithmic latency. A naive crossfade would mix differently delayed versions of the same signal and can create comb filtering. PR #19 therefore uses a very short fade-through-silence for latency-changing graph swaps. This is bounded and deterministic, and it avoids clicks/pops and phase cancellation without adding a second delay-compensation engine merely for the transition.

## Sample-rate changes and recovery

The user EQ model persists independently of prepared FIR programs. When the transport is rebuilt after a native sample-rate change, output-device recovery, or sleep/wake, a linear-phase configuration is redesigned for the new active sample rate and prepared in the new render kernel before publication.

Bands above the active Nyquist frequency remain in the user model but are omitted from the current minimum- or linear-phase design. This preserves presets across native sample-rate changes.

## Realtime guarantees

FIR design and FFT preparation occur off the realtime callback. The callback still performs no allocation, blocking locks, logging, disk/network I/O, UI work, or filter construction. Graph publication remains atomic and each hardware buffer holds one immutable snapshot generation.

## Current optimization boundary

For PR #19, linear-phase redesign is synchronous on the app control plane. This is safe for audio realtime behavior but can make very large/high-rate designs briefly occupy the main thread during rapid editing. A later polish pass should move FIR design to a background worker with debounce/coalescing while retaining exactly the same publication and slot-ownership rules.

## Hardware validation

Validate both 96 kHz and 384 kHz:

- switch minimum ↔ linear while music is playing; expect only a very brief controlled dip, never a click/pop/buzz;
- edit frequency, gain and Q repeatedly while linear mode is active;
- verify linear mode renders zero IIR bands and an active FIR;
- verify FIR program slot/generation changes on redesigns;
- verify FIR program misses, snapshot misses, underruns, overruns, and non-finite samples remain zero;
- verify approximate linear-mode latency is ~24 ms at 96 kHz and ~22 ms at 384 kHz;
- change native rate while linear mode is active and confirm the FIR is redesigned and playback recovers automatically.
