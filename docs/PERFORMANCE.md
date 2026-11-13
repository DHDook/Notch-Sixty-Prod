# Performance

Owner: E20 (engine performance). This file records the method, the baseline, the hot list and the
budgets for the portable engine core (`libn60core`). Harness: `core/bench/n60_bench.cpp`.

## Method

- Load = render time / buffer period, measured with the core only (no Core Audio, no Swift).
- Reference block: 128 frames at 48 kHz, doubled per octave above 48 kHz (1024 frames at 384 kHz), so
  the period stays about 2.7 ms. Stress block: a quarter of that.
- Eight rates: 44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz.
- Each cell is the median of N runs of the mean and the p99.9, and the worst max.
- Scenarios:

| ID | Layout and chain |
|---|---|
| R1 | Full chain, 2 mains + 2 subs, room FIR 8192 taps |
| R2 | Full chain, 6 mains + 2 subs, room FIR 4096 |
| R3 | Full chain, 12 mains + 4 subs, room FIR 4096 |
| R4a / R4b | 262144-tap FIR on 2 / 8 lanes |
| R5 | Layout 9.1.6 binaural, 8192 taps |
| R6 | 32 PEQ stages x 16 sections (512-slot cap) |
| R8 | E19 MIMO treatment stage, armed, 8 sources, 4096 taps per filter (runs at fs/D inside the stage) |
| R7 | ANC lane feed, offline compute only (workflow build, `-DN60_BENCH_ANC`); nothing reaches a device |

- Gate (macos-full): fail above 1.5x the committed baseline, warn above 1.2x. Budgets in
  `core/bench/budgets.json` are enforced in `macos-full` (`--enforce-budgets --workers 2`, E20 S10).
- Per-stage cost: `N60_GRAPH_PROFILE` builds (`n60_bench_profile`) record ns per lane-sample for each
  stage kind. The hooks are compiled out of product builds; `core/tests/test_profile.cpp` asserts the
  symbols are absent there.
- Run locally: `ci/run_harnesses.sh e20_` (self-tests) or build `n60_bench` as in `macos-full.yml` and run
  `n60_bench --out bench.json --budgets core/bench/budgets.json`.

## Baseline (local, Apple M4, -O3, reference block, mean load %)

These are local numbers on an M4, not the M1 target and not a CI runner. The committed CI baseline
(`core/bench/baseline-macos-arm64.json`) comes from the first nightly.

| Scenario | 44.1 | 48 | 88.2 | 96 | 176.4 | 192 | 352.8 | 384 |
|---|---|---|---|---|---|---|---|---|
| R1 | 2.5 | 2.7 | 5.1 | 5.6 | 10.3 | 11.2 | 20.5 | 23.2 |
| R2 | 6.9 | 10.7 | 18.6 | 17.4 | 37.8 | 41.5 | 79.9 | 41.8 |
| R3 | 9.7 | 10.3 | 19.3 | 21.1 | 39.6 | 41.7 | 77.2 | 90.0 |
| R4a | 0.5 | 0.5 | 1.0 | 1.2 | 2.3 | 2.5 | 5.1 | 5.6 |
| R4b | 2.1 | 2.2 | 4.3 | 4.8 | 9.3 | 9.9 | 20.8 | 22.5 |
| R5 | 3.4 | 3.7 | 6.8 | 7.5 | 13.8 | 15.0 | 27.5 | 30.1 |
| R6 | 2.9 | 3.2 | 5.7 | 6.2 | 11.4 | 12.4 | 22.7 | 24.7 |
| R8 | 0.9 | 1.0 | 1.3 | 1.4 | 2.3 | 2.4 | 3.9 | 4.3 |

The R2 384 kHz cell is lower than 352.8 kHz because the period doubling stops at 1024 frames and the
FIR partitioning changes there; treat it as a harness artefact to re-check on the CI baseline.

## After E20 S3 (portable SIMD layer, local M4, -O3, reference block, mean load %)

Same machine and method as the baseline above, three runs, one second each; before is the S2 tree, after is
this slice. The SIMD changes are PEQ and crossover lane pairs (`f64x2`), the 64-tap half-band dot product in
PROTECTION (`f32x4`, four accumulators), meters, gain and M/S, and the removal of the per-block manual denormal flushes.

| Scenario / rate | Before | After | Change |
|---|---|---|---|
| R1 48 kHz | 2.71 | 2.19 | -19% |
| R1 384 kHz | 21.62 | 17.62 | -19% |
| R2 48 kHz | 5.07 | 4.32 | -15% |
| R2 384 kHz | 41.00 | 34.22 | -17% |
| R3 48 kHz | 10.71 | 9.42 | -12% |
| R3 384 kHz | 88.05 | 75.36 | -14% |
| R6 48 kHz | 3.15 | 1.86 | -41% |
| R6 384 kHz | 24.74 | 17.71 | -28% |

Per-stage (ns per lane-sample, profile build, R1): PROTECTION 94.5 to 38.8 at 48 kHz (63.0 to 40.8 at 384 kHz),
PEQ 8.7 to 2.0 at 48 kHz in R1 (R6 PEQ 10.1 to 6.0). FIR is untouched (S4) and is now the top stage at 48 kHz.
Bit-identical SIMD and scalar (`N60_SIMD=0`) builds are checked by `core/tests/test_simd_parity.cpp`.

## After E20 S4 (real FFT, SIMD FFT and complex multiply-accumulate, half-band dot product, local M4, -O3, reference block, mean load %)

Same machine and method, base is `main` at S3, after is this slice (one run, two seconds each, so figures carry a few percent of noise).
Changes: real-input packing (one n/2-point complex FFT per real transform) and SIMD butterflies in `fft.cpp`, SIMD
complex multiply-accumulate (`simd::cmacSpan`) in the non-uniform FIR and the binaural convolver, and PROTECTION half-bands that
compute the dot product only on emitted outputs (decimators) and over the real inputs only (interpolators).

| Scenario / rate | Before | After | Change |
|---|---|---|---|
| R1 48 kHz | 2.22 | 1.52 | -32% |
| R1 384 kHz | 17.75 | 11.85 | -33% |
| R4a 48 kHz | 0.58 | 0.23 | -60% |
| R4a 384 kHz | 5.62 | 2.74 | -51% |
| R4b 48 kHz | 2.29 | 0.92 | -60% |
| R4b 384 kHz | 22.91 | 11.18 | -51% |
| R5 48 kHz | 3.64 | 2.87 | -21% |
| R5 384 kHz | 29.20 | 23.15 | -21% |

R1 and R4 were measured before the binaural convolver was converted; R5 after. Radix-4 butterflies and the remaining loop conversions
(G14) are not in this slice. SIMD and scalar builds stay bit-identical (`ci/run_harnesses.sh` `e20_fft_scalar_parity`).

## Hot list (ns per lane-sample, profile build, before S3)

| Scenario / rate | Top stages |
|---|---|
| R1 48 kHz | PROTECTION 80.9, FIR 57.6, CLEANUP 10.0, PEQ 7.3, DYN_EQ 6.6 |
| R1 384 kHz | PROTECTION 65.1, FIR 45.3, CLEANUP 7.3, PEQ 5.7, DYN_EQ 5.1 |
| R3 48 kHz | PROTECTION 50.2, FIR 35.0, CLEANUP 8.2, DYN_EQ 6.3, EXPANDER 6.2 |
| R3 384 kHz | PROTECTION 58.9, FIR 35.3, CLEANUP 7.5, BASS_MGMT 5.8, PEQ 5.6 |
| R5 | BINAURAL 44.2, PROTECTION 7.7 |
| R6 | PEQ 10.2 |

Protection and the FIR dominate the full chain; S3 (SIMD, section loops) and S4 (FFT, convolution)
target them, and S5/S7 spread or decimate the rest.

## Budgets (E20 Q1, enforced since E20 S10)

`core/bench/budgets.json`: R1 mean 0.25, R1 p99.9 0.5, R1 fade 2x 0.8 (single thread, `ref` rows); R2 mean 0.5, R2 fade 2x
0.8, R3 mean 0.5 (judged on the `refw` rows: the caller's time with two worker threads, `n60_bench --workers 2`, so the
parallel render counts). `macos-full` runs `n60_bench ... --enforce-budgets --workers 2`; a breach fails the step, and so
does an R7 row missing from the JSON (the workflow build passes `-DN60_BENCH_ANC`). R3 has no fade entry yet (gap G33).

Published table (Apple M4, -O3, one core for `ref`, caller plus two workers for `refw`, mean load %, reference block):

| Row | 44.1 | 48 | 88.2 | 96 | 176.4 | 192 | 352.8 | 384 | Budget |
|---|---|---|---|---|---|---|---|---|---|
| R1 ref | 1.7 | 1.5 | 2.7 | 3.0 | 5.5 | 6.0 | 11.1 | 12.1 | 25 |
| R2 refw | 2.7 | 2.7 | 4.5 | 5.0 | 8.8 | 9.6 | 17.2 | 18.8 | 50 |
| R3 refw | 5.2 | 5.6 | 9.5 | 10.4 | 18.6 | 19.5 | 34.4 | 40.4 | 50 |
| R3 ref (single thread) | 5.1 | 5.5 | 10.1 | 11.1 | 20.9 | 21.7 | 38.9 | 49.2 | not judged |

R3 at 384 kHz gains little from workers (the serial PROTECTION stage dominates), so its fade rule (twice the mean under
80%) is not met on this machine: 2 x 40.4% is 80.8%. These are local M4 numbers, not the M1 target or a CI runner; the
CI baseline and M1 re-measurement are E22 items.

## Release optimisation

Xcode Release for the app target now sets `-O3` for C++ (`OTHER_CPLUSPLUSFLAGS`). On the M4, -O3 ran
about 35% faster than -Os/-O2 on R1 and R3, over the plan's 10% threshold. Measured on an M4, not an
M1 (re-check at the E22 bench).
