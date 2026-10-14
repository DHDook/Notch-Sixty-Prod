# PR117 — Acoustic Reference Laboratory

**Status: Slice 1 source is staged; exact-head remote CI and later slices require closeout. Physical evidence pending.**

## Product purpose

Provide an independent mathematical benchmark for actual Notch Sixty DSP
before building additional optimizers. The question is whether the production
filter, crossfeed, routing or binaural stage behaved as mathematically expected,
and whether known acoustic failure modes are recognized. This is **not** an
REW clone, speaker-certification system or physical calibration replacement.

## Slice 1: reference against production snapshots

The file ci/acoustic_reference_lab/pr117_production_probe.c imports the actual
production C DSP headers and emits numerical coefficients and output samples.
The Python 3 standard-library validator ci/validate_pr117_acoustic_reference_lab.py
uses **independently written** complex response and direct-form difference
equations to check the real production probe. No shared numerical verifier
or duplicated C DSP implementation is treated as its own ground truth.

Cases cover 44.1, 48 and 96 kHz:

- PEQ +6 dB at 1 kHz: float coefficients, five frequency-response
  observations and a 512-frame direct-form versus production DF-II impulse.
- Real LR24 and LR48 80-Hz crossover sections: approximately −6 dB per
  leg and coherent unity-magnitude bass summation over multiple frequencies.
- Headphone profile: explicit headroom, individual L/R gain, isolation
  and a three-frame right-ear delay.
- Frequency-dependent acoustic crossfeed: measured 80-Hz and 10-kHz
  contralateral transfer compared to the independently derived one-pole
  discrete-time response.
- Binaural stereo-to-two-ear impulse: known left/right gains and
  the 128-frame partitioned convolution engine delay.

## Synthetic listening-room reasoning cases

1. Two-path direct/reflected response with a six-millisecond reflection,
   known reflected-energy fraction, and sample-rate-dependent frame lag.
2. Coherent cancellation null cannot be filled by common gain or EQ applied
   identically to two opposite paths (not all room dips are equivalent).
3. Weighted three-seat bass-response spread remains unchanged by common
   gain; a universal volume trim does not solve spatial consistency.
4. Odd symmetric 2049-tap linear-phase FIR contributes 1024 frames of
   intrinsic group delay, 21.333 milliseconds at 48 kHz, separate from
   engine buffering, speaker arrival and room decay.

These fixtures use analytical ground truth, not fake measured room data.

## Repeatability and test authority

- Explicit numerical tolerances, finite-sample checks, known sample rates,
  failure on incomplete record sets, source-commit identity and reproducible
  schema-versioned JSON output.
- Production headers and the probe are compiled as an isolated test binary;
  no Core Audio output, microphone or speaker wiring is required.
- The JSON always labels the results as remoteSoftware/syntheticOnly with
  realHardwareMeasured=false, physicalAcceptanceComplete=false,
  releaseAcceptanceComplete=false, liveFeedForwardANCAuthorized=false,
  mayMergeIntoMain=false.
- Mathematical test passes do NOT establish audible benefit, acoustic
  correction accuracy, HRTF individualization, physical protection,
  underrun-free playback, headphone SPL, licensing or public-release readiness.
- No third-party headphone frequency data, copyrighted music or HRTF dataset
  is bundled or downloaded.

## Local test command

From the repository root, run:

    python3 ci/validate_pr117_acoustic_reference_lab.py --report /tmp/pr117-acoustic-reference.json --commit "$(git rev-parse HEAD)"

Ubuntu/macOS GitHub Actions execute these tests and upload the JSON.
The macOS leg also verifies inherited software guards, arm64 Debug/Release
builds and the cumulative XCTest suite.

## Remaining PR117 slices (not implemented by this initial change)

- Slice 2 — additional multi-seat/transfer/timing fixtures, controlled
  measurement noise, weighted objectives, predicted-versus-actual
  synthetic corrections, and rejection tests.
- Slice 3 — FIR/convolver comparisons, ringing/latency/headroom/true-peak
  metrics, fault and clipping fixtures.
- Slice 4 — small license-clean native SOFA Data.Delay and coordinate tests,
  directional rendering and prepared head-tracking transition checks.
- Slice 5 — golden-fixture inventory, report comparison, performance
  benchmarks, acceptance documentation and exact-head remote closeout.

## Stack and hardware boundaries

Stack PR117 directly on PR116B, retain all branches OPEN/DRAFT/UNMERGED,
leave main and owner-approved icon assets unchanged, and never transform
remote software evidence into the real-Mac H01–H08 or headphone-listening
acceptance authorities. No live feed-forward ANC authorization or public
release may be inferred.
