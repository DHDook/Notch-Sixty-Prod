# PR117C — Normalized SOFA/HRTF Spatial Reference Laboratory

**Draft, remote-software-only PR117 Slice 4.** Stacked on PR117B.
The new C probe directly imports the product's
N60BinauralRenderer.h and N60BinauralProfile.h. The Python oracle
independently verifies the observed spatial impulse response and latency.

## Verified in this slice

- 42 cases at standard rates 44.1, 48, 88.2, 96, 176.4, 192,
  352.8 and **384 kHz**.
- Correct left/right default virtual-speaker source positions (-30/+30
  degrees) map to distinct measurement rows even when input SOFA rows
  appear out of program-channel order.
- The production nearest-neighbor spherical direction scorer properly
  wraps 179 degrees past the -180/+180 degree seam; non-finite
  azimuth in the normalized input view is rejected.
- Source-to-ear impulse routing passes through the real prepared
  partitioned binaural renderer; four distinct IR tap offsets verify
  independent ear and left/right speaker routing.
- A normalized SOFA view whose sample rate differs from the profile
  is rejected before HRTF preparation. The renderer does not silently
  resample it or substitute another profile.
- The prepared stereo HRTF adds 128 frames of partition-engine delay
  and the synthetic HRIR taps carry additional frame offsets.
  Their physical delay (ms) depends on rate; a fixed-frame delay is
  not the same acoustic delay at 44.1 and 384 kHz.

## Critical boundaries

The test view contains **synthetic, pre-normalized SOFA-style HRIRs**.
The input arrays deliberately place delays inside the IR samples in
the same form required by the documented pre-render SOFA normalization
contract. This test DOES NOT exercise a native .sofa/HDF5 parser,
Data.Delay extraction or conversion, coordinate-frame metadata,
unit normalization, third-party SOFA data, head tracking, HRIR
interpolation, HRTF personalization, real headset listening,
room measurements, SPL, or real output device sample-rate support.
These remain separate acceptance items; the JSON report explicitly
marks realSOFAFileImported, normalizationAdapterTested,
realHRTFMeasured, physicalAcceptanceComplete, full384kHzRuntimeAcceptance,
releaseAcceptanceComplete and mayMergeIntoMain false.

The generic target is a product supporting standard sample rates up
to 384 kHz. That remains a **target**, not a hardware proof.

## Efficiency

All work in this slice is test-only: a small C probe, independent
Python reference, documentation and portable/Apple Clang CI.
No production audio source, presets, UI, app packaging, library
dependency or runtime allocation path is modified. The prior
PR117A branch still owns whole-app Release + XCTest validation;
rebuilding the full app for these test-only files would be redundant.

## Later follow-ups

An exact-file SOFA importer test should exercise explicit input source
coordinate conventions, Data.Delay unit semantics, resampling or
fail-closed mismatch behavior and declared end-to-end latency.
Subsequent production head tracking and HRTF interpolation require
their own real-time state and perceptual validation, not a synthetic
nearest-neighbor-only pass.

PR117C is OPEN/DRAFT/UNMERGED and the main branch remains unchanged.
