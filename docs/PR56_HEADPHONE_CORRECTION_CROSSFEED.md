# PR56 — Headphone Correction and Acoustic Crossfeed

PR56 is Phase 5 of the post-v1 headphone/multichannel expansion. It is stacked on PR55 and adds a dedicated headphone-output DSP domain without changing the shipping stereo speaker callback.

## Ownership rule

Headphone hardware/device correction is **not** a Content Preset.

The intended product composition is:

```text
Content Preset (Reference / Rock Arena / Cinema / ...)
        ↓
optional spatial transform (crossfeed now; binaural renderer in PR57)
        ↓
Headphone Device Profile / correction
        ↓
existing protection / true-peak stage
        ↓
physical headphone output
```

A headphone profile owns hardware-specific correction, L/R matching, target identity, and correction headroom. Content Presets continue to own media-dependent voicing and dynamics. This avoids baking one headphone model into every listening preset.

## Correction engine

Each headphone channel has independent:

- gain/channel matching;
- polarity;
- fine delay/time matching;
- up to 16 prepared IIR/PEQ sections.

The realtime layer stores only prepared filter coefficients. Measurement/profile import and target-curve fitting remain control-plane work.

The snapshot records whether the prepared correction was designed against a Neutral, Diffuse Field, or Custom target. The target identity is metadata at realtime level; it does not cause filter design in the callback.

### FIR / linear-phase correction

PR56 deliberately does not create another partitioned-convolution engine. The existing proprietary stereo convolver already supports independent L/R FIR taps and will be reused when headphone FIR/device-profile deployment is integrated into the live graph. Its declared latency must participate in the same graph-wide latency-compensation contract established in PR54.

## Crossfeed

PR56 crossfeed is not direct L/R blending and is not marketed as full binaural virtualization.

The processor:

1. derives an interaural delay from virtual speaker angle and head radius;
2. creates a one-pole low-frequency/head-shadow band;
3. preserves the local high-frequency path;
4. cross-couples only the low band through the delayed contralateral path;
5. limits the low-band crossfeed coefficient to 0.5 even at maximum user strength.

This preserves high-frequency separation while reducing unnatural hard-panned low-frequency separation and introducing a speaker-like interaural timing cue.

Controls exposed by the DSP contract:

- Off/On;
- Amount 0...1;
- virtual speaker angle 15°...90°;
- head radius 0.06...0.12 m (advanced/personalization input);
- head-shadow crossover/cutoff.

Full individualized HRTF/BRIR rendering and SOFA import belong to PR57, not this crossfeed stage.

## Headroom / protection

Headphone correction has explicit attenuation-only headroom. PR56 does not duplicate the app's limiter or true-peak protection; the existing protection stage remains authoritative downstream when this processor is integrated live.

## Realtime contract

After preparation the headphone stage performs no allocation/free, locks, logging, I/O, task creation, file parsing, profile fitting, or coefficient design. Runtime storage is fixed and allocated once. The processor sanitizes non-finite input and is native-rate.

## Scope boundary

PR56 does not yet:

- activate a headphone mode in the shipping callback;
- add headphone UI/profile persistence;
- bundle third-party headphone correction databases;
- import AutoEQ or other external datasets;
- perform SOFA/HRTF/BRIR convolution;
- head-track;
- decode proprietary immersive formats.

## Acceptance

Permanent validation covers exact-unity bypass, independent L/R correction, channel delay, target identity, explicit correction headroom, invalid-control rejection, angle-derived contralateral delay, and frequency-dependent crossfeed (stronger low-frequency than high-frequency contralateral transfer). CI runs the harness under portable Clang and Apple Clang and builds the arm64 app with the ABI visible to Swift.
