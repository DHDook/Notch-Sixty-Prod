# PR34 Legacy Analytics / Advanced Metering Audit

Status: **SOURCE AUDIT CONTINUATION — final focused metering/analytics pass supplementing `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This document separates genuine legacy analysis contracts from display-only approximations and mislabeled indicators. The commercial product should preserve useful diagnostics while improving measurement correctness.

## 1. Analytics window is a confirmed live product surface

The legacy Analytics/Meters window explicitly contains:

- Gain Structure,
- Phase Correlation,
- Crest Factor,
- ISP latch indicators,
- DR Factor,
- Bit Stream display,
- nominal Bit Rate / Sample Rate display,
- True Peak,
- Stereo Goniometer.

The window participates in the meter demand-gating contract documented in `PR34_METERING_CONTRACT_AUDIT.md`: analytics processing is enabled only while the relevant meter group/window is active.

**Classification: LATER MILESTONE — Metering / RTA / production analysis UI**, except where the commercial realtime graph already exposes the necessary telemetry foundation.

---

## 2. Phase correlation

Legacy phase correlation is a real realtime-derived metric, not a decorative UI value.

Observable contract:

- range: **-1.0 to +1.0**,
- -1 = anti-phase,
- 0 = uncorrelated,
- +1 = in-phase,
- presented around a center-zero meter,
- UI convention: positive/high correlation is safe/green, negative correlation is warning/red,
- source documentation identifies it as smoothed Pearson L/R correlation.

**Classification: LATER UI MILESTONE; DSP/telemetry concept is valid.**

The commercial implementation should compute correlation from an explicitly documented signal location and averaging window, because those choices materially affect interpretation.

---

## 3. Crest Factor

The legacy analytics bridge computes Crest Factor as the difference between peak and RMS in dB:

`20 * log10(peak / RMS)`

with a silence guard. The inline analytics bridge uses the larger of the L/R input peak values and the larger of the L/R input RMS values.

The legacy dynamics processor also contains a separate realtime crest-factor telemetry value described as measured after the compressor stage. These are therefore not necessarily the same measurement point.

**Classification: LATER MILESTONE — analytics UI, with measurement-point cleanup required.**

Commercial acceptance should name the measurement location explicitly (for example Input Crest Factor or Output Crest Factor) rather than displaying an ambiguous single number sourced from different paths.

---

## 4. DR Factor

The legacy UI's `DR Factor` is not a full EBU/TT Dynamic Range statistic. In the audited bridge it is simply output peak-to-RMS difference, clamped to **0...24 dB**.

**Classification: LATER MILESTONE — analytics UI, but terminology should be improved.**

The commercial product should either:

- label this honestly as output crest factor / peak-to-RMS, or
- implement a documented dynamic-range standard if the label `DR` is retained.

Do not imply standards compliance from the legacy display name alone.

---

## 5. True Peak is a genuine measurement contract

The legacy dynamics processor exposes a continuous final-output true-peak level in dBTP. Source documentation identifies the measurement as using a 4-point FIR interpolator derived from the ITU-R BS.1770 inter-sample-peak approach.

The UI displays:

- continuous dBTP,
- a warning/danger region beginning around **-1 dBTP**,
- an `(approx)` indication when the signal path is not actually running through the 4x oversampled protection path.

The realtime processor also maintains sticky true-peak trip information for clipper/limiter protection conditions.

**Classification: IMPLEMENTED / IMPROVED realtime foundation in the commercial protection engine; LATER MILESTONE for production metering UI.**

Commercial metering should share one authoritative true-peak estimator with protection telemetry or prove equivalent calibration so the limiter and meter cannot disagree materially.

---

## 6. Legacy `ISP` latch is mislabeled and should not be reproduced as-is

The legacy UI labels two sticky indicators `ISP-In` and `ISP-Out`.

However, the audited bridge does **not** drive these latches from the true-peak estimator. It latches them when the ordinary normalized peak-meter value exceeds **0.99**.

Because the normalized level meter maps -60...0 dBFS onto 0...1, this is effectively a near-full-scale **sample-peak** latch, not a demonstrated inter-sample-peak detector.

### Disposition

**KNOWN LEGACY MEASUREMENT/LABELING DEFECT — DO NOT REPRODUCE.**

The commercial analytics UI should either:

- derive overload latches from the actual true-peak/dBTP estimator and label them `True Peak` / `ISP`, or
- retain sample-peak latches but label them honestly as sample clipping/near-clipping.

This removes false parity debt: reproducing the misleading legacy implementation is not required.

---

## 7. Bit Stream display is not a true source bit-depth analyzer

The legacy `Bit Stream` widget presents 24 LEDs and describes them as bit activity.

The audited implementation derives the displayed mask from the current **peak amplitude**, quantizes that one scalar into a 24-bit integer, and lights bits from that integer value.

It does not inspect source PCM word structure, determine effective number of bits, analyze least-significant-bit activity over the actual sample stream, or distinguish genuinely 16/24/32-bit source content.

### Disposition

**LEGACY DISPLAY APPROXIMATION — NOT A PARITY TARGET AS AN ANALYZER.**

If the commercial product includes a bit-depth/bit-activity analyzer, it should analyze actual sample words/statistics over time and clearly distinguish transport format from effective signal resolution. Otherwise this legacy visualization may be omitted without losing real audio functionality.

---

## 8. `Bit Rate` is a nominal transport calculation

The legacy Bit Rate view assumes **32 bits/sample, stereo** and displays:

`sampleRate * 32 * 2`

alongside the current sample rate.

That is a nominal uncompressed Float32 stereo transport rate, not the encoded bitrate of the source media.

### Disposition

**LATER UI / INFORMATIONAL ONLY.**

If retained, commercial labeling should say something like `Processing Format` / `PCM Data Rate` rather than suggesting it is the source-file or streaming-service bitrate.

---

## 9. Gain Structure meter

Legacy Gain Structure is a real telemetry view of stage-specific gain reduction. It displays separate values for:

- De-Esser,
- Multiband Low,
- Multiband Mid,
- Multiband High,
- Compressor,
- Expander,
- Clipper,
- Limiter.

The view refreshes around 30 Hz while analytics metering is enabled.

**Classification: LATER MILESTONE — production dynamics/meters UI.**

The commercial realtime graph already exposes much of the necessary stage telemetry. Production UI should also include any newer commercial protection/headroom stages where useful rather than freezing the display to the legacy list.

---

## 10. Stereo Goniometer

Legacy goniometer behavior is confirmed and independent from the phase-correlation scalar:

- display coordinates use a 45-degree Mid/Side rotation,
- horizontal = `(L - R) / sqrt(2)`,
- vertical = `(L + R) / sqrt(2)`,
- realtime audio feeds a bounded circular buffer,
- UI refresh is approximately **30 Hz**,
- displayed sample window: **512 frames**,
- history capacity: **16,384 frames**,
- phosphor-style trail duration: approximately **1 second**,
- render points are subsampled for UI efficiency,
- low-level display uses sign-preserving logarithmic visual scaling,
- goniometer refresh is demand-gated by window visibility / meter enable state.

**Classification: LATER MILESTONE — Metering / production analysis UI.**

The exact phosphor graphics are not a parity requirement; correct stereo orientation, bounded capture, demand gating and useful low-level visualization are.

---

# 11. PR34 disposition

This final analytics pass does **not** create a new current stereo-core DSP blocker.

Confirmed later analysis requirements:

- phase correlation,
- explicitly located crest-factor telemetry,
- gain-structure telemetry,
- continuous true peak/dBTP,
- stereo goniometer,
- honest processing-format/sample-rate information.

Legacy items to improve or omit rather than recreate literally:

- mislabeled sample-peak `ISP` latch,
- `DR Factor` presented as though it were a formal DR statistic,
- 24-bit `Bit Stream` LEDs derived only from a quantized peak scalar,
- `Bit Rate` wording that can be mistaken for source-media bitrate.

With this pass, the dedicated metering/RTA/analytics source domain is sufficiently classified for PR34's parity-inventory gate. Detailed UI implementation remains attached to the planned Metering / RTA / production-shell milestone.

No production DSP code is changed by this audit slice.
