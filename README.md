# Notch Sixty

Private commercial implementation of **Notch Sixty**, a macOS DSP platform for
speaker, subwoofer, multichannel, headphone/binaural, room-acoustic, plug-in,
and Active Acoustics workflows.

This repository is a fresh proprietary codebase. It is not a fork of the
historical GPL-licensed Notch Sixty / Equaliser repository and must not import
that repository's source, history, tests, scripts, project files, assets, or
configuration.

## Current status

**PR109 — Remote Integration & Stack Consolidation (draft, stacked).**

The clean-room rewrite and cumulative remote/software feature implementations
are complete through PR108, including Speaker Optimizer PEQ/FIR, advanced
Measurement Lab, and coherent Main/Sub alignment. PR109 is integrating their
cross-feature ownership, regression and release contracts. The PR109 branch is
stacked on PR108; existing feature PRs deliberately remain open, draft and
unmerged while the owner is away from the Mac.

The earlier **PR102 integration and commercial-release preparation** delivered
the remote release-candidate foundation. That milestone did **not** satisfy
physical hardware/acoustic acceptance, production signing, TestFlight/App
Review or public-release authorization. Those remain later gates, as does
live speaker-connected feed-forward ANC safety qualification.

Upcoming roadmap milestones: PR110 advanced speaker/subwoofer placement,
PR111 automatic protected per-driver correction, PR112 physical acceptance,
PR113 UX polish, PR114 commercial release-candidate preparation.

## Current product boundary

- macOS only
- Apple Silicon
- driverless Core Audio process-tap transport using public Apple APIs
- native device rates through 384 kHz where selected hardware exposes them
- stereo and approved semantic N-channel program layouts
- speaker/subwoofer playback, bass management, active-crossover and
  multichannel calibration paths
- headphone profiles, binaural/virtual-speaker rendering, SOFA/HRTF import, and
  head-tracking foundations
- multi-seat room correction, target/FIR design, speaker calibration, room
  treatment analysis/design, and ambient compensation
- Audio Unit hosting with fault-containment boundaries
- Active Acoustics / Quiet Zone foundations with commissioning, evidence and
  safety workflows
- **speaker-connected feed-forward ANC remains hardware-gated and unauthorized
  until the required physical acceptance campaign passes**
- App Sandbox and Mac App Store compatibility remain first-class constraints
- no privileged installer, HAL driver install, root helper, kernel/system
  extension, or App-Store self-updater requirement

Proprietary object/bitstream decoders such as Dolby Atmos decoding are not
included without a separate licensing/product decision.

## Architecture

```text
System applications
        ↓
Core Audio device-scoped process tap
        ↓
AudioIOEngine / semantic transport
        ↓
Realtime bridge
        ↓
RenderKernel / DSP graph
        ↓
Selected physical output(s)
```

Measurement/calibration transports are deliberately isolated from normal
program playback where they require controlled excitation or microphone
capture.

The realtime path must remain allocation-free, non-blocking, and independent
of UI/application state machinery.

## Release boundary

Remote CI can validate source/configuration correctness, deterministic DSP,
build/package integrity, resource/dropout behavior, sandbox metadata, and
fail-closed safety contracts.

It cannot substitute for real hardware evidence such as:

- device unplug/replug;
- sleep/wake and clock reacquisition;
- prolonged thermal/endurance playback;
- speaker/emergency-mute safety;
- final acoustic acceptance; or
- physical feed-forward ANC qualification.

Likewise, ad-hoc CI signing is not production App Store or Developer-ID signing.

## Repository policy

Read `AGENTS.md` before making code changes. It contains mandatory clean-room,
realtime, product-scope, dependency, and review rules.

Key design documents live in `docs/`:

- `ARCHITECTURE.md`
- `REALTIME_RULES.md`
- `CLEAN_ROOM_POLICY.md`
- `PROVENANCE.md`
- `APP_STORE_REQUIREMENTS.md`
- `TEST_STRATEGY.md`
- `ROADMAP.md`
- `PR102_INTEGRATION_COMMERCIAL_RELEASE.md`

## Licensing

The commercial source in this repository is proprietary. See `LICENSE`.

Approved third-party production components must be provenance-tracked and
listed in `THIRD_PARTY_NOTICES.md`. The shipping application also carries its
required redistribution notices as bundled product material.
