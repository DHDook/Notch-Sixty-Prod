# Parametric EQ foundation

PR #13 introduces the first substantive DSP stage in the commercial Notch Sixty render graph.

## Scope

The stage supports up to 16 serial biquad bands. The current filter families are:

- peaking
- low shelf
- high shelf
- low-pass
- high-pass
- notch

The production graph remains stereo in this milestone, but the coefficient/state primitives are portable C and contain no Core Audio, Swift, AppKit, Accelerate, or other Apple-only dependency.

## Graph contract

`N60DSPGraphSnapshot` carries render-ready EQ state:

- whole-stage bypass
- active band count
- sample-rate-scaled transition-frame count
- one immutable `N60BiquadBandSnapshot` per configured band
- precomputed normalized coefficients

All frequency/Q/gain validation and coefficient design occurs on the control plane before publication. The realtime callback performs no trigonometry, coefficient construction, allocation, locking, logging, or asynchronous work.

## Parameter transitions

Published band changes do not directly interpolate biquad coefficients. Direct coefficient interpolation can pass through undesirable or unstable intermediate pole locations.

Instead, the kernel keeps preallocated current and pending filter states and crossfades their outputs for approximately 5 ms. The transition duration is converted to frames when the graph snapshot is created, so the callback performs only bounded arithmetic and filter processing.

Enabling a band crossfades dry to filtered output. Disabling a band crossfades filtered to dry output. The EQ-stage bypass and graph-level bypass remain explicit and independent.

## Filter implementation

The realtime filter uses transposed direct form II with independent state per stereo channel. Q controls peaking/notch bandwidth, low/high-pass damping, and shelf steepness.

The EQ stage adds zero algorithmic latency. Any future linear-phase/FIR mode will report its own latency separately rather than changing this minimum-phase contract.

## Validation

Deterministic tests cover:

- +6 dB peaking response at the center frequency across 44.1, 48, 96, 192, and 384 kHz
- low-pass and high-pass directional attenuation
- low-shelf and high-shelf endpoint behavior
- notch rejection at the center frequency
- invalid Nyquist/Q rejection
- per-band bypass
- whole-stage bypass
- existing render-kernel unity, gain, graph-bypass, and sanitation behavior

Hardware validation for this PR is primarily a regression check because the production control-plane/UI does not yet publish user-authored EQ bands. The default graph therefore remains unity.

## Portability rule

Future processors should continue the same separation:

```text
platform audio transport
        ↓
portable render/DSP core
        ↓
platform audio transport
```

Platform-specific routing, device/session APIs, media-server transport, and UI must remain outside the filter math. This keeps the DSP suitable for future Windows, iOS, and Android hosts without expanding the current Mac-stereo product scope.

## Provenance

This implementation was written independently for the commercial repository from standard public digital-filter equations and the documented Notch Sixty architecture/realtime requirements. It does not copy or adapt historical GPL Notch Sixty, Equaliser, BlackHole, or CoreAudioTapPOC source.
