# PR34 Legacy Active-Crossover / Measurement Contract Audit

Status: **SOURCE/TEST AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This audit distinguishes reachable legacy output-matrix/crossover behavior from comments, task-spec remnants, and controls that were present in UI but had no effective implementation. The commercial Active Crossover milestone should preserve useful observable workflows while explicitly avoiding known legacy defects.

## 1. Output-channel EQ editor: actual reachable controls are narrower than its comments claim

`OutputChannelEQView` contains comments stating that the output-channel editor should mirror the main EQ and support all filter types/slopes. The actual rendered `bandEditor`, however, exposes only:

- per-band bypass,
- frequency,
- gain,
- Q.

The actual view does **not** render a filter-type picker or slope picker in the audited source, despite comments saying those controls should exist.

Other reachable controls in the same view include:

- EQ / Linear / Mixed / Flat / Delta compare-mode picker where capabilities allow,
- Linked / Stereo / Mid-Side channel-mode picker where capabilities allow,
- input/output gain,
- global bypass,
- Flatten,
- optional output-EQ oversampling toggle,
- detected-resonance panel with add-to-EQ actions.

### Disposition

The comments/spec text alone must **not** be treated as evidence that per-output filter-type/slope editing was actually user-reachable in this version.

**Classification:** output-channel EQ as a whole remains **LATER MILESTONE — Active Crossover Matrix**, but filter-type/slope picker parity is **not established by this view**. The commercial output-channel editor should instead be designed consistently with the final commercial main-EQ model when that milestone is implemented.

---

## 2. Crossover analysis panel is a real multi-step workflow

The reachable `CrossoverAnalysisView` has five analysis modes:

1. Group Delay
2. Summation
3. Optimise
4. Time Alignment
5. Verification

This confirms that the legacy active-crossover feature was not merely filter creation/routing. Measurement and validation were part of the user workflow.

**Classification:** **LATER MILESTONE — Active Crossover Matrix + Room Correction measurement infrastructure.**

---

## 3. Group-delay analysis and correction

Reachable behavior includes:

- compute per-output group-delay curves,
- inspect adjacent enabled output channels around crossover frequencies,
- flag mismatch when crossover-region delay disagreement is material,
- fit/apply all-pass group-delay correction,
- persist the resulting all-pass coefficients into the affected output-channel configuration.

The legacy UI uses approximately 1 ms mismatch as the trigger for an auto-correction suggestion.

### Commercial acceptance contract

The later commercial matrix should support:

- measured/predicted group-delay visualization per output,
- adjacent-driver comparison around each active crossover,
- a reviewable correction suggestion,
- explicit apply rather than hidden mutation,
- per-output persistence of the resulting correction,
- verification after correction.

The exact fitting algorithm is not a parity requirement and must be independently designed.

---

## 4. Acoustic summation

Reachable Summation behavior includes:

- predicted acoustic summation from individual output paths,
- individual channel-response context,
- a live microphone/RTA overlay,
- explicit warning that predicted summation assumes simplified geometry and that real acoustic result depends on driver placement, diffraction and listening position.

**Classification:** **LATER MILESTONE — Active Crossover + measurement UI.**

The commercial version should preserve the distinction between electrical/predicted summation and measured in-room verification.

---

## 5. Crossover optimiser: only a subset of the displayed options is actually implemented

Legacy `OptimisationParameters` exposes four toggles:

- optimise crossover frequencies,
- optimise crossover slopes,
- optimise delay,
- optimise per-output EQ.

The audited optimiser implementation actually uses:

- **crossover-frequency optimisation**, and
- **per-output EQ optimisation**.

The `optimiseCrossoverSlopes` and `optimiseDelay` fields are declared and surfaced by UI, but are not consumed by the optimisation loop in the audited source.

### Disposition

- Crossover-frequency optimisation -> **CONFIRMED LIVE**.
- Per-output EQ optimisation -> **CONFIRMED LIVE**.
- Optimise crossover slopes toggle -> **LEGACY-DEAD / NO EFFECT in this optimiser path**.
- Optimise delay toggle -> **LEGACY-DEAD / NO EFFECT in this optimiser path**.

The commercial product should not reproduce no-op options. Delay alignment belongs to the dedicated measured time-alignment workflow; slope optimisation may be added later only if a real independently designed optimiser supports it.

---

## 6. Optimiser observable parameters

The live optimiser establishes these user/behavioral defaults and limits:

- optimisation range: 20 Hz to 20 kHz,
- default target: Harman room target,
- maximum iterations: 200,
- convergence threshold: 0.05 dB change in weighted/RMS error,
- maximum crossover-frequency step: 50 Hz,
- maximum per-output EQ adjustment per iteration: 1 dB,
- maximum total per-output EQ correction: 12 dB,
- residual smoothing: 1/3 octave,
- starting and final RMS error are reported,
- convergence state and iteration count are reported,
- optimiser operates on copies/suggestions rather than intentionally mutating the realtime graph while searching.

**Classification:** **LATER MILESTONE acceptance evidence**, not an instruction to preserve the same optimisation algorithm or numerical tuning if the commercial optimiser can do better.

---

## 7. Legacy optimiser Apply-All path contains an internal result-semantics inconsistency

The audited optimiser constructs `suggestedEQAdjustments` as **gain deltas** relative to the original output EQ and returns only materially changed bands. The UI `applyOptimisationResult` path then assigns those returned bands directly to the channel EQ band array as though they were a complete absolute configuration.

That means the source path does not establish a trustworthy desired “Apply All” EQ result contract; it appears to mix delta and absolute semantics.

### Disposition

**KNOWN LEGACY DEFECT — DO NOT REPRODUCE.**

The commercial optimiser must use an unambiguous result type:

- either return an absolute candidate output configuration,
- or return typed deltas that are explicitly applied to a known base revision.

It should also reject application if the live base configuration changed after optimisation began.

---

## 8. Broadband driver time alignment

The legacy measured time-alignment workflow is well-defined:

- requires at least two measured output channels,
- searches each averaged impulse response's direct-sound region (default first 50 ms),
- arrival time is the sample index of the largest absolute IR peak,
- the **latest-arriving** channel is the reference,
- earlier-arriving channels receive positive delay to match it,
- suggested delays are clamped to 0...100 ms,
- the user can review/apply the result to per-output delay fields.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / measurement alignment.**

This is the correct location for the legacy multi-driver IR-alignment use case identified in the spatial audit.

---

## 9. Polarity detection

The legacy measurement workflow distinguishes electrical polarity from crossover/acoustic phase behavior.

Observable contract:

- inspect the sign of the direct-sound IR peak,
- positive peak -> Correct,
- negative peak -> Inverted,
- insufficient SNR -> Uncertain,
- default direct-sound search window: 50 ms,
- default minimum SNR for a confident result: 20 dB,
- UI must warn that a deliberate acoustic/crossover polarity inversion can be valid even when electrical polarity differs.

**Classification:** **LATER MILESTONE — Active Crossover measurement.**

The commercial app should present this as a diagnostic/suggestion, not blindly flip polarity from one measurement.

---

## 10. Acoustic-centre refinement at crossover

Legacy source also supports a second alignment step based on measured group delay near the crossover frequency rather than broadband IR arrival time.

Observable intent:

- use the measured complex response near the crossover,
- compare group delay among participating outputs,
- choose the path with largest group delay as reference,
- compute non-negative compensating delays for earlier paths,
- replace/refine the broadband per-output delay result,
- clamp to the same output-delay bounds.

**Classification:** **LATER MILESTONE — Active Crossover measurement.**

A commercial implementation should use robust phase unwrapping/interpolation and measurement-confidence handling rather than copying the simple legacy finite-difference method.

---

## 11. Baffle-step calculator and apply semantics

Legacy tests establish these observable acceptance points:

- transition frequency is based on driver-to-nearest-edge distance,
- for a centred driver, default edge distance is half baffle width,
- transition relation tested by legacy QA is `c / (2π * edgeDistance)`,
- explicit driver-to-edge distance overrides the half-width assumption,
- theoretical full compensation recommendation is +6 dB,
- applying the recommendation adds exactly one active Low-Shelf EQ band,
- applied shelf frequency is transition frequency / 1.5,
- if the output channel is already at the EQ-band limit, application is rejected rather than overflowing capacity.

**Classification:** **LATER MILESTONE — speaker/driver setup assistance.**

The calculator is a recommendation tool; the commercial product may present geometry-aware or measurement-aware compensation more conservatively.

---

## 12. Diaphragm-resonance detection and correction

Legacy tests establish:

- resonance candidates are detected from measured magnitude response,
- a candidate has frequency, prominence, estimated Q and confidence,
- suggested corrective band is a Notch,
- suggested notch cut is proportional to measured prominence; legacy test expects approximately `-0.8 * prominence dB`,
- the suggested cut must be negative and bounded,
- applying one candidate adds one notch,
- applying multiple candidates adds one per candidate until capacity,
- higher-prominence candidates are applied first.

The reachable output-EQ panel displays candidate frequency, prominence, Q/confidence and explicit Add/Add All actions.

**Classification:** **LATER MILESTONE — measurement-assisted per-output EQ.**

The commercial detector/correction strength may be improved, but user review and bounded correction should remain explicit.

---

## 13. Verification is part of the workflow

The legacy analysis container includes a dedicated Verification mode and combined multi-driver measurement workflow. The broader measurement source also distinguishes individual-output measurements from combined-channel measurements.

**Classification:** **LATER MILESTONE — Active Crossover + Room Correction measurement.**

Commercial acceptance should require re-measurement after alignment/crossover optimisation rather than treating predicted improvement as proof of acoustic improvement.

---

# 14. PR34 disposition

Nothing in this audit creates a new **current stereo-core** blocker. It makes the later Active Crossover milestone more exact and removes false parity debt created by no-op or comment-only legacy controls.

Confirmed later-milestone behavior:

- per-output EQ/gain/delay/polarity framework,
- group-delay analysis/correction,
- predicted summation + measured overlay,
- crossover-frequency optimisation,
- per-output EQ optimisation,
- broadband driver time alignment,
- polarity diagnosis,
- crossover-frequency acoustic-centre refinement,
- baffle-step recommendations,
- diaphragm-resonance suggestions,
- combined-system verification.

Legacy behaviors that should **not** be recreated as-is:

- no-op slope-optimisation toggle,
- no-op delay-optimisation toggle,
- comments claiming output-channel filter/slope controls that the audited rendered view does not actually expose,
- ambiguous delta-vs-absolute optimiser Apply-All behavior.

No production DSP code is changed by this audit slice.
