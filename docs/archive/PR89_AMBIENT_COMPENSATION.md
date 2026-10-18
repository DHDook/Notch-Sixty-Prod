# PR89 — Ambient Compensation

PR89 turns the passive ambient-field foundation into an opt-in playback adaptation system for changing room noise: parties, conversation, HVAC, open windows, appliances, and similar environmental sound.

## Product goal

Preserve perceived musical balance and intelligibility as the room gets louder or quieter without creating a feedback loop that treats Notch Sixty's own loudspeakers as "ambient noise."

The feature is deliberately slow, bounded, explainable, and fail-closed. It is not automatic volume normalization and it is not active noise cancellation.

## Architecture

1. A bounded live microphone monitor copies mono microphone frames into a preallocated SPSC bridge. The Core Audio callback performs no allocation, FFT, filtering, logging, locks, or Swift calls.
2. Existing playback-analysis capture supplies the exact rendered playback reference when the active transport supports it.
3. The control plane aligns bounded microphone/playback windows and passes them to `AmbientFieldAnalyzer`.
4. Playback subtraction is used only when an acoustic speaker-to-microphone model is available and confidence is sufficient.
5. `AmbientCompensationPlanner` converts trusted ambient snapshots into a slowly varying compensation target.
6. A controller smooths target changes and publishes an immutable runtime overlay. UI reads the same controller state.
7. Any missing evidence, transport mismatch, stale acoustic model, low confidence, clipping, or non-finite result removes automatic compensation rather than guessing.

## Compensation policy

The planner produces:
- ambient activity class: Quiet / Normal / Busy / Party
- requested level compensation
- low-frequency support
- vocal/presence support
- high-frequency/detail support
- confidence and hold/fallback reason.

The policy uses broad spectral regions only. It does not chase tones, room modes, individual voices, applause, claps, or transient events.

### Level safety

Automatic level compensation is limited by **known existing digital headroom**.

If the active Content Preset has 4 dB of headroom attenuation and the profile permits a maximum 3 dB ambient level lift, PR89 may release at most 3 dB of that attenuation. If no digital headroom is available, automatic level lift is 0 dB.

PR89 never raises the effective digital gain above the uncompensated 0 dB headroom boundary.

Initial production maximum: 3 dB level compensation. Hard implementation ceiling: 6 dB.

### Tonal safety

Broad tonal offsets are intentionally small:
- low-frequency support: 0...+2 dB
- presence support: 0...+2 dB
- high-frequency/detail support: 0...+1.5 dB

They are reduced when spectral evidence is uncertain or spatial/playback separation confidence is weak.

## Temporal behavior

Ambient adaptation is intentionally much slower than dynamics processing.

Initial production behavior:
- analysis window: roughly 0.5–1.5 s depending on sample rate / transport
- minimum trustworthy separation confidence: 0.75
- activity hysteresis: 1.5 dB
- attack/rise time: 6 s
- release/fall time: 20 s
- transient rejection/hold after nonstationary events
- no reaction to a single analysis window.

A party that gradually fills becomes "Busy" or "Party"; a dropped glass, clap, door slam, or nearby shout does not immediately change playback.

## Ambient reference

The user can establish a quiet-room baseline. Absolute calibrated SPL is displayed when microphone SPL calibration is available; otherwise relative dB is used and the feature remains functional.

Automatic activity thresholds are measured relative to that baseline. Absolute SPL labels never pretend to be calibrated when they are not.

## Playback separation

Preferred path:
- exact rendered playback reference
- measured source-to-monitor acoustic impulse response
- modeled playback subtraction
- minimum confidence gate.

If audible playback is present but no trustworthy acoustic model exists, the system enters **Observe / Model Required** and does not apply automatic compensation.

During negligible playback, microphone-only ambient estimates may update the baseline and ambient display.

## Profile ownership

Ambient Compensation belongs to the Playback System, not the Content Preset.

Persisted Playback System configuration contains:
- enabled state
- adaptation strength
- maximum level compensation
- level compensation opt-in
- baseline ambient level
- optional absolute SPL reference
- attack/release times
- confidence threshold.

Runtime compensation is ephemeral. Turning the feature off or losing trusted evidence returns the overlay smoothly to unity without modifying the user's Content Preset.

## Realtime contract

No `AmbientFieldAnalyzer`, planner, FFT, spectrum math, policy logic, or UI state runs in an audio callback.

Realtime code is restricted to:
- bounded preallocated microphone capture
- bounded existing playback-reference capture
- immutable prepared compensation snapshot consumption.

## Scope

PR89 includes:
- live ambient monitor substrate for stereo production playback
- playback-reference handoff
- adaptive policy/planner
- Playback System persistence
- Active Acoustics UI
- confidence/fallback diagnostics
- deterministic tests
- dedicated CI guard
- fail-closed interaction with unsupported semantic/N-channel transports.

Semantic multichannel analysis data remains architecturally supported by `AmbientFieldAnalyzer`; PR89 does not fake stereo playback subtraction for an N-channel route if an exact source model is unavailable.

## Non-goals

- active anti-noise / quiet-zone generation
- MIMO cancellation
- hearing-safety certification
- automatic master-volume escalation without digital headroom
- fast compressor-like behavior
- cloud inference or opaque ML classification.

Active Quiet Zone work remains a later PR.
