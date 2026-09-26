# Live parametric EQ control plane

PR #14 connects the production parametric EQ engine to application state and live graph publication.

## Product contract

- Up to 64 user EQ bands are supported for legacy parity and advanced playback use cases.
- The user model and the realtime graph are separate representations.
- Disabled user bands are omitted when the graph is compiled, so `eqBandCount` represents enabled/rendered bands rather than UI slots.
- Zero bands is the default.
- The EQ stage and individual bands can be bypassed without rebuilding the Core Audio transport.
- Current EQ state is republished whenever the transport is rebuilt for a sample-rate change, output recovery, or sleep/wake.

The 64-band capacity is a maximum, not a recommendation that ordinary playback presets should use 64 filters. Complex broadband correction should eventually prefer the dedicated FIR/room-correction engines where appropriate.

## Realtime boundary

Coefficient design and graph compilation occur on the control plane. The render callback receives a fully formed immutable snapshot through the atomic publication mechanism introduced by PR #12. No filter design, allocation, locking, SwiftUI work, or device discovery occurs in the realtime callback.

The render kernel retains fixed preallocated state for the maximum capacity. The graph builder compacts enabled bands into contiguous render slots. Disabled UI bands therefore do not create active biquad stages.

## Temporary validation UI

PR #14 exposes a deliberately utilitarian validation editor with:

- add/remove band
- enable/bypass band
- filter type
- frequency
- gain
- Q / shelf shape
- whole-EQ bypass
- configured/active/max counts

This is not the final Notch Sixty EQ editor. It exists to validate live publication, transition behavior, transport stability, and high-band-count performance before the production UI is designed.

## Hardware acceptance

At both a normal rate and 384 kHz:

1. Start with zero bands and confirm the established transport counters remain clean.
2. Add a peaking band while music is playing and make an obvious gain change. Audio should transition without click/pop or interruption.
3. Change frequency, gain, Q, filter type, band enable, and whole-EQ bypass while running.
4. Add multiple enabled bands and verify diagnostics reports the enabled/rendered count.
5. Exercise a 64-enabled-band stress configuration at 384 kHz and confirm no transport underruns/overruns or DSP snapshot misses.
6. Change sample rate and confirm the active EQ configuration returns after rebuild.
7. Stop/start once and confirm the in-memory EQ configuration is republished.

The 64-band stress case is a capacity/performance test, not a recommended listening configuration.

## Portability

The control model is Swift in the current macOS frontend, but the render snapshot remains a C ABI. Future Windows, iOS, and Android frontends may implement their own control models and compile them into the same portable graph representation.


## PR33 Dynamic EQ integration

PR33 keeps the independently authored `N60DynamicEQ` detector/gain engine but makes Dynamic a capability of the normal EQ-band product model rather than a second user-visible band bank. Supported linked minimum-phase Peak bands can enable Dynamic controls directly. Static gain continues to be rendered by the established parametric-EQ biquad; the Dynamic engine contributes only the time-varying correction delta at the EQ stage, preserving the band's neutral static response when no dynamic correction is active.

The realtime Dynamic EQ capacity is 64 bands to match `N60_MAX_EQ_BANDS`. Disabled/non-dynamic EQ bands incur no Dynamic-EQ per-band processing. The 64-dynamic-band / 384 kHz case is a capacity stress target for the bounded optimization pass, not a recommended ordinary preset.
