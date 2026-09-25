# Provenance

This document records the implementation provenance of the commercial Notch Sixty codebase. It complements `AGENTS.md` and `docs/CLEAN_ROOM_POLICY.md`.

## Rules

- GPL-derived or inherited implementation is not copied, adapted, transliterated, cherry-picked, or mechanically reproduced.
- Inherited behavior is independently implemented from observable behavior, public specifications, Apple documentation, independently derived DSP math, and commercial product requirements.
- Later owner-authored/current-only code is only reusable after lineage, ownership, architecture, realtime-safety, and quality review.
- Assets, generated materials, presets, metadata, and third-party dependencies require separate provenance/license review.
- When provenance is uncertain, reimplement from specification.

## Commercial implementation ledger

### Foundation and transport

The commercial repository, Xcode shell, sandbox configuration, CI, Core Audio device selection, driverless process-tap transport, realtime bridge, startup/recovery behavior, and hardware packaging workflow were implemented independently for this repository from product requirements and public Apple APIs.

### Realtime DSP graph

The commercial realtime graph, immutable snapshot publication, gain/headroom stages, meters, parametric EQ, channel-aware stereo EQ, bass-management crossover, FIR convolution, linear-phase EQ, room-correction runtime/control plane, balance, global bypass/Flat audition, and master playback gain are original commercial implementations. DSP equations and algorithms use public specifications, standard signal-processing derivations, and independently written tests/reference behavior.

### Product state and stereo playback controls

`ProductController`, versioned product configuration, linked/independent stereo EQ state, editing-channel state, balance, global bypass/Flat audition, and associated compatibility boundaries were implemented independently for the commercial architecture. No inherited preset/store/volume-management source expression is used.

### PR #24 master volume, mute, and keyboard control

PR #24 is an independent commercial implementation. Historical GPL/inherited volume-management or virtual-driver source was not used as an implementation reference.

The implementation uses public Core Audio HAL property discovery and listeners when the user-selected physical output exposes writable device volume/mute. For fixed-volume physical outputs, the existing commercial realtime software-master stage remains authoritative and a passive public IOKit HID listener observes Consumer Control Volume Increment/Decrement usages. The HID path does not seize, suppress, synthesize, or repost keyboard events and is enabled only for the software-volume fallback. macOS Input Monitoring permission is treated as a separate keyboard-control capability rather than an audio-route prerequisite.

This design intentionally does not reproduce the legacy virtual/HAL driver architecture. The selected physical output UID remains authoritative, and the fallback is implemented inside the sandboxed commercial app using public platform APIs.

## Candidate owner-authored legacy/current-only code

The following historical/current-only components may be candidates for deliberate migration only after commit-lineage, authorship, third-party reference, architecture, realtime-safety, and quality review. Presence in this list is not clearance to copy:

- `LookAheadLimiter.swift`
- `LoudnessMatchProcessor.swift`
- `StereoWidener.swift`
- `EQHeadroomCompensator.swift`
- `AdaptiveExcessPhaseCorrector.swift`
- `FractionalDelayLine.swift`
- `OversamplingProcessor.swift`
- `RoomCorrection*`
- sample-rate conversion processor(s)
- newer crossover/speaker utilities and crossover engines

## Known inherited/GPL-path areas

Historical preset management, volume-management paths, and portions of old EQ configuration/store/routing are treated as inherited/derivative paths and must be independently replaced from behavior/specification rather than source expression.

## Release gate

Before commercial release, perform final counsel/IP review, regenerate license/SBOM/metadata records from the commercial tree, and verify all shipped code/assets/dependencies have documented provenance and compatible terms.
