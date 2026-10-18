# PR52 — N-channel program-layout foundation

## Purpose

PR52 begins the post-v1 headphone and multichannel expansion without changing the shipping stereo audio path.

The production engine currently has two different concepts that must not be conflated:

1. the **program** is still stereo; and
2. PR41/PR43 can derive that stereo program into multiple physical speaker/crossover buses and route those buses to multiple hardware channels/devices.

This PR introduces the semantic program-channel layer that future work will use to generalize item 1. It deliberately does **not** reinterpret PR41's speaker-driver buses as surround channels and does not allow an incompletely migrated multichannel program to enter the existing stereo render kernel.

## Architecture added

`N60ProgramLayout.h` defines a fixed-size, allocation-free semantic program layout contract with a maximum of 16 channels.

Semantic roles are stable signal identities rather than physical channel indices:

- Front Left / Front Right
- Front Center
- Low Frequency Effects (LFE)
- Side Left / Side Right
- Rear Left / Rear Right
- Wide Left / Wide Right
- Top Front Left / Top Front Right
- Top Middle Left / Top Middle Right
- Top Rear Left / Top Rear Right

Canonical layouts are provided for:

- Stereo
- 5.1
- 7.1
- 5.1.2
- 5.1.4
- 7.1.4
- 9.1.6

A bounded custom-layout representation is also provided so later work does not require another realtime ABI redesign merely to represent a new conventional layout.

## Semantic order versus physical order

The order stored in `N60ProgramChannelLayout` is an **internal canonical semantic order only**.

It must never be assumed to equal:

- an application's source-buffer order;
- an `AudioChannelLayout` / `AudioChannelDescription` order supplied by Core Audio;
- a device stream order; or
- a physical output-channel number.

PR53 / Phase 2 will introduce the explicit mapping layer between external channel-layout metadata, the internal semantic program layout, and physical output destinations.

## LFE is not a subwoofer output

`LowFrequencyEffects` is a program-channel role. It represents the native `.1` content channel in a multichannel program.

It is intentionally separate from PR41's `subMono` physical speaker bus and from any future Sub 1 / Sub 2 / Sub N output destinations.

Future bass management must therefore be able to combine or route, under an explicit policy:

- native LFE content; and
- bass redirected from bandwidth-limited main/surround/height channels.

This distinction is a hard architectural requirement.

## Stereo compatibility boundary

`N60ProgramChannelLayoutIsStereoCompatible` is the explicit compatibility gate for the current render path.

In PR52:

- Stereo is represented as `{ FrontLeft, FrontRight }`.
- The shipping `N60RenderKernelProcessStereoFrame*` path is unchanged.
- No non-stereo program layout is passed into the current render kernel.
- No existing routing, EQ, FIR, dynamics, room-correction, crossover, speaker-driver, metering, or transport behavior changes.

The existence of a 5.1/7.1/etc. layout value is therefore **not** a claim that PR52 can render that layout. It is the type-safe foundation needed before the router and N-channel render path are introduced.

## Realtime impact

None on the shipping callback in this PR.

The new representation:

- uses fixed-size storage only;
- allocates no memory;
- acquires no locks;
- performs no I/O;
- adds no latency;
- has no sample-rate dependency;
- is not invoked by the shipping stereo callback yet.

All helper functions in `N60ProgramLayout.h` are bounded by `N60_MAX_PROGRAM_CHANNELS == 16`.

## Reset behavior

There is no stateful DSP in PR52 and therefore no reset state. A layout value is an immutable/control-plane-style value once published to any later realtime consumer.

## Provenance / source of truth

Net-new proprietary implementation.

Source of truth is the owner-approved post-v1 architecture requirement: generalize the program representation to semantic N-channel layouts while retaining the existing production stereo path until each downstream stage is safely generalized.

No historical GPL source, tests, routing hierarchy, or type names were used as an implementation template.

## Validation

Permanent guard: `ci/validate_pr52_nchannel_foundation.py`.

It compiles and executes a standalone C harness with Clang and verifies:

- every canonical layout is structurally valid;
- canonical channel counts are 2 / 6 / 8 / 8 / 10 / 12 / 16;
- stereo resolves Front Left and Front Right deterministically;
- 9.1.6 fills the complete 16-channel bound;
- duplicate semantic roles are rejected;
- invalid/overflow custom layouts are rejected;
- valid bounded custom layouts remain representable;
- a mutated standard layout no longer validates as that standard layout;
- only explicit Front Left + Front Right is accepted by the stereo compatibility helper.

The new header is imported by the existing Swift bridging header, so the normal macOS app build also exercises Clang/Swift interoperability.

Normal repository gates remain authoritative for build, full XCTest, realtime benchmarks, retained architectural validators, Release build, and packaging.

## Manual validation required

Because PR52 intentionally changes no live audio or UI behavior, the later real-Mac acceptance is a **stereo regression smoke test**, not a new-feature acceptance test:

- ordinary stereo playback;
- EQ and Dynamics edits;
- Levels/Stereo meters;
- Room Correction path;
- existing PR41/PR43 speaker/crossover routing where safely connected;
- Stop/Start;
- no new clicks, channel swaps, level changes, latency changes, or instability.

No surround/headphone feature should appear in the production UI yet.

## App Sandbox / App Store impact

None. No entitlement, device permission, driver, privileged helper, dependency, network access, or filesystem capability is added.

## Next phase

PR53 / Phase 2 should add the semantic channel mapper / matrix router and explicit Core Audio channel-layout translation while continuing to preserve the shipping stereo path as the default and refusing unsafe/ambiguous mappings.
