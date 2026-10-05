# PR71 — Semantic N-Channel Adaptive SRC Activation

## Purpose

PR71 extends the PR69 adaptive clock / asynchronous sample-rate-conversion primitive, already activated for the production stereo transport by PR70, into Notch Sixty's semantic N-channel speaker path.

The design preserves semantic channel identity across conversion:

```text
Core Audio stream order
    -> explicit semantic reorder
    -> canonical N-channel ASRC
    -> PR54 per-channel lanes
    -> PR55 bass management / Sub N
    -> semantic-to-physical output map
    -> hardware
```

Rate conversion therefore never operates on guessed channel order or physical output numbering.

## Scope

PR71 activates adaptive SRC for the live semantic speaker transport when the program tap and a single selected physical output device expose different native rates.

The existing semantic multi-device output mode deliberately remains fail-closed on a pre-aggregate native-rate mismatch. That mode uses one HAL Aggregate Device as the output clock domain. Supporting a different tap-native clock there cleanly would require separating capture and output aggregate ownership, which is not introduced without real hardware acceptance.

Virtual Speakers / binaural transport is also outside this PR and remains a separate activation decision.

## Realtime architecture

The live N-channel bridge owns, after control-plane preparation:

- one PR69 `N60AdaptiveSRC` configured for the semantic program channel count;
- one preallocated canonical interleaved capture scratch buffer;
- one preallocated canonical interleaved output scratch buffer;
- the existing PR54/55 render runtime and output map.

The capture callback maps each Core Audio frame into the canonical semantic layout before staging it into the ASRC. The output callback pulls one complete output-rate semantic block before entering the existing render graph.

No allocation/free, blocking lock, logging, file/network I/O, device discovery, graph construction, or coefficient design occurs in either callback.

## Startup, drift, and relock

PR71 reuses PR70's production startup policy in the input clock domain:

- three output quanta of steady-state input headroom;
- two half-kernel look-ahead margins around the target;
- one additional input-equivalent output quantum plus half-kernel margin before opening the startup gate.

If the ASRC cannot produce a complete physical-output callback block:

- the callback emits silence for the complete hardware block;
- the consumer-only PI controller relocks to nominal;
- the semantic ring/source position remains intact;
- cumulative ASRC failure telemetry remains intact;
- the output gate closes;
- the startup fade is re-armed;
- output resumes only after a complete re-prime.

Partial converted blocks never enter PR54 lanes, PR55 bass management, metering, or the physical output map.

## Multichannel optimization

PR69 originally evaluated the same fractional-phase FIR coefficient separately inside every channel loop. PR71 hoists fractional coefficient interpolation to the tap loop and applies each shared coefficient across the complete semantic channel vector.

This materially reduces redundant work for layouts such as 7.1.4, 9.1.6, and custom layouts up to the current 32-channel semantic program ceiling while preserving independent per-channel sample histories.

## Diagnostics and latency

The existing Transport workspace receives the same adaptive telemetry used by PR70:

- input native sample rate;
- output native sample rate;
- live correction ppm;
- target buffered input frames;
- dropped input frames;
- starved output frames;
- controller saturation telemetry.

Semantic transport published latency now includes the adaptive transport buffering converted into output-domain frames in addition to the existing PR54/55 configured graph latency.

## Deterministic validation

Permanent PR71 validation covers:

- inherited PR69 sample-rate-conversion quality;
- inherited PR70 stereo activation remaining present;
- semantic reorder occurring before ASRC;
- callback realtime-safety guards;
- 6-channel, 7.1.4-class 12-channel, 16-channel, and 32-channel isolation;
- zero cross-channel leakage in the adaptive converter;
- independent per-channel level preservation;
- 32-channel +180 ppm source-clock drift;
- bounded buffer behavior without drops/starvation;
- a 32-channel CPU regression ceiling to catch order-of-magnitude performance regressions;
- arm64 macOS app build and retained XCTest suite.

The CI performance ceiling is a regression guard, not a claim that every 32-channel configuration has passed production hardware thermal/CPU acceptance.

## Relationship to PR70

PR70 remains the production stereo activation layer. PR71 does not replace its direct matched-rate path, startup policy, diagnostics, or failure behavior.

Both transports use the same independently implemented PR69 adaptive SRC primitive and the same fail-closed principle: a callback either receives a complete prepared block or emits silence and re-primes.

## Manual acceptance

Still pending real Mac / interface hardware:

- matched 44.1 / 48 / 96 kHz N-channel regression;
- 44.1 <-> 48 kHz semantic mismatch on a multichannel-capable single device;
- 5.1, 7.1, 7.1.4, 9.1.6, and larger custom semantic layouts where hardware permits;
- long-run independent-clock drift;
- startup, starvation, relock, and fade behavior;
- sample-rate change rebuilds;
- Stop/Start, unplug/replug, and sleep/wake;
- native LFE vs redirected bass and Sub N routing;
- real CPU/thermal/underrun behavior under 12/16/32-channel load;
- listening for channel swaps, pitch modulation, clicks, image movement, HF loss, or other SRC artifacts.

The existing multi-device aggregate-output path should also receive a matched-rate regression pass. Native-rate mismatch for that topology remains intentionally unsupported in PR71.

## Provenance / App Store

PR71 is clean-room proprietary work built on the current proprietary Notch Sixty architecture and the independently implemented PR69 primitive. No third-party SRC library, GPL implementation, private API, new entitlement, driver, helper, or network dependency is introduced.
