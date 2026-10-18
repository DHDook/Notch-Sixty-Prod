# PR117B — FIR, Latency and Headroom Reference Laboratory

**Scope:** test-only continuation stacked on PR117A. No product code, DSP
settings, user interface, native-rate negotiation or audio graphs change.

## 19 independent test cases

- Real production N60ProgramFIRRuntime five-tap symmetric FIR versus
  Python direct-convolution oracle, including 256-frame buffering, 2-frame
  tap-center delay, isolated filtered left channel, and right passthrough.
- Symmetric filter complex frequency response from discrete Fourier summation
  versus an independent trigonometric closed form at eight sample rates.
- Sample-rate-aware 258-frame end-to-end impulse-center accounting at
  44.1, 48, 88.2, 96, 176.4, 192, 352.8, and 384 kHz.
- Conservative FIR L1 gain/headroom example: [0.7,0.7] can create 1.4x peak
  and needs approximately 2.92 dB attenuation against that worst case.
- Known bandlimited synthetic sine with a continuous peak about 3.01 dB
  greater than integer-sample peaks; an analytical 4x grid recovers the peak.

## Latency and real-world boundaries

The 256-frame partition engine delay plus a separate 2-frame symmetric
FIR group delay yields an impulse center at 258 frames. The program's
declared latency is metadata for that extra filter offset, not a redundant
render delay. Inactive channels pass through in the underlying C runtime;
upstream multi-lane graph synchronization must compensate separately.
Acoustic distance, plugin buffering and output-device delay are NOT counted
here, and user-visible A/V sync requires physical acceptance.

The FIR program is sample-rate agnostic; converting frame delays into
milliseconds at 384 kHz checks mathematics, not actual DAC support.
The L1 gain example is a conservative bound, not guaranteed music peak
or acoustic SPL. The true-peak sine is analytical, not an implementation
test or certification of the production limiter/oversampling filter.

The case report explicitly declares remoteSoftware/syntheticOnly evidence,
with physical acceptance, native-device 384-kHz acceptance, public release,
live ANC authorization, and main merging all false.

## CI and remaining work

The test-only workflow runs the same standalone C/Python reference with
portable and Apple Clang and uploads schema-versioned JSON. There is no
need to repeat the complete app build for files that do not enter the
shipping binary; PR117A covers app compilation and cumulative XCTest.

Next phases: more production FIR/true-peak boundaries, native SOFA/Data.Delay
normalization and spatial transitions, final fixed-fixture review, then
owner-supervised real hardware testing. All PRs stay OPEN/DRAFT/UNMERGED.
