# PR34 Legacy Spatial / Alignment Contract Audit

Status: **SOURCE AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This audit resolves several Wave-B items that can look superficially equivalent to ordinary balance/delay controls but are not necessarily the same behavior.

## 1. Symmetry Balance is not the same as the commercial linear Balance control

Legacy `Symmetry Balance` is separately enabled and uses the existing `stereoBalancePosition` value over `-1...+1`.

The live legacy processor applies a **constant-power stereo gain matrix** when Symmetry Balance is enabled:

- center preserves unity on both channels,
- moving toward one side changes both channel gains along a constant-power law,
- it is intended as loudness compensation for an asymmetric listening position.

The commercial rewrite currently has a normal Balance control whose gains are bounded attenuation-style Left/Right balance. That is useful product functionality, but it is not behaviorally identical to the legacy constant-power Symmetry Balance stage.

**Classification: MISSING / BLOCKER.**

Recommended commercial treatment: preserve ordinary user Balance as-is and add Symmetry/Listening-Position compensation as a separately named optional stage later in PR34 or the production spatial-controls milestone. Do not silently change the semantics of the existing Balance control.

---

## 2. Panning Gain Matrix is a speaker crossfeed matrix

Legacy source and UI confirm a distinct `Panning Gain Matrix` stage with a Crossfeed control.

Observable transfer behavior is a symmetric two-channel blend:

- `outL = (1 - a) * inL + a * inR`
- `outR = (1 - a) * inR + a * inL`
- `a = 0` is untouched stereo,
- effective `a = 0.5` is mono.

There is an important legacy UI/runtime mismatch:

- the UI exposes a nominal **0...1.0** Crossfeed range,
- the processor setter clamps the effective amount to **0...0.5**.

Therefore values above 0.5 do not create additional audible change in the legacy processor.

This is speaker-oriented crossfeed/panning behavior, not the excluded headphone crossfeed feature.

**Classification: MISSING / BLOCKER unless deliberately removed by product decision.**

If retained, the commercial UI should expose the true effective range rather than reproducing the misleading 0...1 legacy slider. A legacy-state importer should clamp old values above 0.5.

---

## 3. Crosstalk Cancellation is a separate speaker-processing stage

Legacy source confirms an independently enabled speaker `Crosstalk Cancellation Matrix` after the panning stage.

User-visible state includes:

- Amount: **0...1**, default **0.5**,
- Head-Shadow frequency: **200...2000 Hz** in UI, default **700 Hz**,
- product guidance associates lower Head-Shadow frequencies with narrower speaker angles and approximately 700 Hz with ~60-degree spacing.

The live source describes the stage as cross-channel cancellation with frequency-shaped/head-shadow behavior. This is not equivalent to simple channel balance, M/S EQ, stereo widening, or the Panning Gain Matrix.

**Classification: MISSING / BLOCKER unless deliberately moved out of product scope.**

A commercial implementation should be independently designed and should include explicit stability, mono-compatibility, head-movement robustness, gain/headroom and bypass-transition tests. It should not be recreated from legacy implementation expression.

---

## 4. Speaker IR Alignment is distinct from signed L/R speaker delay

Legacy `Speaker IR Alignment` exposes:

- enable/disable,
- Fine Delay: **0...5 ms**, 0.01 ms UI resolution,
- fractional-sample delay behavior,
- stated purpose: acoustic-center alignment in multi-driver speaker systems.

In the legacy dynamics chain this alignment stage is distinct from the later inter-channel stereo time-delay/balance stage.

The commercial rewrite already has a high-quality signed inter-channel L/R speaker-alignment delay. That satisfies the two-speaker listening-position alignment use case, but it does not by itself reproduce the legacy **multi-driver/output-path acoustic-center** workflow.

**Classification: LATER MILESTONE — Active Crossover Matrix / per-output driver processing.**

Do not add a redundant common stereo delay now merely to match the old toggle. Preserve the behavioral requirement as per-output/driver fractional delay where it becomes meaningful in the commercial active-crossover graph.

---

## 5. Sub-Bass Phase Alignment is an all-pass phase tool, not just polarity or delay

Legacy source confirms a separately enabled `Sub-Bass Align` stage with:

- alignment frequency, default **80 Hz**,
- Q, default **0.7**,
- all-pass phase rotation around the chosen region,
- product intent of aligning sub-bass and mains phase near crossover without changing magnitude response materially.

The commercial bass-management foundation currently provides crossover, sub gain, polarity and speaker timing/alignment controls, but no equivalent tunable all-pass phase-alignment stage in the stereo graph.

**Classification: MISSING / BLOCKER for bass-management parity.**

Recommended commercial treatment: implement as an optional independently designed all-pass phase stage associated with the sub/mains crossover, after the current crossover topology is stable. Validate magnitude transparency, phase rotation, finite behavior through 384 kHz, bypass transitions and interaction with polarity/time alignment.

---

## 6. Resulting Wave-B disposition

After this source pass:

- **Symmetry Balance** -> confirmed distinct, **MISSING / BLOCKER**.
- **Panning Gain Matrix** -> confirmed live speaker crossfeed, **MISSING / BLOCKER unless explicit product removal**.
- **Crosstalk Cancellation** -> confirmed distinct speaker processing, **MISSING / BLOCKER unless explicit product removal**.
- **Speaker IR Alignment** -> **LATER MILESTONE: Active Crossover Matrix / per-output driver processing** rather than a current stereo-core blocker.
- **Sub-Bass Phase Alignment** -> confirmed distinct all-pass crossover tool, **MISSING / BLOCKER**.

The commercial signed L/R delay, ordinary Balance, Stereo Widener and bass-management polarity controls remain valid improvements/features, but none should be used to mark the distinct legacy behaviors above as implemented without matching the actual observable contract.

No realtime code is changed by this audit slice.
