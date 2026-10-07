# PR90 — Active Quiet Zone / Low-Frequency Active Noise Control

PR90 extends PR89's trusted ambient sensing into a bounded active-noise-control
system for predictable low-frequency environmental noise.

## Physics contract

The first production implementation deliberately targets **stable tonal and
quasi-periodic noise**, initially 25–150 Hz: HVAC hum, fan/motor tones,
transformer hum, and similar predictable components.

An error microphone located in the listening area cannot provide causal
feed-forward cancellation of arbitrary stochastic broadband noise: by the time
an unpredictable pressure fluctuation reaches the error microphone, a speaker
cannot send an earlier anti-wave back in time. PR90 therefore does not claim
whole-room or broadband ANC from a single error microphone.

Future broadband feed-forward ANC requires an upstream/reference microphone
with useful acoustic preview. PR90's runtime is designed so that reference
sensor can be added later.

## Relationship to PR89

PR89 remains the environmental sensing layer:
- live microphone capture
- exact rendered-playback reference
- speaker-to-microphone acoustic impulse responses
- mic/playback timing alignment
- environmental residual extraction
- stationarity / tonality / confidence analysis.

PR90 consumes only **trusted separated residual noise**. Audible program
material is never treated as a cancellation target.

PR89 perceptual masking compensation remains useful above the ANC band.
The intended hybrid is:
- 25–150 Hz: active cancellation where the noise is predictable and the plant
  is trustworthy.
- above the active band: PR89 perceptual masking compensation rather than
  physically unrealistic broadband room cancellation.

## Control strategy

PR90 uses narrowband complex adaptive cancellation.

For each accepted tone:
1. Estimate the external disturbance complex phasor from PR89's separated
   residual.
2. Evaluate the measured left/right (and later N-channel) secondary paths at
   the same frequency.
3. Solve a regularized least-energy inverse for source complex amplitudes.
4. Convert the desired acoustic phasor into the realtime oscillator's phase
   coordinate using a dedicated anti-noise reference stream plus PR89 timing
   alignment.
5. Apply bounded coefficient ramps.
6. Re-measure the physical error microphone.
7. Continue only while measured residual improves; otherwise fade to unity and
   latch a fault.

The controller never performs adaptive math in the audio callback.

## Phase / clock strategy

The microphone and output may use independent hardware clocks.

PR90 does **not** assume their sample zero or phase is shared. A dedicated
rendered anti-noise reference stream is aligned to the microphone using the same
bounded timing evidence developed in PR89. The controller measures the actual
generator phasor in that aligned output reference and uses it as the phase basis
for subsequent coefficient updates.

This makes fixed transport offset and slow clock drift observable instead of
silently corrupting cancellation phase.

## Initial acceptance gates

A component is eligible only when all are true:
- 25–150 Hz
- separated ambient evidence, not raw playback-contaminated microphone audio
- separation confidence >= 0.85
- stationarity >= 0.80
- tonal prominence >= 12 dB
- stable frequency across at least 4 analysis windows
- matching retained Room Correction source-to-monitor impulse responses
- microphone identity/channel/calibration provenance matches the acoustic model
- sample-rate compatibility
- usable anti-noise output headroom
- no active protection/fault condition.

## Output / headroom limits

Anti-noise is additive energy and must not bypass output protection.

The realtime generator is inserted upstream of dynamics/protection. Its output
is included in the final rendered playback reference.

Initial hard bounds:
- maximum 4 simultaneous tones
- maximum per-source tone peak: -24 dBFS
- maximum aggregate anti-noise peak per source: -18 dBFS
- 500 ms arm/update ramp
- 100 ms fault fade
- program + PR89 level recovery + worst-case anti-noise peak must remain <= the
  uncompensated full-scale boundary.

If the active Content Preset or PR89 consumes the required reserve, PR90
immediately reduces or disarms anti-noise before publishing the new graph.

## Closed-loop acceptance

Predicted cancellation is insufficient. The live error microphone is the commit
authority.

After a candidate is applied:
- require >= 1.0 dB measured reduction at the controlled component before
  escalating beyond probe level
- target useful reduction is 3–10 dB depending on source/room geometry
- any > 1.0 dB sustained increase at the target tone triggers a fault fade
- any non-finite data, model mismatch, timing-confidence loss, protection event,
  or frequency instability disarms the component
- no component can self-increase without a fresh measured improvement.

## Realtime architecture

A dedicated immutable Active Quiet Zone snapshot contains:
- up to 4 frequencies
- complex source coefficients
- ramp/fault state
- hard per-source and aggregate limits.

The realtime path performs only:
- oscillator phase advance
- coefficient smoothing
- bounded anti-noise synthesis
- additive injection before dynamics/protection
- anti-noise reference capture
- lock-free telemetry.

No FFT, matrix solve, acoustic modeling, allocation, logging, locks, or Swift
runs in the render callback.

## Stereo and multichannel scope

PR90 first makes the stereo production path live using left/right as independent
cancellation sources. The solver and data model remain source-generic so the
existing N-channel/MIMO room-treatment infrastructure can host additional
independent speakers/subwoofers in a later extension.

A stereo receiver whose subwoofer follows the stereo pre-out is treated as part
of the measured left/right secondary path, not as an independently controllable
subwoofer.

## User experience

Active Acoustics gains an **Active Quiet Zone** section showing:
- status: Observe / Eligible / Probing / Cancelling / Hold / Fault
- controlled tone frequency
- ambient tone before cancellation
- measured residual after cancellation
- achieved attenuation
- left/right anti-noise output level
- timing/separation confidence
- available anti-noise headroom
- reason for any hold/fault.

The user explicitly arms Active Quiet Zone. Ambient Compensation and Active
Quiet Zone remain independently bypassable.

## Non-goals

- no claim of whole-room silence
- no speech cancellation
- no cancellation of music/program material
- no single-error-mic broadband stochastic ANC
- no ultrasonic pilot
- no hidden always-on calibration signal
- no cloud/ML controller
- no bypass of dynamics, limiter, or speaker protection.
