# Architecture

How Notch Sixty is built on `main` today, and where the v1 program (`docs/PROGRAM_PLAN.md`) takes it.
The stereo render kernel is described in `docs/DSP_KERNEL.md`; realtime rules are in
`docs/REALTIME_RULES.md`.

## Goals

- Public Core Audio APIs only: no HAL driver, privileged helper or system extension.
- App Sandbox and Mac App Store from day one (`docs/APP_STORE_REQUIREMENTS.md`). Minimum macOS 26.
- A control plane (Swift, may block) kept strictly apart from the render plane (C today, may never
  block).
- The selected physical output, identified by its stable UID, is authoritative.
- Native device rates up to 384 kHz with no hidden transport SRC. Every feature works at every rate.
- Every DSP stage declares its latency.

## Layers

| Layer | Where | Role |
|---|---|---|
| App and UI | `NotchSixtyApp.swift` (`NotchSixtyApp`, `ProductController`), `UI/` | SwiftUI views and the product model |
| Control plane | `Audio/AudioIOEngine.swift`, `State/` | Lifecycle, device selection, transport build/teardown, recovery, graph compilation |
| Core Audio transport | `Audio/CoreAudio/` | Process tap, aggregate device, IO procs, measurement and reference transports |
| Render plane | `Audio/Realtime/` (`N60*.c/.h`) | Realtime bridge, render kernels, ANC and MIMO runtimes, AU rack exchange |
| Gates and evidence | `Acceptance/` | Hardware acceptance, authorisation of hardware-gated features |
| Devices and routing | `Audio/Devices/`, `Audio/Routing/` | Output catalogue, route, output and headphone profiles |

## Control-plane state machine

`AudioLifecycleState` (`State/AudioLifecycleState.swift`):

```text
Idle → RequestingPermission → CreatingTap → CreatingAggregate → OpeningOutput → Starting → Running
Running → Reconfiguring → (rebuild) → Running
Running → RecoveringOutput → (same UID returns) → Running
any → Stopping → Idle        any → Failed
```

`AudioLifecycleStateMachine` rejects illegal edges (`AudioLifecycleTransitionError`); `AudioIOEngine`
drives it through `setLifecycle(_:)`.

- **Reconfiguring:** intentional changes, such as a nominal sample-rate change. The engine tears the
  transport down and rebuilds it at the new rate, and detaches an Audio Unit rack that can't run at
  that rate.
- **RecoveringOutput:** the selected device (or the spatial source device) disappeared. The engine
  stops transport and retries with backoff, guarded by a recovery generation, until the **same UID**
  returns. It never falls back to another device or follows a later macOS default-output change.
- Sleep and wake are handled explicitly. Normal Quit fades out, stops, then destroys the private tap
  and aggregate. A force-quit can't run cleanup, but the private tap and aggregate must not leave
  system audio wedged.

## Transport

```text
Other applications
    ↓
Device-scoped private process tap        (AudioHardwareCreateProcessTap)
    ↓
Private aggregate device                 (AudioHardwareCreateAggregateDevice)
    ↓  capture IO proc (tap clock domain)
Realtime bridge                          (N60RealtimeAudioBridge: lock-free SPSC)
    ↓  output IO proc (device clock domain)
Render kernel / N-channel render core
    ↓
Selected physical output
```

The bridge carries audio between the capture and output clock domains. When the tap and device rates
match, it is a direct single-producer/single-consumer ring. When they differ, the bridge's adaptive
SRC (`N60AdaptiveSampleRate`) tracks clock drift and converts to the device's native rate; this is an
explicit, configured stage, never a hidden one.

## Which path runs

`AudioIOEngine.buildTransport(output:)` picks one transport session per start:

| Configuration | Session | Render path |
|---|---|---|
| Headphone profile, virtual-speaker mode | `CoreAudioBinauralHeadphoneTransportSession` | Binaural renderer (HRTF/SOFA), head-tracking runtime |
| Headphone profile, stereo mode | `CoreAudioTransportSession` | Stereo kernel with headphone DSP (correction, crossfeed) |
| Output-device (speaker) profile | `CoreAudioNChannelTransportSession` | N-channel render core: program layout, lanes, bass management, output map |
| Neither | `CoreAudioTransportSession` | Stereo kernel |

A headphone profile and a speaker profile can't both be active. The N-channel path refuses to start
while stereo-only DSP is active (for example the legacy speaker IR or single-sub phase alignment)
rather than silently dropping it. Program layouts reach 32 channels and 40 physical outputs
(`N60ProgramLayout.h`, `N60LiveNChannelRenderCore.h`).

Measurement and calibration transports (`RoomCorrectionCalibrationTransport`,
`MultichannelCalibrationTransport`, `AmbientMonitorTransport`, `FeedForwardReferenceTransport`) are
kept apart from program playback because they drive controlled excitation or microphone capture.

## Getting settings to the render thread

1. Swift compiles settings into an immutable render-ready snapshot off the realtime thread, for the
   device's actual rate (for example `LiveNChannelRenderGraphCompiler.makeGraph` for N-channel).
   Filters and FIR programs are built here, never on the render thread.
2. The snapshot goes into a preallocated inactive slot, and an atomic swap publishes it with a new
   generation (`N60RenderKernelPublishSnapshot`; FIR programs via the `Prepare…Program` calls).
3. Each hardware buffer pins one snapshot from start to end, so a buffer never mixes two generations.

Feature flags (`State/FeatureFlags.swift`, `docs/FEATURE_FLAGS.md`) are read only in Swift. The
engine never sees a flag: Swift decides and publishes a configuration through the same snapshot path,
so the core stays flag-free and portable.

## Audio Unit rack

The host (`AudioUnitHostController`, `AudioUnitLiveRackRuntime`, `AudioUnitLiveRackSwitchboard`)
loads and prepares Audio Units off the realtime thread. On the render thread, the rack runs between
the stereo kernel's playback half and its system half, so speaker, room and protection processing
always follow third-party plug-ins. `N60AudioUnitLiveRackBridge` and `N60AudioUnitRackExchange`
exchange the prepared rack with the render thread without locks, and contain a faulting or
incompatible unit instead of letting it reach the output.

## Hardware-gated paths: ANC and MIMO

Speaker ANC (Quiet Zone) is the flagship differentiator. It and live MIMO room treatment can emit
energy into a room, so each has one written authorisation path and defaults to off.

- **Live feed-forward ANC.** Authorised only by a passing hardware-acceptance status
  (`Acceptance/HardwareAcceptance.swift`, `liveFeedForwardANCAuthorized`). Until then, commissioning,
  survey, shadow and rehearsal stages run, but `liveANCQualified` stays false. Runtime:
  `N60ActiveQuietZone`, the `N60FeedForward*` bridges, and `QuietZone*.swift`.
- **Live MIMO room treatment.** Needs a `MIMORoomTreatmentActivationPermit`, which is created only
  when its gate reports eligibility and must match the accepted profile, the selected output UID and
  the sample rate. Runtime: `N60MIMOTreatmentTransition`, `N60MIMOTreatmentLiveIntegration`,
  `N60MIMOFIRRuntime`.

Never enable either live path outside these authorisation paths (`CLAUDE.md`).

## Where the program takes it

- **E6:** one unified live N-channel graph, in C++, replaces the stereo kernel and the N-channel core.
  Stereo becomes a two-channel layout and the binaural renderer becomes a stage, not a separate
  transport. Every lane gets the full stereo stage set, and the `unsupportedActiveDSP` restrictions go.
- **E7:** buffers sized in time for the 384 kHz worst case, the remaining frame caps lifted, and
  double-precision filters where float32 loses low-frequency accuracy at high rates.
- **E20:** whole-buffer processing, multirate low-frequency paths, multiple realtime threads (Audio
  Workgroups), portable SIMD, an enforced CPU budget.
- **E21:** the engine core moves to C++20/23 behind one versioned C interface, with no Apple framework
  dependency (an FFT abstraction: vDSP on Apple, a BSD-licensed FFT elsewhere). Swift stays for the
  app shell, Core Audio control and UI.
- **E4 / E19:** ANC and MIMO qualification on hardware; their authorisation paths stay the only way
  to go live.
