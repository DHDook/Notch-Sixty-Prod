# PR69 — Adaptive Clock + Asynchronous SRC Foundation

## Purpose

PR69 establishes the reusable transport primitive needed for future adaptive clock-domain management and asynchronous sample-rate conversion (ASRC). It is **foundation only**: there is **no live transport activation** in this PR. Existing stereo and semantic N-channel transports continue to fail closed when the process-tap and selected output device expose different native sample rates.

This separation is deliberate. Sample-rate conversion is a material audio-path decision, and Notch Sixty should not silently change live playback until the resampler quality, controller stability, callback integration, telemetry, and hardware behavior can be accepted independently.

## Architecture

`N60AdaptiveSampleRate` combines two small components:

1. A bounded PI adaptive-clock controller that observes buffered-frame error and produces a slowly varying correction in parts per million (ppm).
2. A channel-agnostic band-limited sample-rate converter using a precomputed Kaiser-windowed sinc phase table with interpolation between adjacent phases.

The nominal source-position increment is:

```text
input sample rate / output sample rate
```

The adaptive controller applies only a very small correction around that nominal ratio:

```text
effective step = nominal step × (1 + correctionPPM × 1e-6)
```

A positive buffer error increases source consumption; a negative error reduces it. Correction is bounded, slew-limited, and uses integral anti-windup so a long disturbance cannot leave the controller stuck at a large correction after the buffer recovers.

The default interpolation kernel is 64 taps with 2048 precomputed fractional phases and linear interpolation between adjacent phase rows. The low-pass cutoff is reduced when downsampling so frequencies above the destination Nyquist limit are rejected rather than folded into the audible band. The same primitive accepts arbitrary positive nominal rates, including the product requirement for device-exposed operation through **384 kHz**.

## DSP derivation / public source of truth

The implementation is independently written from standard band-limited interpolation theory. The core derivation is Shannon reconstruction evaluated at new sample times, approximated with a finite windowed-sinc kernel. Public reference:

- Julius O. Smith III, *Physical Audio Signal Processing*, “Windowed Sinc Interpolation”: https://www.dsprelated.com/freebooks/pasp/Windowed_Sinc_Interpolation.html
- Smith & Gossett, “A Flexible Sampling-Rate Conversion Method,” ICASSP 1984, bibliographic reference: https://www.dsprelated.com/freebooks/sasp/PARSHL_Program.html

No third-party source code or resampling library is copied, adapted, linked, or added as a dependency.

## Realtime contract

### Allocation

`N60AdaptiveSRCCreate` allocates the SPSC input ring and immutable phase table on the control plane. `N60AdaptiveSRCDestroy` frees them on the control plane. `N60AdaptiveSRCReset` clears preallocated state and is also control-plane only.

`N60AdaptiveSRCPushInterleaved` and `N60AdaptiveSRCPullInterleaved` perform **no allocation or deallocation**.

### Synchronization

The streaming boundary is single-producer / single-consumer. Producer publication and consumer reclamation use C11 atomics. Creation fails if the atomic types used by the realtime boundary are not lock-free on the current architecture. There are no mutexes, blocking locks, dispatch calls, logging calls, file I/O, or device discovery in Push/Pull.

### Latency

The symmetric interpolation kernel requires future samples. Algorithmic look-ahead is `tapCount / 2` input frames (32 frames with the default 64-tap kernel), in addition to whatever target transport buffering a later activation PR selects.

### Sample-rate assumptions

The kernel does not impose a 44.1/48/96 kHz whitelist. Configuration accepts arbitrary finite positive rates and is validated in CI for conventional conversion and high-rate operation through 384 kHz. Live transport policy remains unchanged in PR69.

### Channel-count assumptions

The primitive supports 1–40 interleaved channels, matching Notch Sixty's physical channel ceiling. A future semantic integration can therefore use the same math without inventing separate stereo and multichannel resamplers.

### Reset / relock

Reset clears the preallocated ring, fractional source position, PI integral, correction, and transport counters. Later activation PRs will call reset/relock only from the control plane after discontinuity, device recovery, or explicit transport reconfiguration.

## Quality and deterministic validation

Portable C validation covers:

- valid high-rate configuration through 384 kHz;
- 44.1 → 48 kHz sine frequency and passband-level preservation;
- 48 → 44.1 kHz conversion;
- anti-alias rejection when downsampling 48 → 32 kHz;
- bounded/slew-limited PI behavior;
- controller saturation telemetry and reset behavior;
- lock-free atomic requirement;
- frame/counter and latency contracts.

A structural validator additionally rejects allocation, deallocation, blocking-lock, and logging calls inside the realtime Push/Pull functions and verifies that the shipping stereo and N-channel mismatch guards are still present.

## Planned activation stack

- **PR69:** reusable ASRC + adaptive-clock foundation only.
- **PR70:** stereo transport activation, startup buffering, diagnostics, failure/relock behavior, and deterministic callback simulation.
- **PR71:** semantic N-channel activation using the same primitive, including multichannel performance gates.

This sequence keeps shipping behavior reversible while the most consequential transport change since the clean-room rewrite is validated in layers.

## Manual validation

No listening/hardware behavior changes in PR69, so there is no new hardware acceptance gate for this foundation itself. The later activation PRs require manual validation at minimum for **44.1 / 48 / 96 kHz**, high-rate device operation when exposed, mismatched tap/output nominal rates, long-run independent-clock drift, live nominal-rate changes, device unplug/replug, sleep/wake, Stop/Start, and underrun/overrun recovery.

## App Sandbox / App Store impact

None. PR69 uses no privileged API, driver, helper, network service, filesystem access, or third-party dependency. It is a private in-process DSP primitive and is not yet invoked by production transport.
