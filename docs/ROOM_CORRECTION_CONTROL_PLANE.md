# Room Correction Control Plane

## Scope

PR #21 exposes the room-correction runtime foundation from PR #20 to the Swift control plane. It is intentionally a control/validation milestone, not the acoustic measurement or correction-design milestone.

The control plane can now retain a room-correction filter definition, prepare it in the dedicated room-correction convolver, attach or bypass it in a graph, and rebuild it when the Core Audio transport is recreated.

## Filter model

A `RoomCorrectionFilter` contains:

- a diagnostic/display name;
- optional source sample-rate metadata;
- left FIR coefficients;
- optional independent right FIR coefficients;
- declared filter/group-delay latency in frames.

If the right FIR is omitted, the left FIR is applied to both channels. When source-rate metadata is present it must match the active output device rate; PR #21 does not silently resample correction filters.

Before preparation the control plane rejects empty or oversized FIRs, non-finite coefficients, mismatched stereo FIR lengths, incompatible sample-rate metadata, and invalid declared latency.

## Program ownership and transitions

Room correction continues to use the independent three-slot program namespace introduced by PR #20. Linear-phase EQ and room correction therefore cannot overwrite one another even when they use the same numeric slot.

A new or changed room-correction FIR is prepared off the render path in an inactive room-correction slot. The resulting graph is published with the existing fade-through-silence graph transition so FIR replacement, enable, and bypass do not create an abrupt discontinuity.

Unrelated EQ, gain, and crossover changes preserve the currently active room-correction program in the rebuilt graph.

## Transport rebuilds

Room-correction configuration is model state, while prepared convolution programs belong to a particular transport/render-kernel lifetime. On device sample-rate changes, output recovery, sleep/wake rebuilds, or other transport recreation:

1. prepared-program state is discarded;
2. the room-correction filter model is retained;
3. if room correction is enabled, the filter is validated against the new native device rate;
4. a fresh program is prepared in the new room convolver;
5. the rebuilt graph references the new program before audio starts.

A sample-rate-specific filter that does not match the new output rate fails closed instead of being silently interpreted at the wrong rate.

## Deterministic validation filter

PR #21 defines a rate-independent three-tap validation FIR:

```text
[0.25, 0.50, 0.25]
```

with one frame of declared filter latency. It exists only to validate the complete control-plane -> bridge -> room-convolver -> graph-publication path on real hardware before the measurement pipeline exists. It is not an acoustic correction solution and must not be presented as one.

## Deferred intentionally

PR #21 still does not implement microphone selection/capture, sweep generation, impulse-response extraction, three-seat storage or averaging, target curves, correction-window policy, correction FIR design, automatic headroom compensation, calibration persistence/presets, or final room-correction UX. Those build on this control plane in later milestones.

## Provenance

This control-plane implementation is original commercial code derived from the Notch Sixty production architecture and the clean-room runtime contract established in this repository. No historical GPL Notch Sixty / Equaliser implementation, tests, project files, or assets were used as coding references.
