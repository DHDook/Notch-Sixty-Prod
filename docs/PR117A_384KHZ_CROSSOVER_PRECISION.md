# PR117A — 384-kHz Crossover Precision Hardening

**Draft / stack above PR117 #120. Real-hardware and listening gates remain open.**

## Why

PR117 exposed audible-band low-frequency response drift in float normalized
crossover second-order sections at sample rates high relative to cutoff.
At a 384-kHz rate and 80-Hz crossover, the normalized feedback values are
close to -2 and +1, while the important differences between them are tiny.
Rounding each to float destroys significant digits and can introduce
several-percent coherent-summation error around the intended crossover.
The independent LR24/LR48 response oracle caught this defect.

## Minimal DSP fix

- Only crossover and speaker-bus splitter immutable SOS snapshots move to
  five *double* coefficients per section, with paired double DF-II state.
- The crossover designs low-pass, high-pass, and all-pass sections off the
  realtime thread in double precision and never downcasts the feedback
  coefficients into the former float slots.
- The actual physical 2-, 3- and Sub bus splitter uses the precise filter
  states and coefficients. The protected per-driver offline measurement
  path reuses the same DSP helper.
- Input/output samples remain float; Core Audio routing, subwoofer output
  topology, master volume, meter, protection, Headphone DSP, equalizer
  snapshot types, user presets, plugin system, audio callback ownership,
  latency and real-time allocation rules remain otherwise unchanged.
- No new library, Audio Unit, HRTF data, live ANC, background process or
  alternate samplerate engine.
- This has some bounded extra float64 arithmetic for physical crossover
  sections. At 384 kHz, performance and power should still be checked with
  the real target hardware as part of PR112 acceptance.

## Numerical validation

The existing PR117 production C probe now serializes crossover coefficient
values with 17 significant decimal digits, without converting back to float.
The independent Python oracle continues to require LR24/LR48 coherent
unity summation error at most 0.018 across 25/45/80/160/320 Hz, with
the target 80 Hz crossover leg at approximately -6 dB. Eight sample
rates are checked: 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz.
Peaking EQ comparisons remain bounded to 0.005 dB on ideal versus float
production coefficients; headphone channel, crossfeed and HRTF tests
also remain in PR117's full fixture suite.

**This test passing is NOT equivalent to measured bass flatness at a
listening position**: the speaker, room, sub alignment and amplifier may
change the actual acoustic sum. Likewise, it does not demonstrate that
all plugins or all output devices are 384-kHz-compatible.

## Acceptance

- Portable numerical and source-ownership guard, plus inherited safety gates.
- Apple Silicon build and cumulative XCTest regression with the new C types.
- Preserve initial PR117 synthetic 384-kHz acoustic verification artifact.
- PR112 H01–H08 and real listening/hardware tests remain mandatory.
- Keep OPEN/DRAFT/UNMERGED; main and PR116/PR116B masters untouched.
