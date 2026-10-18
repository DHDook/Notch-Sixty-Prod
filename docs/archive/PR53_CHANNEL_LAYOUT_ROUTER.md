# PR53 — Semantic channel mapper and matrix router

## Purpose

PR53 is Phase 2 of the post-v1 headphone/multichannel train. It builds on PR52's semantic program layouts by adding:

1. a bounded, allocation-free N×M channel-routing matrix; and
2. a Core Audio channel-description adapter that translates explicit Apple channel labels into Notch Sixty semantic roles.

It still does **not** activate multichannel playback in the production transport or replace the shipping stereo render kernel.

## Routing matrix

`N60ChannelRoutingMatrix` supports up to 16 source and 16 destination channels with fixed 16×16 storage.

Two compilation paths are intentionally distinct.

### Semantic reorder

`N60ChannelRoutingMatrixCompileSemanticReorder` is the safe convenience path.

It requires source and destination layouts to contain exactly the same unique semantic roles. It may reorder channels, but it refuses to:

- drop a channel;
- duplicate a channel;
- invent a missing channel;
- downmix;
- upmix; or
- silently change gain.

This is the correct mechanism for normalizing an externally ordered program into Notch Sixty's canonical semantic order.

### Explicit matrix

`N60ChannelRoutingMatrixCompile` accepts explicit source→destination edges and linear gains. It allows fan-in and fan-out because future downmix, bass-management, binaural and crossover policies need those capabilities.

Those behaviors are never inferred by this API. The higher-level product policy must intentionally supply the matrix.

Duplicate source→destination edges and non-finite gains are rejected.

## Core Audio semantic mapping

`N60CoreAudioChannelMapping.h` translates explicit `AudioChannelDescription.mChannelLabel` values into PR52 semantic identities.

Supported families include:

- Left / Right / Center;
- LFE;
- side surround;
- rear surround;
- wide;
- top front;
- top middle; and
- top rear.

Headphone-left/right labels normalize to Front Left / Front Right as signal identities only. A future headphone **device mode** remains a separate product/output concept.

Unsupported or ambiguous labels are rejected as `Unused`; they are not guessed into a position. This is especially important for discrete/object channels, extra LFE channels, center-height channels, ambisonics, and other layouts not represented by the current semantic schema.

### Standard layout tags and bitmaps

PR53 does not hardcode every standard Core Audio layout tag's hidden channel order.

The control plane should expand tag- or bitmap-based layouts into `AudioChannelDescription` arrays with Apple's public Audio Toolbox channel-layout properties, then pass those explicit descriptions through the semantic mapper. This avoids assuming that two six- or eight-channel formats use the same ordering.

Public Apple source of truth:

- Core Audio Types — Audio Channel Layout Tags
- Core Audio Types — Audio Channel Labels
- Audio Toolbox — `kAudioFormatProperty_ChannelLayoutForTag`
- Audio Toolbox — `kAudioFormatProperty_ChannelLayoutForBitmap`
- Audio Toolbox — `kAudioFormatProperty_ChannelMap`
- Audio Toolbox — `kAudioFormatProperty_MatrixMixMap`

The Apple documentation explicitly defines standard tags as layout/order identifiers and provides properties to expand tags/bitmaps and obtain reorder/mix maps. Notch Sixty keeps its own semantic matrix so the DSP graph remains independent of device/source ordering.

## LFE safety

The Core Audio label `kAudioChannelLabel_LFEScreen` maps to the semantic **program** role `LowFrequencyEffects`.

It does not map to PR41's physical `subMono` output bus. The later bass-management phase will make the relationship between native LFE, redirected bass and physical Sub N outputs explicit.

## Realtime impact

No shipping callback integration in PR53.

The matrix representation and frame primitive are nevertheless realtime-safe by construction:

- fixed-size storage;
- no allocation/free;
- no locks;
- no I/O;
- no logging;
- bounded loops at 16×16;
- zero algorithmic latency;
- no persistent filter state;
- no sample-rate assumption;
- reset behavior is trivial/stateless.

Matrix compilation and Core Audio metadata expansion belong on the control plane. Only an immutable compiled matrix is intended for a later audio callback.

## Provenance / source of truth

Net-new proprietary implementation based on:

- the owner-approved PR52→PR59 architecture plan;
- the PR52 semantic channel contract; and
- Apple's public Core Audio / Audio Toolbox channel-layout APIs.

No historical GPL source, tests or routing hierarchy were used as an implementation template.

## Validation

Permanent guard: `ci/validate_pr53_channel_router.py`.

The portable Clang harness verifies:

- stereo semantic mapping compiles to identity;
- reversed external L/R order compiles to the correct swap matrix;
- a reordered 7.1 source maps losslessly to canonical 7.1;
- explicit fan-in/mixing works only through the explicit matrix path;
- duplicate matrix edges are rejected;
- non-finite gains are rejected;
- semantic reordering rejects missing/replaced roles;
- processed frame results match the compiled matrix.

The Core Audio adapter is imported by the production Swift bridging header so the macOS build validates the actual SDK symbols and interoperability.

## Manual validation required

No new user-facing feature should appear.

After PR52 is accepted, PR53's real-Mac test remains a stereo regression smoke pass. There should be no audible or UI difference because the new matrix is not yet inserted into the live callback.

## App Sandbox / App Store impact

None. Only existing public Core Audio types are referenced. No new dependency, entitlement, permission, helper, driver or filesystem/network capability is introduced.

## Next phase

PR54 / Phase 3 should introduce the actual generalized N-channel DSP lane/render-buffer architecture, per-channel gain/polarity/delay, linked groups, coherent per-lane latency accounting and multichannel-aware metering foundations. That is the first phase where the live DSP core itself begins moving beyond a stereo-only frame contract, so it needs particularly strict regression and realtime validation.
