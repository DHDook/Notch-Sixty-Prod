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


## Fourth slice — measured reference-leakage stability preflight (offline)

The PR96 per-frequency design and compiler already check individual
reference-microphone echo magnitudes. The new
\`QuietZoneReferenceLeakageStabilityAnalyzer\` adds a complementary and
strictly conservative **time-domain BIBO small-gain criterion**. It accepts
three separate, repeatable source launches for the LEFT speaker and three
for the RIGHT speaker, all recorded with the same exact microphone channel,
DAC route lease, source fixture, sample clock and calibration rig.

Each limited-length speaker-to-reference impulse response includes a
per-tap uncertainty estimate. An upper L1 bound includes the absolute
three-repetition mean, maximum inter-repeat deviation at each tap,
and **three sigma** amplitude uncertainty at each tap. The resulting
worst-case feedback upper bound is

\`||L_ref||_1 × ||F_left||_1 + ||R_ref||_1 × ||F_right||_1\`,

with a conservative maximum of **0.10**. This is a sufficient stability
criterion only for a bounded, causal linear time-invariant plant whose
physical impulse responses lie inside the stated uncertainty envelope;
it is NOT a proof about nonlinear speakers, changing rooms, microphone
movement, or real adaptive ANC.

Preflight refuses missing/duplicate launches, wrong left/right count,
route/clock/fixture mismatch, expired captures, low coherence, changing
impulse responses, NaNs, invalid uncertainty, FIRs violating the existing
-24 dBFS L1 cap, and even a nominally safe path whose uncertainty
makes the whole-loop bound unsafe.

\`QuietZoneLeakageGuardedShadowSession\` offers a dedicated constructor
that runs this whole six-capture preflight **before** creating the already
clock-guarded native deadline FIFO. No new callback, output routing,
speaker connection, echo cancellation or adaptive gain is introduced.
The report explicitly says \`echoCancellerEnabled = false\`,
\`acousticFeedbackVerified = false\`, \`outputConnected = false\`, and
\`liveANCQualified = false\`. All supplied measurements remain model
data pending independent physical instrument review.

New deterministic XCTest tests cover low/high leakage, uncertainty
overruns, mismatch/duplication, stale/wrong rig, repeat drift, low
coherence, invalid values, candidate headroom and diagnostic admission.
**Actual** speaker-to-microphone impulse capture and physical echo
suppression remain future hardware-dependent work.


## Fifth slice — offline speaker-reference echo suppression and frozen adaptation

\`QuietZoneReferenceEchoModelBuilder\` compiles the six repeated PR98
left/right speaker-to-reference impulse captures only after the previous
small-gain, coherence, identity, freshness, repeatability and FIR-headroom
safety gates pass. It retains per-tap nominal impulse values and independent
three-sigma uncertainty envelopes, never treating a modeled response as
independently hardware-attested.

\`QuietZoneReferenceEchoOfflineSimulator\` is a strictly **disconnected,
offline-only** convolution of *known recorded stereo speaker waveforms*
through those measured impulse paths, subtracted from the same-timebase
microphone recording. It publishes a diagnostic pair of predicted speaker
echo and preview-decontaminated reference, plus mean-square residuals.
This does not run in a Core Audio callback or feed playback. Its bounded
4096-frame input blocks require the exact rig, fresh model, finite and
unclipped inputs and identical contiguous speaker/microphone sample indices.
One failure permanently halts and erases buffered history without returning
partial cleaned audio. It never assumes that model subtraction itself
attenuates noise at the seat.

\`QuietZoneReferenceEchoAdaptationGuard\` offers a distinct, non-mutating
coefficient **proposal** workflow. It accepts two separate, time-ordered,
source-silent speaker-only probe captures, disjoint from the six speaker
impulse capture launch IDs, and proposes small regularized normalized-gradient
changes. It rejects unbounded steps, coefficient changes outside the
measured tap uncertainty envelope, total adjustment exceeding 0.002,
conservative whole-loop gains above 0.10 and proposals that fail to improve
an independent held-out probe by at least 1% mean-square error. It does
**not** install proposed coefficients, run continuous live adaptation,
process unverified speech/background, or issue any output data or command.

Synthetic end-to-end XCTest covers stereo echo/ambient preservation,
cross-block convolution continuity, frame gap/route/staleness faults,
nonfinite/clipping failures, uncertain models, probe double-talk,
independent validation regression and unsafe coefficient updates.
All outputs are marked \`outputConnected = false\` and
\`liveANCQualified = false\`. Even a successful held-out simulated probe
is **not** acoustic feedback stability certification, physical clock
attestation or authority to energize ANC.


## Sixth slice — conservative output envelope and simulated fault-to-bypass

**The native PR98 shadow deadline bridge still discards every computed
anti-noise PCM sample.** To prevent future assumptions that the existing
individual FIR limiter would cover stereo summation, it now checks
**per-speaker instantaneous peak ≤0.063095734 (-24 dBFS)** AND
**combined instantaneous |left| + |right| ≤0.10 (≈-20 dBFS)**.
Any FIR sanitization or limiting event is treated as a FAULT, rather than
silently accepting a clipped anti-noise suggestion. A violation terminally
halts the scheduler, invalidates its metadata queue and clears FIR history.
The snapshot exposes only a quantized observed stereo peak, never audio.

All halts now start a **128-frame simulated fault-to-bypass counter**.
An explicit control-plane \`N60FFDeadlineBridgeAdvanceFaultFade\` step
reduces a metadata-only hypothetical wet ANC gain from 1.0 to 0.0,
monotonically. After fault, no reference frame may resume the scheduling
engine, even when the counter reaches zero; a new independent calibration
and distinct session will ultimately be needed. A real speaker fade or
emergency mute MUST be implemented and measured later as part of the live
output integration. No actual audio can be faded by this code because
nothing is connected to the DAC.

\`QuietZoneFeedForwardSafetyAcceptanceEvaluator\` aggregates ten explicit
software and hardware review gates: individual gain, shared stereo headroom,
HAL clock, deadline diagnostics, leakage bound, offline echo model,
simulated bypass, external instrument calibration, measured seat ANC benefit
and stability, and separate output authorization. All apparently passing
software results remain **diagnostic only**. Independent physical acceptance
and live authorization are always marked incomplete; the returned
\`liveANCQualified\`, \`independentlyCommissioned\`, and
\`speakerOutputConnected\` remain **false** in every case.
Negative/missing evidence fails the relevant diagnostic gate.

Targeted XCTest adds four native-envelope and fade tests and six
commissioning-report tests, including software-green-but-hardware-blocked,
per-channel-valid-but-combined-too-loud, invalid clock, and wrong echo rig.

**Physical hardware outstanding:** Independent calibrated input-to-output
sample/timestamp mapping, physical DAC/speaker/seat latency,
source/microphone acoustic consistency, real SPL/attenuation, echo/feedback
stability under moving people, and implementation of a speaker-connected
hardware-verified mute/fade. This PR does not enable or claim acoustic ANC.
