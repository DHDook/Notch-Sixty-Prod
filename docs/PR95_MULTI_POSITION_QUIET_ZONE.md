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