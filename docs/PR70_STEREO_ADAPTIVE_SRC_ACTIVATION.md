# PR70 — Stereo Adaptive Clock / ASRC Activation

## Purpose

PR70 activates the PR69 adaptive clock-domain and asynchronous sample-rate converter in the production **stereo** transport. A system-audio tap and selected physical output no longer have to expose the same native sample rate for ordinary stereo or same-device stereo speaker routing.

Matched-rate sessions retain the existing direct SPSC bridge unchanged. Semantic N-channel / Virtual Speakers activation remains deferred to **PR71**.

## Live transport policy

At session preparation, Notch Sixty compares the process-tap format with the selected output format.

- If the native rates match within 0.5 Hz, the existing stereo ring remains the production path.
- If the rates differ and capture/output are independent stereo clock domains, the bridge prepares PR69's 96-tap / 2048-phase adaptive SRC off realtime.
- If the legacy multi-device speaker route uses one HAL Aggregate Device for both capture and output, a native-rate mismatch still fails closed. That path already has a HAL-owned aggregate clock domain and must not be mixed with PR70's independent-clock assumptions.
- Semantic N-channel and binaural transports continue to fail closed on native-rate mismatch until PR71.

For an ASRC session, the private tap aggregate remains at the tap's native rate instead of being pinned to the output rate. The physical output callback continues at the selected device rate. The PR69 PI controller therefore sees the real producer/consumer clock relationship and can correct slow drift rather than hiding it behind an implicit platform conversion.

## Startup buffering

The normal startup gate remains in place.

For matched-rate sessions its policy is unchanged: two physical output callback quanta are buffered before opening, followed by the existing fade-in.

For an ASRC session the gate is expressed in **input-domain frames**. The target includes:

- two output callback quanta converted to input-domain frames;
- two PR69 half-kernel look-ahead margins;
- one additional callback quantum plus one look-ahead margin before initial gate opening.

This gives the symmetric interpolation kernel enough future support at startup and leaves the PI controller meaningful headroom around its steady-state target. The gate still outputs deterministic silence until ready and then uses the existing click-free startup fade.

## Realtime integration

PR70 adds no allocation, deallocation, blocking synchronization, logging, device discovery, or filter construction to either Core Audio callback.

Control-plane setup allocates:

- the PR69 adaptive SRC ring and immutable phase table;
- one bounded stereo capture scratch buffer;
- one bounded stereo output scratch buffer.

The capture callback converts supported interleaved or planar stereo Core Audio buffers into the preallocated interleaved scratch area and pushes one bounded block to PR69.

The output callback pulls one bounded interleaved output block from PR69, then feeds those samples through the existing production order:

```text
ASRC -> Content DSP / EQ / FIR / Dynamics
     -> optional headphone correction
     -> protection / output gain
     -> optional physical speaker-bus split / driver processing
     -> physical output
```

ASRC is therefore a transport-domain operation, not a Content Preset effect. DSP coefficient design continues to use the physical **output** sample rate.

## Diagnostics

The existing Transport page now reports an Adaptive SRC card while the stereo ASRC path is active:

- native input and output rates;
- live PI correction in ppm;
- target buffered input frames;
- dropped input frames;
- starved output frames.

The ordinary Buffered, startup-gate, underrun/overrun, recovery, selected-output, and render diagnostics remain available.

The bridge snapshot embeds the PR69 adaptive-SRC snapshot so diagnostics are read off realtime without constructing new callback-side state.

## Reset / relock behavior

PR70 does not attempt to rebuild a running SRC from an audio callback. Existing transport recovery remains the authority for device discontinuities, sample-rate changes, sleep/wake, unplug/replug, and explicit Stop/Start.

When a stereo bridge is reset on the control plane, the adaptive ring, fractional source position, PI integral/correction, and transport counters are reset together. The normal startup gate then re-primes before audio is emitted.

This is deliberately conservative: a discontinuity is treated as a new clock relationship rather than asking a stale adaptive controller to extrapolate through it.

## Deterministic validation

CI retains the PR69 DSP-quality harness and adds a PR70 transport simulation covering:

- 44.1 kHz capture -> 48 kHz output callback cadence;
- passband frequency and level preservation through callback-sized blocks;
- no drops or starvation after startup under nominal cadence;
- an independently drifting source clock at +220 ppm;
- correction moving in the expected direction while buffer fill remains bounded;
- explicit starvation telemetry;
- control-plane reset;
- re-prime and successful output after reset.

The PR70 structural validator also checks the actual Core Audio bridge/session glue and rejects callback allocation, free, blocking locks, logging, or accidental semantic N-channel activation.

## Manual validation

Hardware acceptance remains required before this stack is merged.

At minimum, the real-Mac pass should cover:

- 44.1 -> 48 kHz and 48 -> 44.1 kHz native-rate mismatch;
- 44.1 / 48 / 96 kHz matched-rate regression;
- any available 192 / 384 kHz device modes;
- long-run playback with independently clocked tap/output domains;
- startup silence and fade-in;
- Stop/Start and sample-rate rebuild;
- output-device unplug/replug;
- sleep/wake;
- underrun/overrun recovery;
- stereo headphone mode;
- same-device physical stereo speaker routing where safely connected;
- subjective checks for pitch stability, clicks, image shifts, HF loss, or modulation artifacts.

The legacy multi-device HAL Aggregate Device route should still reject a pre-aggregate native-rate mismatch in PR70.

## Scope boundary / next PR

PR70 does **not** activate ASRC in:

- semantic speaker playback;
- Virtual Speakers / binaural transport;
- multichannel calibration transport.

Those paths keep their existing native-rate fail-closed behavior.

**PR71** will reuse the same PR69 primitive for semantic N-channel transport and add multichannel performance / callback-load gates.

## App Sandbox / App Store impact

None. PR70 remains an in-process Core Audio + DSP change with no driver, helper, network access, filesystem capability, private API, or third-party dependency.
