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


## Second slice: native SPSC shadow deadline bridge (remote)

The native C \`N60FeedForwardDeadlineBridge\` is a preallocated, fixed-capacity
single-producer/single-consumer FIFO (256–4096 power-of-two records) for
**hypothetical output frame/time/slack metadata only**. It has no output PCM
API. Setup allocates the ring and configures the existing bounded native
PR96 FIR exactly once, off the callback. Per-frame Process and Read use
bounded loops, acquire/release atomics, no locks, allocation, logging,
Core Audio calls, Objective-C, Swift callbacks or memory replacement.
A corrupted reference sample, clock drift or discontinuity, wrong route
or clock token, stale output witness, missed sample deadline or metadata
FIFO overflow permanently halts the bridge, resets FIR state and returns
no further records. Anti-noise L/R samples remain temporary variables and
are **discarded**, never published.

\`QuietZoneNativeShadowTimingTransport\` is a non-realtime Swift owner
that checks identity with existing \`N60FeedForwardReferenceFrame\` HAL
input-ring metadata, accepts externally cross-calibrated acoustic timestamps
and output witnesses, and forwards the input to the C bridge. It offers
only read-only deadline diagnostics. The selected route/clock are represented
by control-plane generated numeric tokens; matching these does not independently
authenticate hardware and the caller must regenerate them on changes.
The adapter deliberately does not attach to the playback callback.

Deterministic native FIFO/adversarial XCTest covers ordering, ring
wraparound, expiry, clock and route changes, missed deadlines, raw HAL
reference-ID mismatch, exhaustion, invalid FIR and noncausal plans.
The native bridge rejects overlarge/unbounded FIR coefficients using the
existing PR96 L1 limiter and always reports playback disconnected.

**Not yet implemented:** A hardware-calibrated mapping from HAL host
ticks to physical acoustic emission and DAC deadlines; the output scheduler
is not running inside an IOProc and is not eligible to drive speakers.
Transport safety tests with synthetic timestamps are not proof of realtime
OS scheduling or measured cancellation. Any future live topology must
undergo physical commissioning, echo/feedback stability screening, and
explicit independent authorization before enablement.


## Third slice — continuously qualified clock alignment watchdog

\`QuietZoneFeedForwardClockMonitor\` loads a two-second **PR97-qualified**
synchronized HAL input/output trace for an exact physical microphone and
selected DAC/route lease. Every subsequent control-thread observation
must be monotonic, consistent with fitted sample rates, from the same
route/rate/lease, recently witnessed, and inside a bounded overlapping
window; the original PR97 analyzer is rerun to detect *gradual clock drift*
even when individual callback increments appear plausible.

It rejects sudden frame-counter jumps, reversed/stalled clocks, device
restart, sample-rate changes, expired/missing timestamps, and excessive
relative drift permanently. It also validates that **the individual
scheduled input and output frame IDs actually map to the monitored host-time
axes**. Merely supplying an unrelated "healthy" clock trace cannot validate
another set of frame IDs.

\`QuietZoneClockGuardedShadowTransport\` wraps the native PR98 metadata
bridge: fresh clock/route and frame-mapping validation are required before
each hypothetical scheduling operation. Any clock fault calls the native
transport terminal stop, revokes any queued diagnostics and cannot be
recovered by repackaging the same frame. Native deadline/FIR output remains
**physically disconnected**, and all clock reports assert
\`physicalLatencyVerified = false\` and \`liveANCQualified = false\`.
An untrusted caller-supplied trace or route token alone cannot qualify real
hardware or justify enabling ANC.

Five pure clock watchdog tests and three guarded-native integration tests
cover ordinary fresh clocks, sudden frame jumps, reverse/stalled counts,
rate drift over repeated observations, route restarts, stale data, unrelated
frame IDs and FIFO revocation. The user-return hardware path still needs
actual shared-host-clock observation acquisition and physical ADC/DAC/
speaker acoustic commissioning; no clock converter or live output callback
is fabricated from model estimates.
