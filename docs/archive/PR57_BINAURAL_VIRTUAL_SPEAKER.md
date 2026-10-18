# PR57 — Binaural Virtual-Speaker Foundation

PR57 is Phase 6 of the post-v1 headphone/multichannel expansion. It is stacked on PR56 and adds the multichannel-to-binaural render architecture plus an open HRTF/BRIR data boundary. It does not yet activate live headphone output or head tracking.

## Signal model

```text
semantic program channels (1...16)
        ↓
virtual source position per semantic role
        ↓
channel HRIR/BRIR pair (left ear + right ear)
        ↓
shared-input partitioned convolution
        ↓
binaural L/R
        ↓
PR56 headphone-device correction
        ↓
existing protection / true-peak stage
        ↓
headphones
```

Each program channel is one acoustic source. Each source owns two FIR transfer functions: source→left ear and source→right ear. The renderer sums every source's two ear contributions into a final binaural stereo pair.

## Shared-input partitioned convolution

A naive implementation would instantiate a complete stereo convolver for every source and transform the same source sample separately for each ear. PR57 instead performs one forward FFT/history stream per program channel and shares that spectrum across the left- and right-ear kernels.

Bounds:

- 1–16 semantic program channels;
- 2 receiver/ear outputs;
- 128-frame partitions;
- 256-point FFT;
- up to 8,192 FIR taps per source/ear;
- 64 partitions maximum;
- fixed 128-frame engine latency plus profile-declared acoustic/filter latency.

Kernel and history storage is allocated during renderer creation. Profile preparation and FFT kernel generation occur off the realtime thread. Frame rendering allocates nothing and takes no locks.

The current portable scalar FFT provides a deterministic architecture/reference implementation. A future optimization pass may replace the internal transform with Accelerate/vDSP on Apple platforms while preserving the exact renderer ABI and convolution mathematics.

## Virtual source geometry

The profile carries semantic role plus azimuth/elevation/distance for every channel. Standard layouts receive deterministic default positions for fronts, center, sides, rears, wides, and height speakers. Positions are metadata used by HRTF/BRIR selection; the measured impulse responses remain authoritative for localization.

LFE defaults to **equal-ear** rendering rather than pretending the `.1` program channel is a localized physical subwoofer. Directional LFE remains an explicit opt-in profile policy.

## SOFA boundary

SOFA/AES69 is the interchange target for open HRTF/HRIR data. The `SimpleFreeFieldHRIR` convention represents varying source positions, two receiver/ear responses, `Data.IR`, sampling rate, and optional additional delay.

PR57 deliberately separates **file decoding** from **realtime rendering**. A control-plane SOFA adapter normalizes a file into `N60SOFAHRTFNormalizedView`:

- one sample rate;
- measurement count M;
- exactly two receiver IRs;
- tap count N;
- source azimuth/elevation/distance in the Notch Sixty canonical spatial convention;
- any SOFA `Data.Delay` already incorporated into the normalized IRs;
- channel-major left/right float PCM.

The renderer then selects the nearest measured direction for each virtual speaker and prepares immutable partitioned kernels. This means HDF5/NetCDF parsing and dependency/licensing decisions never enter the realtime layer.

Public source of truth for the normalized boundary: AES69/SOFA `SimpleFreeFieldHRIR` and GeneralFIR conventions maintained by the SOFA project.

## HRTF vs BRIR

`HRTF` profiles represent free-field/head-related transfer behavior. `BRIR` profiles may include room response/externalization and therefore can use the larger FIR budget. Both use the same two-ear MIMO renderer.

PR57 does not synthesize a room algorithmically. It renders measured/prepared impulse responses supplied by the control plane.

## Head tracking

PR57 profiles are static. Head tracking requires time-varying orientation, rapid HRTF direction updates/interpolation, and click-free kernel transitions. That belongs to a later phase and must not mutate or rebuild convolution kernels inside the audio callback.

## Scope boundary

PR57 does not yet:

- parse `.sofa` files directly in the realtime module;
- add a third-party SOFA/HDF5 dependency;
- activate a production headphone mode;
- expose virtual-speaker/headphone UI;
- head-track;
- perform individualized HRTF estimation from ear photos;
- decode Dolby Atmos bitstreams or object metadata.

Already-decoded PCM in layouts such as 5.1, 7.1, 5.1.4 and 7.1.4 can feed this semantic renderer once the live multichannel transport is connected.

## Acceptance

Permanent validation covers partition latency, stereo semantic routing, equal-ear LFE behavior, SOFA-normalized nearest-direction selection, a 7.1.4/two-partition render smoke test, non-finite rejection, no realtime allocation, and arm64 app compilation with the renderer ABI visible to Swift.
