# PR55 Acceptance Checklist

PR55 is an architecture/runtime foundation. No new production UI or live multichannel transport is expected.

## Automated acceptance

- Native LFE remains semantically distinct from physical subwoofer outputs.
- LFE may route independently to multiple physical subs.
- Non-LFE channels may be independently high-passed and redirect complementary bass to multiple subs.
- Per-sub enable, gain, polarity, delay, subsonic HPF, phase alignment, user EQ, and emergency protection are deterministic and isolated.
- Disabled/unassigned physical subs remain silent.
- No realtime allocation, locks, logging, I/O, async work, or filter design is introduced.
- Portable Clang and Apple Clang validators pass.
- arm64 Debug app build passes with the new ABI exposed through the Swift bridging header.

## Later real-Mac regression pass

Because PR55 is not wired into the shipping callback, the manual pass is regression-only:

- ordinary stereo playback unchanged;
- Equalizer and Dynamics unchanged;
- Levels/Stereo meters unchanged;
- Room Correction unchanged;
- existing PR41 speaker/crossover routing unchanged;
- Stop/Start unchanged;
- no clicks, level changes, channel swaps, latency changes, or new instability.

Do not expect surround/headphone controls to appear from PR55 alone.
