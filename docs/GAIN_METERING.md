# Gain, headroom, and metering foundation

PR #15 establishes explicit DSP-domain gain staging and observability before additional processing stages are introduced.

## Signal order

Current production order:

```text
captured input
  -> input preamp
  -> internal headroom attenuation
  -> parametric EQ
  -> DSP output gain
  -> transport startup fade / physical output
```

The transport startup fade is intentionally outside DSP metering and headroom decisions.

## Gain stages

- **Input preamp** is user-controlled gain applied before EQ.
- **Headroom attenuation** is a distinct internal gain stage. It is manually controllable for validation in PR #15, but no automatic compensation policy is enabled yet.
- **DSP output gain** is user/control-plane gain after EQ.

The graph snapshot stores linear gain values. The Swift control plane presents dB values and converts them before publication.

Live gain changes are smoothed over a short sample-rate-scaled transition using preallocated runtime state. No allocation, locking, logging, async work, or UI access occurs in render.

## Meter points

Meters are published for three locations:

1. **Input** — captured signal before any DSP gain.
2. **Post-EQ** — after input preamp, headroom attenuation, and EQ; before DSP output gain.
3. **DSP output** — after DSP output gain; before the transport startup fade.

Each meter reports stereo peak, stereo RMS, and a cumulative count of samples whose absolute value exceeded 1.0 (0 dBFS in normalized float amplitude).

Peak and RMS are calculated locally in the render context for one hardware buffer. The completed buffer reading is atomically published once at `EndRender`; the UI never reads audio buffers or mutable filter state.

The over-range count is diagnostic only. PR #15 does not clip, limit, normalize, or otherwise modify over-range samples.

## Scope boundaries

PR #15 intentionally does **not** add:

- limiter or compressor behavior
- true-peak / inter-sample-peak oversampling
- LUFS / loudness metering
- automatic headroom calculation
- peak hold / decay presentation
- final production meter UI

Those can be layered on this foundation later without changing the realtime/control-plane boundary.

## Portability

Gain math and meter accumulation live in the portable C DSP kernel and depend on no Core Audio, SwiftUI, or macOS-specific API. Platform transports remain responsible only for delivering and consuming audio buffers.
