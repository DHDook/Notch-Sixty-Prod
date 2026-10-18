# PR55 — Multichannel Bass Management

PR55 is Phase 4 of the post-v1 headphone/multichannel expansion. It is stacked on PR54 and remains deliberately disconnected from the shipping stereo callback until the later live N-channel transport/render integration.

## Signal-model rule

Native LFE and bass redirected from bandwidth-limited speakers are different signals and remain different throughout the engine.

- An LFE program channel is identified semantically as `LowFrequencyEffects`.
- LFE may be independently low-passed, trimmed, and routed to one or more physical subs.
- Any non-LFE program channel may be high-passed at its own crossover frequency and have its complementary low-pass energy routed independently to one or more physical subs.
- A physical subwoofer output is not an LFE channel. It is a destination that can receive weighted contributions from LFE and/or redirected bass.

This prevents the common `.1 == subwoofer` architectural error and keeps future downmixing, multi-sub optimization, and room correction well-defined.

## Bounds

- program channels: 1–16, inherited from the semantic program-layout contract;
- physical subwoofer destinations: 1–4;
- per-sub generic filter bank: 8 biquads;
- product-facing allocation: 1 subsonic HPF + 1 phase-alignment all-pass + 6 user EQ sections;
- per-sub delay: fixed preallocated ring, up to 65,535 frames.

These are product/runtime bounds, not assumptions about Core Audio physical stream order.

## Per-speaker bass management

Every non-LFE program lane can independently declare:

- bass management enabled/disabled;
- crossover frequency;
- LR24 or LR48 topology;
- routing weight to each physical subwoofer.

The realtime stage emits the high-passed speaker feed in the original semantic channel position and accumulates the complementary low-pass feed into the configured physical sub destinations.

## Native LFE

LFE has its own controls:

- optional LR24/LR48 low-pass;
- LFE trim;
- independent LFE → Sub N routing weights.

LFE is consumed into the sub routing matrix and never silently reinterpreted as a physical sub output.

## Per-sub processing

Each physical sub destination has independent:

- enable/bypass;
- gain;
- polarity;
- delay;
- dedicated subsonic HPF;
- dedicated second-order all-pass phase alignment;
- six user EQ sections through the normal product-facing API;
- explicit emergency sample ceiling and clamp telemetry.

The subsonic and phase controls reuse two reserved slots in the generic per-sub biquad bank. This avoids introducing a redundant realtime filtering implementation while still keeping product controls disjoint from ordinary user EQ.

The emergency ceiling is intentionally not described as a mastering limiter. A future physical-output protection stage may replace it with a more sophisticated look-ahead policy while preserving the same per-sub ownership boundary.

## Realtime contract

After control-plane preparation, frame processing performs no allocation, free, locks, logging, I/O, tasks, filter design, or graph construction. Filter coefficients and routing weights are immutable realtime inputs; delay storage is allocated only when the runtime object is created.

## Scope boundary

PR55 does not yet:

- activate multichannel playback in the shipping Core Audio callback;
- perform multi-sub measurement/optimization;
- design room-correction FIRs;
- expose production UI;
- decode Dolby Atmos/object metadata;
- provide headphone rendering.

Those remain later phases of the PR52→PR59 roadmap.

## Acceptance

The permanent PR55 validation covers native LFE isolation, multi-sub routing, independent trim/polarity/delay, redirected bass, per-sub filtering, enable state, subsonic HPF, phase alignment, user-EQ slot isolation, and emergency protection behavior. The stacked PR-specific workflow runs the deterministic harness on portable Clang and Apple Clang and builds the arm64 macOS app with the ABI visible to Swift.
