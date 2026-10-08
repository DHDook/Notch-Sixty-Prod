# PR95 — Multi-Position Quiet Zone

## Aim
Extend PR90's safe 20–150 Hz tonal Active Quiet Zone from one measured error point to a **bounded multi-position listening-area objective**, using one ordinary microphone moved between positions sequentially.

## Physical limits and calibration policy
- PR90's live error microphone remains the *only continuously measured* runtime location.
- Each position needs measured left/right speaker-to-mic impulse responses at one common sample rate, microphone identity, calibration and route.
- To compute complex environmental cancellation across different positions, **noise measurements must share a defensible coherent phase reference**. Independent FFT windows from sequential measurements are NOT coherent, even if the tones look similar.
- A *phase-referenced stationary-source survey* (or controlled source / explicitly qualified common time base) is required before applying a multi-seat complex cancellation solver.
- Without phase-coherent source data, PR95 only computes a conservative spatial injection-risk envelope and recommends a sequential move-and-measure process; it must NOT claim verified multi-seat reduction.
- A single live mic cannot verify simultaneous changes in other locations. Only an offline remeasurement campaign can establish area-wide benefit; when the environment/source changes the saved spatial model may no longer be valid.
- In a moving-party/noise scenario, PR95 remains deliberately limited to persistent coherent LF tones; PR96/97 tackle more complex feed-forward acoustics.

## Core model
Project-scoped `ActiveQuietZoneSpatialCalibration` stores chosen positions, the live anchor ID, source coherence/frequency stability evidence, sample-rate and route identity, and explicitly referenced complex disturbance transfer ratios. Calibration never resides in Content Presets; it is not a global DSP preset.

The solver optimizes weighted LF complex residual energy with regularization and **per-seat do-no-harm limits**; source amplitude follows PR90 injection limits. It rejects poor conditioning, untrusted phase reference, mismatched routes, substandard quality, >configured spatial regression or inaudible overall improvement. Single-position PR90 remains available as an explicit fallback only with user intent.

## Workflow
1. Create/save a Room Correction project with 2–5 positions measured by moving the same mic; choose the live anchor.
2. Review route/mic/speaker-path readiness and positions.
3. Gather phase-coherent *environmental* tone evidence. Mere multiple saved Room Correction sweeps are not sufficient.
4. Compute spatial candidate; show predicted per-position attenuation/regression and confidence.
5. Run low-level probe and sequential move-and-measure verification at each seat. Record real measured before/after changes.
6. Only then explicitly arm the validated multi-position strategy, with one live physical monitor at the anchor; fail closed on source drift or changed routing.

PR95 must not be marketed as whole-room ANC.
## Implemented single-microphone survey

The microphone-only observation path now retains the frame index and a
session epoch for each published residual window. Playback must be stopped
during this survey; PR89 modeled playback subtraction is not used as an
acceptable substitute for a stationary external source.

A capture takes the strongest nearby tone, refines its frequency below FFT
bin resolution, and rotates its complex phasor into the continuous input
clock basis. The user sequentially makes **two observations at each location**,
beginning and ending with the anchor. The survey builder checks:
- an uninterrupted input session epoch;
- source frequency and stationarity across captures;
- narrowband prominence and adequate capture length;
- duplicate observations at each location for phase/level stability;
- a final return-to-anchor phase and level closure;
- no more than three minutes in the full sequence.

A failed gate prevents saving a phase-coherent survey. Successful records are
kept in the project-scoped sidecar. Mic audio itself is not persisted.

This method is appropriate for a strongly stationary LF tone and requires the
source to be stable over the entire mic movement. It is not appropriate for
moving speakers, party conversations, broadband interruptions or shifting
mechanical noise. The user must then return the mic to the calibrated anchor
for realtime PR90 verification.

**Caveat:** software-side counters cannot by themselves prove that the
hardware input experienced zero lost samples or that the source remained
globally phase coherent between captures. Return-to-anchor and
within-position coherence guards are necessary but not a substitute for
simultaneous reference and error microphones.

## Spatial live operation

With an explicit enabled spatial strategy and a recent passing survey,
the PR90 probe/controller solves regularized weighted complex residuals
for all sampled positions, respects the same per-source/aggregate headroom
and frequency limits, and rejects candidates that predict unacceptable
seat regression. A passing model is not independent physical measurement
of the other seats.

The runtime physical microphone at the anchor still gates all coefficient
updates and faults on measured regression. The spatial model expires after
30 minutes; a change in the noise field can invalidate its predictions even
sooner. Multi-position before/after verification requires physically moving
and remeasuring the mic between seats; PR95 does not claim simultaneous
verification or whole-room broadband cancellation.
