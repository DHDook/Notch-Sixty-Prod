# PR34 Legacy Room-Correction / Measurement Contract Audit

Status: **SOURCE/TEST AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This audit records the observable room-measurement and correction workflows present in the legacy product and separates them from implementation details that must be independently redesigned for the commercial rewrite.

## 1. Transfer-function measurement is a real multi-position workflow

The legacy product exposes both **Individual** and **Combined** measurement modes.

Individual measurement can target:

- the Main Chain, or
- selected output-matrix channels individually.

Combined measurement can play selected output channels together for direct comparison against the sum of previously measured individual responses.

User-selectable measurement parameters are:

- microphone input device,
- microphone positions: **1...5**, default **1**,
- sweeps per position: **1...5**, default **3**,
- sweep duration: **5...30 s**, default **10 s**,
- minimum-SNR display threshold: **20...50 dB**, default **30 dB**.

The generated measurement sweep is an exponential/log sweep from **20 Hz to 20 kHz** at the active processing sample rate.

Between positions, the workflow explicitly pauses and asks the user to reposition the microphone before continuing.

**Classification: LATER MILESTONE — Room Correction / measurement UI.**

The commercial version should preserve multi-position/multi-sweep measurement as a first-class workflow rather than reducing room correction to one imported frequency-response curve.

---

## 2. Measurement SNR and the legacy minimum-SNR control

The legacy engine estimates SNR from the impulse response using:

- RMS around the direct-sound peak, and
- RMS of a pre-onset noise window.

The source comments describe approximately **40 dB or better** as a good room measurement.

However, the `minSNRDB` value passed into the multi-channel measurement routine is not used to reject, retry, or exclude low-SNR sweeps in the audited measurement function. It is used by the results UI as an acceptance/warning threshold.

### Disposition

The minimum-SNR slider is **not** evidence of an automatic legacy measurement-rejection algorithm.

For the commercial product, low-SNR handling should be improved explicitly:

- report measured SNR,
- warn when a sweep falls below the selected quality threshold,
- offer retry/exclusion before averaging,
- do not silently discard data without user-visible rationale.

**Classification: LATER MILESTONE; legacy UI threshold semantics should not be overstated.**

---

## 3. Multi-sweep / multi-position averaging

Legacy room correction does more than simple magnitude averaging.

The source-level averaging contract includes:

- time-align impulse responses to a common direct-sound reference,
- weight repeated sweeps using measured SNR,
- produce an averaged impulse response,
- derive averaged complex and magnitude response from that IR,
- preserve complex response so phase-aware comparison/correction remains possible.

The engine comments further state that, for multiple positions, sweeps are averaged within each position and positions receive equal spatial weighting rather than letting one seat dominate merely because it had more repeats.

A separate seat-based workflow also stores complex seat responses and supports user weights bounded to **0.25...2.0**, with equal weight **1.0** as the default.

A prior first-seat bias is explicitly called out in the legacy source as a correctness bug that was fixed; the current audited behavior uses flat default weighting.

**Classification: LATER MILESTONE — multi-seat Room Correction.**

The commercial design should retain complex-domain/spatially fair averaging and should not revert to first-seat bias or raw dB averaging.

---

## 4. Reflection-free / time-windowed measurement

The legacy product has an optional reflection-free window before frequency-response calculation.

Current default state:

- disabled by default,
- default window duration: **80 ms**.

The legacy engine supports:

- automatic onset near the IR direct-sound peak,
- typical window durations in roughly the **20...200 ms** range,
- cosine tapering at the edges,
- default taper approximately **5 ms**.

The raw IR is preserved for visualization while the optionally windowed IR can be used to compute the correction response.

**Classification: LATER MILESTONE — measurement analysis.**

The commercial UI should make clear that shortening the time window trades low-frequency resolution for reduced room-reflection contamination rather than presenting “reflection free” as an absolute physical guarantee.

---

## 5. Microphone calibration is a confirmed workflow

The legacy calibration loader accepts plain-text calibration files with:

- frequency in Hz,
- deviation in dB,
- whitespace-separated columns,
- `*` and `#` comment lines,
- positive frequencies,
- log-frequency interpolation between points.

The product additionally supports a **dual-calibration** mode:

- free-field calibration,
- diffuse-field calibration,
- Schroeder-frequency transition,
- default Schroeder frequency **300 Hz**,
- configured range **100...1000 Hz**,
- default transition width **1 octave**,
- smooth/cosine crossfade between diffuse-field correction at low frequencies and free-field correction at high frequencies.

**Classification: LATER MILESTONE — Room Correction measurement setup.**

The commercial implementation may support additional standard calibration formats, but single-file microphone calibration and the documented hybrid free/diffuse workflow are confirmed legacy capabilities.

---

## 6. Built-in target curves

The legacy target library exposes:

- Flat,
- Harman room,
- B&K house,
- Home theater,
- X-Curve (cinema),
- Sub-only.

Custom target curves are also supported elsewhere in the room-correction coordinator and are persisted with room-correction presets when applicable.

The legacy source contains some stale/misleading wording around the Harman target (“over-ear”) even though the actual curve and adjacent engine documentation identify it as the loudspeaker-room target. That wording should not be reproduced.

**Classification: LATER MILESTONE — Room Correction target selection.**

The commercial product should independently validate/re-document built-in target definitions before release rather than inheriting legacy comments uncritically.

---

## 7. Three correction modes are user-visible product concepts

The legacy multi-channel correction result supports three distinct modes:

1. **Parametric EQ (IIR)**
   - up to 20 correction bands in the legacy correction engine,
   - zero additional convolution latency,
   - intended for relatively simple/subtle magnitude correction.

2. **Minimum-phase FIR — magnitude only**
   - magnitude correction through FIR convolution,
   - legacy defaults use a 4096-tap design path unless another tap count is supplied.

3. **FIR + phase correction**
   - FIR magnitude correction plus separately derived excess-phase/all-pass correction.

The third mode is explicitly distinct from the legacy **Mixed Phase EQ compare mode** documented in the core-EQ audit. Measurement-derived excess-phase correction uses a measured impulse response; Mixed Phase EQ derives correction from the active EQ filter chain.

**Classification: LATER MILESTONE — Room Correction.**

The commercial convolution runtime already supplies an important implementation foundation, but these measurement/design/application workflows are not yet product-complete.

---

## 8. IIR room-correction fitting contract

The legacy correction engine's observable bounds are:

- maximum correction bands: **20**,
- maximum individual correction boost/cut: **±12 dB**,
- fitting may stop when the largest residual error falls below approximately **0.5 dB**,
- correction bands are parametric filters.

A separate call path commonly defaults to **16** maximum bands for per-channel application.

**Classification: LATER MILESTONE acceptance evidence.**

These values are useful compatibility/tuning references, not a mandate to reproduce the same greedy fitter. The commercial fitter should be independently designed and should favor conservative correction, robust smoothing/regularization, and explicit correction-range controls.

---

## 9. FIR correction behavioral requirements

Legacy source confirms the following product-level intentions:

- correction = target minus measured response,
- bounded correction gain,
- high-frequency smoothing to avoid chasing measurement noise,
- regularization/noise-floor protection so low-confidence bins are not aggressively boosted,
- minimum-phase reconstruction for magnitude-only correction,
- configurable FIR tap count,
- independent per-channel correction is supported by calling the design path per measured channel.

**Classification: LATER MILESTONE — Room Correction FIR design.**

The commercial FIR design must be independently implemented and verified. Legacy FFT/cepstrum implementation details are not an implementation source.

---

## 10. Excess-phase correction

Legacy measured correction can derive minimum-phase content from the measured IR, calculate excess phase, and fit all-pass correction coefficients when the user chooses FIR + Phase Correction.

This is a measurement-derived acoustic correction workflow and is separate from:

- ordinary All-Pass EQ bands,
- the legacy Mixed Phase EQ mode,
- crossover group-delay correction.

**Classification: LATER MILESTONE — Room Correction phase correction.**

The commercial design should require phase-confidence/measurement-quality checks and bounded correction rather than assuming every measured phase feature should be inverted.

---

## 11. Individual vs combined measurement is a verification contract

The Combined mode measures multiple outputs playing together and can overlay a complex-domain sum of prior individual measurements.

The distinction is important:

- the sum of individually measured responses is a prediction based on those separate measurements,
- the combined measurement is the real acoustic result when the selected outputs operate together.

**Classification: LATER MILESTONE — verification.**

This should be retained because it exposes cancellation/summation effects that are not visible from magnitude-only inspection of separate drivers.

---

## 12. Measurement/correction persistence is richer than ordinary EQ presets

Legacy transfer-function datasets persist separately from `.eqpreset` files.

The dataset store records:

- channel metadata,
- sample rate,
- capture date,
- mic-position count,
- sweeps-per-position,
- averaged IRs as 32-bit floating-point WAV,
- correction metadata/results as JSON,
- FIR kernels as separate float WAV files,
- IIR correction bands,
- excess-phase coefficients,
- correction mode,
- target curve,
- optional residual/verification response.

The ordinary dataset loader does not reconstruct every raw sweep; the persisted artifact is primarily the averaged measurement/correction set.

**Classification: LATER MILESTONE — measurement library / correction presets.**

The commercial persistence format should be newly versioned and atomic rather than copying legacy directory/file structures, but it must preserve equivalent user-owned measurement/correction assets.

---

## 13. Room-correction preset state

Legacy room-correction presets independently preserve product state such as:

- selected target curve,
- custom target curve where applicable,
- seat measurements,
- measured response,
- microphone calibration,
- fitted room-correction bands,
- FIR correction state/resource information where applicable.

This is separate from ordinary musical `.eqpreset` persistence.

**Classification: LATER MILESTONE — Room Correction preset management.**

The commercial app should keep “listening/music preset” and “measurement/correction project” concepts distinct enough that loading a musical preset cannot accidentally destroy measurement assets.

---

## 14. Measurement analysis views

The legacy source tree includes dedicated measurement views for:

- Impulse Response,
- Step Response,
- Energy Decay,
- Group Delay.

These complement the magnitude-response and crossover-analysis views documented elsewhere.

**Classification: LATER MILESTONE — Metering / Room Correction analysis UI.**

Exact visual design is not a parity requirement, but access to time-domain and phase/delay diagnostics is a confirmed product capability.

---

# 15. Known legacy limitations / non-targets

The commercial rewrite should not mechanically reproduce these legacy weaknesses:

- the minimum-SNR slider is not an automatic sweep acceptance/rejection mechanism in the audited measurement routine,
- stale target-curve comments contain terminology inconsistent with the actual loudspeaker-room intent,
- legacy persistence is split across several ad-hoc structures/directories,
- measurement algorithms often use fixed defaults that should become explicitly documented, validated commercial controls where users benefit from them.

---

# 16. PR34 disposition

This source pass does **not** add a new current stereo-core DSP blocker. It confirms that the planned Room Correction milestone must include more than a convolution engine:

- physical microphone measurement,
- 20 Hz–20 kHz log sweeps,
- multi-sweep and multi-position capture,
- SNR/quality reporting,
- optional reflection-reduced IR windowing,
- microphone calibration,
- complex-domain averaging,
- built-in/custom target curves,
- IIR correction,
- FIR magnitude correction,
- measurement-derived excess-phase correction,
- individual-vs-combined verification,
- correction/measurement persistence,
- IR/step/decay/group-delay analysis.

The commercial convolution and room-correction runtime foundations can therefore be classified as **IMPLEMENTED / IMPROVED foundation**, while the complete measurement/design/persistence product workflow remains **LATER MILESTONE — Room Correction / production UI**.

No production DSP code is changed by this audit slice.
