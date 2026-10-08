# PR95 — Multi-Position Quiet Zone

## User experience
Add an optional **Quiet Zone → Multi-Position Calibration** section to Active Acoustics.
One microphone is moved sequentially between positions, with a repeatable,
phase-synchronized stimulus and independently measured left/right speaker-to-mic
secondary paths at every seat. No additional simultaneous microphone is required
for **calibration**.

1. Create named positions (central seat, adjacent seats).
2. Capture each position sequentially with the **same calibrated microphone,
   route, sample rate, and common coherent phase/time reference**.
3. Assess capture quality, timing reference, source-path conditioning, spatial
   diversity, frequency coverage and latency. Nonrepeatable background sounds
   cannot establish cross-seat disturbance phase by sequential measurements.
4. Offline solve bounded complex stereo anti-noise coefficients using all seats,
   with explicit per-seat worsening constraints.
5. Show predicted reduction/worsening per position; discard solutions violating
   headroom, any-seat regression caps, or insufficient global benefit.
6. Commission with low-energy physical verification at each position, moving
   the same mic. Verify every position again after finalizing all positions.
7. Only then allow eligible live ANC, with mic left at designated **monitor
   seat**. Other positions remain *model-predicted*, not continuously measured.
   A live monitor regression invokes the existing PR90 fault fade. Stale
   geometry/route/session/calibration disarms multi-seat control.

## Critical physics boundary
For broad unpredictable party conversation, sequential captures at different
times cannot reliably estimate a coherent disturbance field at every seat.
PR95 therefore remains **bounded low-frequency stationary tonal ANC** within
PR90's 20–150 Hz hardware/engine limits. PR96 adds a live upstream reference
and a separately measured causality budget; it is NOT part of PR95.

## Safety contract
- Build a project-scoped optional multi-seat calibration sidecar, *not* a
  Content Preset setting.
- Fail closed if fewer than two seats, incompatible devices, untrusted capture,
  absent common phase reference, incompatible timing, low rank or non-finite
  paths, changing room/route, or insufficient injection headroom.
- Constrained multi-seat optimizer uses weighted residual minimization, soft
  worst-seat fairness and strict hard no-regression at **every** modeled seat.
  The source limit is always <= existing PR90 caps.
- No implicit activation: proposed coefficients are only offline previews until
  a verified commissioning step; never automatically arm an optimizer result.
- Live error microphone at only one seat cannot directly verify the rest in
  real time. UI always distinguishes modeled/commissioned vs live-observed.
- Per-seat results must report worst seat and regression, not just an average.
- Preserve PR90's runtime protection, fade and headroom limits.
