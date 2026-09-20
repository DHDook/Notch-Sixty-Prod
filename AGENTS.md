# AGENTS.md

These rules apply to all human and automated contributors, including Codex and other coding agents.

## 1. Clean-room rule is mandatory

This repository is a fresh proprietary implementation.

Do **not** copy, import, transliterate, adapt, cherry-pick, or mechanically reproduce source expression from the historical GPL Notch Sixty / Equaliser repository or its upstream history. Do not import its tests, scripts, Xcode project, resources, presets, assets, generated files, or configuration unless a specific item has first been independently cleared and documented in `docs/PROVENANCE.md`.

Do not use the historical GPL repository as a coding reference while implementing commercial source. Implement behavior from public specifications, Apple documentation, independently written design notes, and testable product requirements.

The separate CoreAudioTapPOC-N60 repository is owner-authored clean-room validation work. Treat it primarily as behavioral and architectural evidence. Source reuse from the POC is **not automatic**: reuse requires an explicit provenance note and a deliberate review that the code is suitable for production rather than experimental scaffolding.

If provenance is uncertain, stop copying and reimplement from specification.

## 2. Product scope

The product is a macOS DSP application for stereo speakers plus a subwoofer.

In scope:
- stereo playback
- bass management
- subwoofer integration
- room correction
- multi-seat measurement/averaging
- EQ, FIR, convolution, crossovers, dynamics, metering, and related loudspeaker DSP

Out of scope unless explicitly approved:
- headphone-only processing
- headphone crossfeed
- actual multichannel output
- surround rendering
- driver installation
- privileged helpers
- kernel/system extensions

Do not confuse multi-seat room correction with multichannel audio.

## 3. Transport architecture

Use public Core Audio APIs and the driverless process-tap architecture.

Expected flow:

```text
Other applications
    ↓
Device-scoped private Core Audio process tap
    ↓
Private aggregate/tap input path
    ↓
Realtime bridge
    ↓
RenderKernel / DSP graph
    ↓
Explicitly selected physical output device
```

The selected physical output is authoritative. Do not silently follow a later macOS default-output change and do not silently fall back to another device if the selected device disappears. Recovery should wait for the same stable device UID unless product requirements explicitly change.

The transport layer must not impose a fixed 44.1/48/96 kHz whitelist. It must remain native-rate and support device-exposed rates through 384 kHz. Do not add SRC simply to hide a transport mismatch; SRC must be an explicit DSP/product decision.

## 4. Realtime rules

The audio callback must never:
- allocate or free memory
- take blocking locks
- perform disk or network I/O
- log
- touch SwiftUI, Observation, Combine, or AppKit state
- spawn tasks
- await async work
- construct or destroy filters/graphs
- parse files or JSON
- perform device discovery

Build immutable or preallocated processing state off the realtime thread and atomically swap it into the render path.

Any new realtime component must document:
- allocation behavior
- synchronization behavior
- latency
- sample-rate assumptions
- channel-count assumptions
- reset behavior

See `docs/REALTIME_RULES.md`.

## 5. Lifecycle and recovery

Use an explicit control-plane state machine. Production states should distinguish normal reconfiguration from hardware failure recovery.

Target states:

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

Normal Quit must stop/fade audio before teardown. A true force-quit cannot rely on application cleanup, but it must not leave system audio wedged.

## 6. App Store constraints

App Sandbox is required from the beginning. Do not introduce architecture that depends on:
- root privileges
- Authorization Services
- installing HAL drivers into `/Library/Audio/Plug-Ins/HAL`
- restarting `coreaudiod`
- self-updaters in the App Store build
- writing outside permitted sandbox/user-selected locations

See `docs/APP_STORE_REQUIREMENTS.md`.

## 7. Dependencies

Prefer Apple frameworks and small independently implemented DSP primitives.

Before adding a third-party dependency:
1. justify why it is needed;
2. verify the license is compatible with proprietary Mac App Store distribution;
3. add it to `THIRD_PARTY_NOTICES.md`;
4. add provenance information to `docs/PROVENANCE.md`;
5. consider whether the dependency is safe on a realtime path.

Do not add GPL/AGPL dependencies to production targets.

## 8. Testing

Every audio-path change should include deterministic tests where possible and identify required hardware/manual validation.

No audio architecture change is considered complete solely because it compiles.

Regression requirements include:
- 44.1 / 48 / 96 kHz
- high-rate native operation through available device rates up to 384 kHz
- live nominal-rate changes
- device unplug/replug
- sleep/wake
- permission lifecycle
- selected-device policy
- Stop/Start
- normal Quit
- force-quit recovery
- long-run transport/resource stability

See `docs/TEST_STRATEGY.md`.

## 9. Quality rule

When touching code, improve the design rather than reproducing legacy structure. Do not recreate old type names, routing hierarchies, or store architecture simply because the historical application used them.

Prefer small explicit components, narrow responsibilities, deterministic state transitions, and testable boundaries.

## 10. Pull requests

Each substantial PR should state:
- purpose
- architecture impact
- realtime impact
- provenance/source-of-truth
- tests added/run
- manual validation required
- App Sandbox/App Store impact

If a PR introduces DSP math, cite the public specification or derivation used to implement it.
