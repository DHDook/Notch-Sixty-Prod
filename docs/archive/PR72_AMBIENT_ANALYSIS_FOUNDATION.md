# PR72 — Passive Ambient Analysis Foundation

## Purpose

PR72 begins the active-acoustics / room-quieting roadmap with a deliberately passive estimator. It does **not** generate anti-noise, modify playback, adapt any realtime filter, or control speakers/subwoofers.

The goal is to answer a prerequisite question safely:

> What acoustic energy at the measurement microphone is plausibly environmental rather than caused by Notch Sixty's own known playback?

Only after that estimate is trustworthy should later PRs use it for ambient compensation, MIMO active room treatment, or an Active Quiet Zone.

## Inputs

The control-plane analyzer accepts:

- a microphone observation;
- zero or more semantic playback-source histories;
- one measured source-to-microphone impulse response per audible modeled source;
- the analysis sample rate;
- optional absolute microphone/SPL calibration.

The source model is intentionally semantic and multichannel-ready. Front Left, Front Right, Center, surrounds, heights, native LFE, and other program sources remain distinct until their predicted acoustic contributions are summed at the microphone.

## Playback rejection

For each modeled audible source:

1. the known playback history is convolved with its measured acoustic impulse response;
2. predicted source contributions are summed in the acoustic domain;
3. one bounded least-squares gain estimates residual microphone/path sensitivity mismatch;
4. the summed prediction is subtracted from the microphone observation;
5. analysis is performed on the residual field.

If playback is negligible, the microphone can be analyzed directly.

If **any audible playback source lacks an acoustic model**, separation fails confidence closed:

- separation mode becomes `playbackModelUnavailable`;
- the microphone signal is not claimed to be clean ambient residual;
- confidence is deliberately low;
- no inferred anti-noise/control action is produced.

This avoids treating music, dialogue, effects, or speaker leakage as environmental noise.

## Passive metrics

`AmbientAnalysisSnapshot` is the PR72 data/UI contract. It exposes:

- separation mode and confidence;
- fitted playback-prediction gain;
- microphone level in dBFS;
- modeled playback level in dBFS;
- residual ambient level in dBFS;
- optional calibrated dB SPL;
- 64-band logarithmic ambient spectrum;
- tonal-component frequency, level, and prominence;
- stationarity score;
- periodicity score and estimated periodic frequency;
- fraction of residual energy below the low-frequency control ceiling;
- ambient character classification;
- a bounded **cancellation-candidate score**.

The cancellation-candidate score is descriptive only. It is not an actuator command and is not consumed by a realtime output path in PR72.

## Spectral / temporal analysis

The analyzer is offline/control-plane Swift using Accelerate DFTs.

- Playback prediction uses frequency-domain convolution.
- Spectrum uses a Hann-windowed transform and logarithmic energy bands.
- Tone detection looks for local spectral maxima with neighborhood prominence.
- Periodicity uses Wiener-Khinchin autocorrelation from the residual spectrum.
- Stationarity compares residual RMS level across bounded time segments.
- Low-frequency suitability currently uses 250 Hz as the default upper control region, matching the conservative room-quieting direction.

Analysis windows are bounded. The production defaults cap the working window at 65,536 frames and the acoustic model at 8,192 taps.

## Confidence policy

PR72 intentionally separates "a residual can be computed" from "the residual should be trusted."

With modeled playback, confidence combines:

- stability of the fitted playback gain across time segments; and
- residual/reference decorrelation across those segments.

No audible playback model -> low confidence.

Negligible playback -> direct microphone analysis with high separation confidence, because no subtraction is required.

Future live work may add cross-window confidence hysteresis, microphone health, clock-coherence checks, spatial agreement across multiple error microphones, and model-aging detection.

## Realtime safety boundary

PR72 does not modify a Core Audio callback.

The analyzer:

- owns no IOProc;
- writes no output audio;
- creates no adaptive controller;
- does not update speaker/sub filters;
- does not run on the realtime render thread.

A later PR may feed it from bounded copied microphone/playback-history rings, using the same architectural pattern as `ProductionAnalysisWorker`. That future worker must keep DFT creation, convolution, statistics, and allocation off the callback.

## Existing infrastructure reused conceptually

PR72 is designed to consume artifacts already produced by Notch Sixty:

- PR40 room-measurement microphone infrastructure;
- room-correction impulse responses / transfer measurements;
- PR58/PR64 semantic speaker and subwoofer calibration identities;
- PR69–71 clock-domain work;
- PR39-style off-realtime analysis ownership.

No live measurement transport is activated by this PR.

## Synthetic acceptance

The XCTest suite validates:

- stable 60 Hz HVAC-like tonal/periodic noise;
- known playback contamination passed through a measured impulse response;
- recovery of an independent 83 Hz ambient tone after playback subtraction;
- two semantic playback sources summed in the acoustic domain;
- fail-closed behavior when one audible semantic source lacks a model;
- negligible-playback microphone-only behavior;
- steady versus burst/nonstationary noise;
- preference for stable low-frequency versus high-frequency energy in the descriptive candidate score;
- optional dBFS -> dB SPL calibration;
- malformed/non-finite input rejection.

## Deferred live / hardware acceptance

When a Mac, microphone, and physical playback system are available, follow-on work should validate:

- continuous microphone capture while normal program audio is playing;
- alignment between playback-history and microphone clock domains;
- measured IR model accuracy across volume changes;
- residual quality with stereo and multichannel content;
- microphone calibration and absolute SPL;
- HVAC, fan, road/traffic, appliance, and other real ambient sources;
- confidence behavior when people move or doors/windows change the acoustic path;
- long-run model drift;
- multiple error/reference microphones.

## Explicit non-goals

PR72 does not implement:

- ambient-compensation EQ;
- filtered-x LMS / FxLMS;
- adaptive cancellation filters;
- MIMO active room treatment;
- speaker-generated anti-noise;
- Active Quiet Zone;
- Precision Quiet Seat.

Those features should consume this passive analysis layer only after their own stability, causality, excursion, limiter, failure-detection, and acoustic-safety gates exist.

## Provenance / App Store

PR72 is clean-room proprietary work based on standard signal-processing techniques: linear convolution, least-squares scalar fitting, DFT spectral analysis, autocorrelation, and statistical stationarity measures. It introduces no third-party DSP dependency, private API, driver, helper process, entitlement, network access, or new microphone permission. The existing measurement-microphone permission remains unchanged.
