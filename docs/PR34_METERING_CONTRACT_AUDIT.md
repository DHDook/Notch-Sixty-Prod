# PR34 Legacy Metering / RTA Contract Audit

Status: **SOURCE/TEST AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This document records observable metering and RTA contracts established from reachable legacy source and the legacy test suite. It does not copy implementation expression. These requirements belong primarily to the already-planned **Metering / RTA / analysis + production UI shell** milestone, with per-output telemetry attached to the later **Active Crossover Matrix** milestone.

# 1. Main level-meter display contract

Legacy `MeterConstants` and `MeterCalculationTests` establish:

- display range: **-60 dBFS to 0 dBFS**,
- values below/above the display range clamp to the bottom/top,
- display position is **linear in dB**, not gamma-corrected,
- silence calculation floor: **-90 dBFS**,
- at-rest silence threshold: **-85 dBFS**,
- standard scale ticks: **0, -3, -6, -12, -18, -24, -30, -36, -48, -60 dB**,
- meter update interval: **1/60 s**,
- peak hold: **1.0 s**,
- clipping hold: **0.5 s**,
- peak attack smoothing: **1.0** (instant rise),
- peak release smoothing: **0.33**,
- RMS smoothing: **0.12**.

The tests also explicitly establish ordinary peak-as-maximum-absolute-sample behavior and RMS as the standard square-mean-root quantity.

**Classification:** **LATER MILESTONE — Metering / RTA / analysis + production UI shell.**

The commercial implementation may use a different internal meter transport, but these are verified observable presentation/ballistics contracts that must be deliberately preserved or improved rather than omitted accidentally.

---

# 2. VU meter contract

Legacy source/tests establish:

- VU source is selectable between **Input** and **Output**,
- default VU source is **Output**,
- VU motion uses symmetric analog-style ballistics,
- documented settling target is approximately **300 ms to ~99%** of a step,
- legacy 60 Hz update coefficient is approximately **0.226**,
- 0 dBFS raises the clipping indication,
- clipping remains latched through the configured **0.5 s** clip-hold interval before clearing,
- VU updates converge gradually rather than jumping immediately to the target.

**Classification:** **LATER MILESTONE — Metering / RTA / analysis + production UI shell.**

The exact UI appearance may change, but source selection, bounded ballistics, and clip-hold behavior are confirmed live product contracts.

---

# 3. Meter work is demand-gated

`MeterStoreTests` establish an important performance/behavior contract:

- the master meter switch alone does **not** enable realtime meter work when every meter group is disabled,
- a group toggle enables pipeline metering only while the master switch is enabled and a meter window is visible,
- window visibility is reference-counted by window ID,
- when no relevant meter window remains visible, realtime meter calculations are disabled,
- disabling/stopping meters returns observers to a silent state.

**Classification:** **LATER MILESTONE — Metering / RTA / analysis**, and also a **performance invariant** for the production UI.

The commercial meter architecture does not need to reproduce the same timer/observer implementation, but it should retain the principle that expensive analysis work is not performed merely because the application supports meters.

---

# 4. RTA / dual-spectrum acceptance contract

Legacy `RTAAnalyzerTests` establish:

- simultaneous **Input** and **Output** spectrum paths,
- RTA normalization maps **-80 dBFS -> 0** and **0 dBFS -> 1**,
- a full-scale 1 kHz sine should read within a few dB of 0 dBFS in its band,
- silence remains near the spectrum floor,
- peak hold is **60 frames / ~1 s at 60 Hz**,
- falling smoothing coefficient is approximately **0.847**,
- peak decay coefficient is approximately **0.959**,
- the analyzer must remain finite and in-range across every explicitly tested sample rate:
  - 44.1 kHz
  - 48 kHz
  - 88.2 kHz
  - 96 kHz
  - 176.4 kHz
  - 192 kHz
  - 352.8 kHz
  - **384 kHz**,
- narrow low-frequency bands that are smaller than one FFT bin at high rates must still produce a valid finite value rather than an invalid bin range/crash,
- full-spectrum material must route successfully across the analyzer's multiple resolution lanes at all supported rates.

**Classification:** **LATER MILESTONE — Metering / RTA / analysis + production UI shell.**

The exact FFT sizes or multi-lane internals are not parity requirements by themselves. The verified observable requirements are correct band mapping, useful level calibration, stable ballistics, and finite behavior through 384 kHz.

---

# 5. Per-output channel metering contract

The output-matrix test suite establishes per-output telemetry for active matrix channels:

- pre-limiter peak,
- post-limiter peak,
- excursion-protection gain reduction,
- brickwall-limiter gain reduction,
- clipping state,
- all active output channels are published to the meter store.

Additional tested behavior:

- pre-limiter peak is refreshed during processing,
- with the output limiter enabled, post-limiter level does not materially exceed its ceiling,
- brickwall gain reduction remains at zero when the signal is comfortably below the ceiling,
- the legacy clipping criterion is based on the **pre-limiter level exceeding -0.5 dBFS**.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / driver-processing parity**, surfaced through the production metering/analysis UI.

This contract is more specific than a generic global output meter: every active physical/output-matrix channel needs its own protection/level telemetry when that milestone is implemented.

---

# 6. PR34 disposition

This source/test pass does **not** create a new current core-DSP blocker. It makes the later metering milestone more precise and supplies deterministic acceptance criteria that can be independently reimplemented.

The production metering milestone should therefore include explicit tests for:

1. finite meter/RTA behavior through 384 kHz,
2. calibrated peak/RMS and RTA floor/full-scale behavior,
3. VU source selection and bounded VU ballistics,
4. peak/clip hold behavior,
5. demand-gating of expensive analysis work,
6. per-output pre/post-limiter and protection telemetry once the Active Crossover Matrix exists.

The broader PR34 source audit remains active; optimization should remain behind the unresolved core-EQ/spatial parity dispositions documented in the living ledger.
