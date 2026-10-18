# Post-v1 headphone and multichannel roadmap

This roadmap records the owner-approved staged expansion of Notch Sixty beyond the v1 stereo-speaker program model. Each phase should land as its own reviewable PR and remain independently testable before the next phase is merged.

## Sequencing rule

The stack is cumulative. Each phase should be based on the preceding phase's accepted head so the PRs can be tested and merged in order. Shipping stereo behavior remains the compatibility baseline throughout the migration.

## Phase 1 / PR52 — N-channel core foundation

- semantic program-channel roles;
- canonical layouts through 9.1.6;
- fixed 16-channel realtime representation;
- explicit stereo-compatibility boundary;
- no audible/runtime behavior change.

## Phase 2 / PR53 — Channel-layout mapper and matrix router

- translate Core Audio channel-layout metadata into semantic program roles;
- compile bounded N×M routing matrices off the realtime thread;
- explicit unmapped/duplicate/ambiguous-channel rejection;
- identity stereo route remains the default;
- preserve the distinction between program channels and physical speaker endpoints.

## Phase 3 / PR54 — Per-channel and group DSP lanes

- generalized N-channel render buffers/state;
- per-channel gain, mute, polarity and delay;
- channel groups with linked editing;
- per-channel PEQ/FIR infrastructure;
- coherent latency accounting across lanes;
- multichannel-aware metering foundation.

## Phase 4 / PR55 — Multichannel bass management

- independent per-speaker crossover policy;
- explicit LFE handling;
- redirected-bass matrix;
- multiple physical subwoofer destinations;
- per-sub trim, delay, polarity, EQ/FIR and protection;
- preserve existing stereo Mains+Sub / active-crossover safety semantics.

## Phase 5 / PR56 — Headphone device mode

- headphone device profiles separate from content presets;
- independent L/R correction and channel matching;
- headphone target/correction lane;
- quality crossfeed with frequency-dependent opposite-ear feed and delay;
- headphone-safe gain/headroom and limiting policy.

## Phase 6 / PR57 — Binaural / virtual-speaker engine

- HRTF/BRIR convolution architecture;
- SOFA-profile import/validation policy;
- virtual speaker geometry;
- stereo and multichannel-to-binaural rendering;
- latency-coherent integration with headphone correction.

## Phase 7 / PR58 — Multichannel measurement, room correction and multi-sub

- speaker-by-speaker calibration sequencing;
- per-speaker level/delay/polarity evidence;
- multi-position measurement model generalized beyond stereo;
- per-speaker room correction;
- multi-sub optimization for seat-to-seat consistency;
- processed-path verification where measurement evidence supports automation.

## Phase 8 / PR59 — Advanced spatial and joint optimization

- head-tracking interface for virtual-speaker playback;
- vendor-neutral pose abstraction with platform-specific adapters where appropriate;
- MIMO/joint speaker-room optimization research path;
- advanced spatial/downmix/upmix features only where deterministic validation and product value justify them.

## Explicit non-goals of this train unless separately approved

- installing an audio driver or kernel/system extension;
- proprietary Dolby/DTS bitstream or object decoder implementation without the required licensing/product decision;
- silently synthesizing missing surround/height content by default;
- weakening the existing selected-output-device policy;
- moving graph construction, file parsing, device discovery, or allocation onto the audio callback.

## Acceptance philosophy

Each PR should have three gates:

1. deterministic software validation and retained CI;
2. explicit realtime/allocation/latency documentation for any callback change;
3. focused real-Mac hardware/listening acceptance before merge when the phase changes live audio behavior.

Later PRs may be prepared as a stacked sequence for convenient testing, but a later phase must not be treated as accepted merely because it builds on an untested predecessor.
