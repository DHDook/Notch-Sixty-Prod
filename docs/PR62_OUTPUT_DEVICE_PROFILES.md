# PR62 — Output Device Profiles and Semantic Speaker Layouts

## Purpose

PR62 adds the persistent control-plane model that turns the PR52–PR61 N-channel architecture into a hardware-specific Playback System configuration.

A Playback System can now own an optional **Output Device Profile** describing:

- semantic program layout,
- semantic speaker -> physical device/channel assignments,
- explicit physical `Sub 1...N` assignments,
- aggregate-device synchronization intent,
- reference/clock device identity.

This state is deliberately separate from Content Presets. Tone, dynamics, and other listening choices remain content-layer state; speaker layout and hardware routing belong to the output/calibration layer.

## Architecture

### Semantic program layouts

`OutputProgramLayout` exposes the currently supported bounded semantic layouts:

- 2.0
- 3.1
- 5.1
- 7.1
- 5.1.2
- 5.1.4
- 7.1.4
- 9.1.6

The first seven canonical layouts reuse PR52's fixed semantic C representation. `3.1` is represented as a valid custom `L/R/C/LFE` layout, so no new realtime enum is required.

Physical subwoofer count is intentionally **not** part of the program-layout identity. For example:

- 2.1 = stereo program layout + one physical Sub output,
- 2.2 = stereo program layout + two physical Sub outputs,
- 5.2 = 5.1 program layout + two physical Sub outputs,
- 7.2 = 7.1 program layout + two physical Sub outputs.

This preserves the architecture rule that native LFE program content is not the same thing as a physical subwoofer output.

### LFE and physical Sub N remain separate

When PR55 bass management is enabled:

- every non-LFE semantic speaker must map exactly once,
- semantic LFE must **not** have a direct physical speaker assignment,
- at least one explicit physical Sub assignment is required,
- Sub indices must be dense from Sub 1,
- PR61's output-map compiler receives semantic LFE as unmapped and separate `Sub 1...N` destinations.

When bass management is bypassed:

- a layout containing semantic LFE must map LFE like an ordinary program channel,
- explicit physical Sub N assignments are rejected.

This prevents a future transport from accidentally duplicating LFE or collapsing redirected bass and native LFE into one ambiguous identity.

### Hardware/device planning

`OutputDeviceProfileConfiguration.makeLivePlan(...)` performs control-plane validation before any realtime activation:

1. profile must be enabled,
2. semantic assignments must match the selected layout,
3. physical destinations must be unique,
4. every referenced device must currently exist,
5. every physical channel index must exist,
6. every device must natively support the requested sample rate,
7. software-PLL mode remains rejected in favor of Core Audio Aggregate Device clocking/drift compensation,
8. multiple devices are flattened deterministically with the reference device first,
9. the flattened channel count must fit PR61's fixed physical-output bound,
10. the resulting plan must compile successfully through `N60LiveNChannelOutputMapCompile`.

The resulting `LiveNChannelOutputRoutePlan` is immutable control-plane data intended for the PR61 live N-channel bridge/session layer.

### Playback System persistence

`PlaybackSystemState` now owns:

```swift
var outputDeviceProfile: OutputDeviceProfileConfiguration?
```

The field is optional and `PlaybackSystemState.currentSchemaVersion` deliberately remains version 1. Pre-PR62 JSON archives therefore decode the missing key as `nil`, preserving existing saved Playback Systems instead of dropping them during migration.

PR41's legacy stereo physical-output routing and PR62's semantic N-channel Output Device Profile are mutually exclusive when enabled. Profile mutations and Playback System application both enforce that conflict explicitly.

Changing bass-management enabled state also revalidates any enabled Output Device Profile first, so a saved routing contract cannot silently change from direct LFE to Sub routing or vice versa.

## Realtime impact

No shipping audio callback is changed or activated by PR62.

PR62 is control-plane only. It creates validated immutable route plans and compiles them against PR61's realtime output-map ABI, but the current production stereo transport remains the default path.

PR63 will be responsible for creating/stopping the live PR61 transport from an enabled Output Device Profile. Keeping activation out of PR62 preserves a narrow rollback boundary and lets persistence/routing semantics become green before hardware lifecycle changes are introduced.

## Provenance

Clean-room proprietary implementation based on the project's existing proprietary PR41/PR52–PR61 architecture, Core Audio device abstractions already present in this repository, and owner-approved semantic routing requirements.

No GPL source code or implementation was copied or adapted.

## Automated validation

`ci/validate_pr62_output_device_profiles.py` runs structural checks on all platforms. On macOS it additionally compiles and executes the actual PR62 Swift source against the app's real C bridging header using a minimal control-plane stub for existing Swift device/routing types.

The executable harness covers:

- 7.1.4 plus two physical subs,
- semantic LFE remaining unmapped under bass management,
- PR61 output-map compilation,
- 3.1 custom-layout validity,
- disabled-profile fail-closed behavior,
- direct-LFE versus Sub N mutual exclusivity,
- dense Sub numbering,
- sample-rate and physical-channel capability rejection,
- deterministic multi-device flattening/reference ordering.

macOS CI also performs a full arm64 application build so the new production Swift source and Playback System persistence wiring are compiled in the real target.

## Manual validation after merge stack is tested on a Mac

PR62 itself should not change audible behavior. Manual review should confirm:

- existing saved Playback Systems still appear and select normally,
- existing stereo processing starts exactly as before,
- no Output Device Profile activates unless explicitly configured and enabled,
- legacy multi-output routing remains unchanged for existing users.

Actual multichannel hardware playback belongs to PR63 and later real-device QA.

## App Store impact

No new entitlement, permission, network access, file access, or background service is introduced. The model uses existing Core Audio output-device identities and existing application persistence only.
