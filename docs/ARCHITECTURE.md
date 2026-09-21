# Architecture

## Goals

Notch Sixty is a native macOS stereo DSP application for loudspeakers plus subwoofer, designed for a proprietary Mac App Store distribution.

Primary architectural goals:
- public Core Audio APIs only
- no installed HAL driver
- App Sandbox from day one
- explicit separation between control plane and realtime render plane
- selected physical output by stable device UID
- native sample-rate transport through device-exposed rates up to 384 kHz
- no hidden transport SRC
- modular DSP graph with explicit latency

## High-level flow

```text
System applications
      ↓
Device-scoped private process tap
      ↓
Private aggregate/tap input
      ↓
AudioIOEngine
      ↓
RealtimeBridge
      ↓
RenderKernel
      ↓
DSPGraphSnapshot
      ↓
Selected physical output
```

## Production components

### AudioIOEngine
Owns control-plane Core Audio lifecycle, device selection, tap/aggregate creation, output opening, listeners, reconfiguration, recovery, and teardown.

### RealtimeBridge
Preallocated lock-free transfer between capture and output clock domains. It exposes bounded counters and never performs control-plane work.

### RenderKernel
Owns the realtime rendering contract. It acquires one atomically published render-ready graph snapshot per physical-output hardware buffer and uses that immutable generation for the complete callback. Realtime snapshot acquisition is bounded and never waits; graph publication is control-plane-only.

The current PR #12 reference graph is deliberately transparent:

```text
InputGain → IdentityReferenceStage → OutputGain
```

It has zero algorithmic latency at unity gain. NaN/Inf and denormal values are contained at the render boundary and diagnosed. See `docs/DSP_KERNEL.md`.

### DSPGraphSnapshot
A render-ready graph state assembled off the realtime thread and copied into preallocated publication slots. The foundation snapshot carries sample rate, stereo channel count, input/output gain, bypass, latency, and generation metadata.

Planned substantive stages include:

```text
InputGain
EQProcessor
CrossoverProcessor
RoomCorrectionProcessor
ConvolutionProcessor
DynamicsProcessor
OutputGain
MeterTap
```

Stages may be absent/bypassed. Every stage declares latency and supported channel/rate constraints. Richer future graphs must preserve the current render-safe publication and lifetime contract.

## Lifecycle

```text
Idle
RequestingPermission
CreatingTap
CreatingAggregate
OpeningOutput
Starting
Running
Reconfiguring
RecoveringOutput
Stopping
Failed
```

`Reconfiguring` covers intentional changes such as nominal sample-rate changes. `RecoveringOutput` covers disappearance/reappearance of the selected physical device.

## Output policy

The explicitly selected output device is authoritative. A macOS default-output change must not silently move the session. If the selected device disappears, stop transport safely and wait for the same stable UID rather than silently falling back.

## Shutdown

Normal termination should ramp output to zero over a short bounded interval, stop output and capture, destroy private Core Audio resources, then allow process termination. Abrupt force-quit cannot depend on cleanup code; the architecture must still allow normal system audio to recover externally.

## Future DSP

Substantive DSP implementation should be based on public math/specifications and clean provenance. Multi-seat correction is measurement/optimization logic and must not introduce an actual multichannel playback architecture.
