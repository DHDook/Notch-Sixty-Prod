# PR98 — Causal Feed-Forward Runtime (staged)

## Goal

Build a low-latency, two-loudspeaker feed-forward reference-to-output path
from the single upstream microphone, while maintaining reliable source timing,
causality and fail-closed protections. This PR is stacked on PR97 and does
**not** claim that real hardware has been acoustically commissioned.

## First slice: disconnected sample-deadline planner

PR96 already provides a native input-only timestamped reference bridge,
an offline causal stereo FIR compiler, a bounded native preview FIR and a
no-output reference rehearsal.

PR98 adds \`QuietZoneFeedForwardShadowScheduler\`, a **control-plane-only**
planner for the deadline of each potential anti-noise output frame.
It consumes an externally synchronized acoustic reference arrival, its
measured acquisition-available time and an exact output-clock frame/host-time
anchor, then checks whether FIR processing could finish in time for a
correctly rounded output sample slot.

It uses PR97's conservative lower bound on noise travel lead, measured
DAC+speaker-to-listener propagation, measured processing latency, and
the complete worst-case jitter/3σ allowance **exactly once**, followed by
the required explicit safety reserve. Nothing is inferred from nominal
HAL buffer sizes or a cable loopback interpreted as acoustic travel.

A stale output callback witness, route lease or rate change, input drop,
timestamp rewind, nonfinite signal, impossible acquisition timing, missed
output deadline, invalid filter or noncausal physical budget stops the
shadow scheduler permanently. Its internal PR96 native stereo FIR runs
into discarded scratch variables; **no audio samples or output pointers
are published**, and there is no Core Audio render/injection connection.
All scheduling is strictly off the realtime callback. No speaker is driven.

Seven synthetic XCTest cases cover monotonically scheduled 128-frame
streams, route resets, late processing, stale output timing, input drop
and rewind, nonfinite acquisition, noncausal budgets, FIR headroom and
physical-route mismatches.

## Later PR98 slices

- Ground acoustic/input/output timestamps in separately calibrated hardware
  clocks, including rate changes and output callback delay fluctuations.
- Native allocation-free realtime reference→output scheduling and
  multiproducer/singleconsumer ownership/lifecycle checks.
- Control-loop authority, leakage/reference echo cancellation and physical
  secondary-path correction with staleness monitoring.
- Bounded output, fault-fade and robust independent seat acoustic acceptance.
- Live anti-noise speaker mixing must remain **disconnected** until
  independently verified, especially for unpredictable speech/noise.

Positive causality or signature checks do not prove attenuation. No
unverified estimate of cancelled frequency range or dB reduction is made.
