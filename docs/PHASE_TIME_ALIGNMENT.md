# Phase & Time Alignment Foundation

PR30 adds two independent, commercially-authored phase/time primitives.

## All-Pass EQ

The minimum-phase EQ engine supports a second-order All-Pass section. Frequency and Q control phase rotation while magnitude remains unity. All-Pass is intentionally rejected by the current Linear Phase FIR EQ projection because that designer represents magnitude equalisation, not arbitrary phase-only requests.

## Signed inter-channel delay

`PlaybackControlConfiguration.interChannelDelayMs` supports **−20...+20 ms**:

- positive values delay **Right** relative to Left;
- negative values delay **Left** relative to Right;
- zero is a true transparent bypass.

Non-zero alignment adds the same two-frame common interpolation latency to both channels, then adds the requested relative delay to the selected channel. This allows a third-order Thiran all-pass approximation for fractional samples while keeping magnitude unity and greatly improving broadband fractional-delay accuracy over a first-order section. Exact integer delays use direct circular-buffer indexing with no all-pass section.

The two-frame common delay is local to the post-audition speaker-alignment stage. It is not added to the Processed-vs-Reference graph latency because both selected audition outputs receive the alignment stage together. Global Bypass discards the aligned copy and remains raw. Master volume remains downstream.

## Realtime contract

- fixed 8192-frame per-channel history; no callback allocation;
- delay/all-pass coefficients are designed when the immutable graph snapshot is built, not in the render callback;
- current and pending taps crossfade over the graph gain-transition window;
- rapid UI changes queue only the newest target instead of replacing an active crossfade branch;
- histories remain warm during Global Bypass so leaving bypass does not start from an empty delay line;
- no locks, logging, file/device I/O, or coefficient construction in realtime.

## Deferred related capabilities

Excess-phase correction stays with the room-correction suite because it requires phase-resolved measurement. Independent sub-bass phase alignment and multi-driver IR timing remain deferred until their physical output paths exist.
