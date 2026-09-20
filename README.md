# Notch Sixty

Private commercial implementation of **Notch Sixty**, a macOS stereo DSP application for loudspeaker + subwoofer playback.

This repository is a fresh proprietary codebase. It is not a fork of the historical GPL-licensed Notch Sixty / Equaliser repository and must not import that repository's source, history, tests, scripts, project files, assets, or configuration.

## Current status

**Commercial bootstrap / architecture foundation.**

The driverless Core Audio transport architecture has already been validated separately in the CoreAudioTapPOC-N60 proof of concept, including native transport through 384 kHz, live sample-rate rebuilding, selected-device persistence, USB reconnect, sleep/wake, permission transitions, failure-safe restoration, and extended high-rate soak testing.

The POC is architectural evidence, not a production dependency. The commercial implementation should be independently structured and production-hardened.

## Product boundaries

- macOS only
- Apple Silicon
- two-channel loudspeaker playback
- subwoofer support through bass management
- multi-seat room correction is in scope
- actual multichannel output is out of scope
- headphone-only features are out of scope
- native device sample rates through 384 kHz where the selected hardware exposes them
- no hidden sample-rate conversion in the transport layer
- Mac App Store compatibility is a first-class constraint

## Architectural direction

```text
System applications
        ↓
Core Audio device-scoped process tap
        ↓
AudioIOEngine
        ↓
Realtime bridge
        ↓
RenderKernel
        ↓
DSPGraphSnapshot
        ↓
Selected physical output
```

The realtime path must remain allocation-free, non-blocking, and independent of UI/application state machinery.

## Repository policy

Read `AGENTS.md` before making code changes. It contains mandatory clean-room, realtime, product-scope, and review rules.

Key design documents live in `docs/`:

- `ARCHITECTURE.md`
- `REALTIME_RULES.md`
- `CLEAN_ROOM_POLICY.md`
- `PROVENANCE.md`
- `APP_STORE_REQUIREMENTS.md`
- `TEST_STRATEGY.md`
- `ROADMAP.md`
- `XCODE_BOOTSTRAP.md`

## Licensing

The commercial source in this repository is proprietary. See `LICENSE`.

Third-party components must be approved, provenance-tracked, and listed in `THIRD_PARTY_NOTICES.md` before they are introduced.
