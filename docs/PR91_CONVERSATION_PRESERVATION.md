# PR91 — Conversation Preservation and Unified Active Acoustics

## Purpose

Extend the PR89/PR90 Active Acoustics stack with an adaptive coexistence mode
for social listening: keep music present while reducing how strongly playback
masks nearby human conversation.

PR91 also turns PR89 and the new behavior into one mutually-exclusive playback
adaptation policy while keeping PR90 Active Quiet Zone independently selectable.

## User model

Playback Adaptation:
- Off
- Music Focus — PR89 behavior; preserve music under environmental masking
- Conversation Focus — PR91 behavior; let nearby speech win the masking contest

Active Quiet Zone remains a separate on/off capability and may operate with any
Playback Adaptation mode.

This intentionally permits the useful combination:

Conversation Focus + Active Quiet Zone

so playback yields to voices while stable 25–150 Hz mechanical/HVAC tones may
still be physically attenuated.

## Architecture

PR89 remains the shared sensing substrate:
- live microphone capture
- exact rendered playback reference
- measured playback-to-microphone model
- separated environmental residual
- calibrated/relative ambient level
- spectral analysis and confidence

The persisted PR89 configuration gains an optional playback-adaptation mode.
For migration, saved profiles without the new field map:
- legacy enabled=true -> Music Focus
- legacy enabled=false -> Off

Music Focus and Conversation Focus share one realtime adaptation overlay. They
cannot run simultaneously.

PR90 remains an independent additive anti-noise path.

## Conversation evidence

The first production policy is deterministic and explainable. It derives a
bounded conversation-evidence score from the separated residual using:
- energy concentration in the speech-critical band
- rejection/down-weighting of strongly periodic/tonal disturbances
- temporal/stationarity evidence that rejects isolated impulses
- ambient rise above the retained quiet baseline
- trusted modeled-playback separation while playback is active

This is an acoustic conversation detector, not speaker identification, speech
recognition, transcription, or content analysis.

Production false-positive policy:
- nonstationary/transient events such as applause, clatter, or dropped objects
  fail closed rather than triggering a music duck
- strongly tonal/periodic low-frequency disturbances are down-weighted
- speech-shaped residuals may remain eligible when a moderate HVAC/mechanical
  tone is also present
- speech-like program leakage is ineligible when modeled playback separation
  confidence falls below the configured threshold
- the detector never bypasses the existing playback-model trust requirement

No microphone audio is persisted by this feature.

## Playback policy

Conversation Focus never boosts overall playback.

As conversation evidence rises it may apply:
- bounded full-band attenuation
- additional broad attenuation around the speech/intelligibility region
- partial low-frequency restoration relative to the attenuation, preserving
  musical weight without exceeding unity gain
- partial high-frequency restoration relative to the attenuation, preserving
  ambience without exceeding unity gain

Initial hard intent:
- maximum full-band attenuation: 4 dB
- maximum additional presence carve: 3 dB
- no positive combined gain above the unadapted signal
- smooth onset/recovery; no PA-style hard ducking

The exact applied response is exposed in the UI.

## Safety and fidelity

- running playback requires trusted playback/environment separation
- low-confidence or invalid evidence fails toward unity
- Music Focus and Conversation Focus are mutually exclusive at the controller
  and persistence layers
- Conversation Focus may free digital headroom; it never consumes positive
  level-recovery headroom
- PR90 headroom accounting uses only positive playback-recovery gain
- all analysis/planning stays off the realtime thread
- realtime DSP consumes only prepared bounded snapshots

## UI

Active Acoustics exposes:

Playback Adaptation
[ Off | Music Focus | Conversation Focus ]

and a separate Active Quiet Zone on/off control with a link/detail surface.

Music Focus retains PR89 telemetry and exact response visualization.

Conversation Focus adds:
- Conversation Activity / evidence
- Applied Level
- Speech-band clearance
- exact live adaptation response
- hold/confidence diagnostics

Quiet Zone retains PR90 measured cancellation telemetry.

## Out of scope

- speech recognition or transcription
- identifying who is speaking
- broadband room ANC
- automatically choosing Conversation Focus without user opt-in
- multizone social-audio beamforming
