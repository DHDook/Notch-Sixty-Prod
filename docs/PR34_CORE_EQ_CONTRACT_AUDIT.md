# PR34 Legacy Core-EQ Contract Audit

Status: **SOURCE/TEST AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This document records observable core-EQ behavior established from the legacy product source/UI/tests and maps it against the commercial rewrite. Legacy implementation expression is not an implementation source. New DSP work must be independently designed from public DSP references and the behavioral contracts below.

## 1. Mid/Side EQ — confirmed live product behavior

The legacy product exposes three channel modes: Linked, independent Stereo, and Mid/Side. Mid/Side is not merely a UI alias for Left/Right:

- Mid and Side have independently editable EQ states and band counts.
- Mid state is stored in the legacy left-state slot and Side state in the right-state slot.
- The live render path explicitly converts physical L/R to M/S before EQ and converts M/S back to L/R afterward.
- The observable scaling convention is:
  - `Mid = 0.5 * (L + R)`
  - `Side = 0.5 * (L - R)`
  - `L = Mid + Side`
  - `R = Mid - Side`
- This convention is unity-preserving on encode/decode when no processing is applied.

Legacy Dynamic EQ has a separate limitation: its UI explicitly states that Dynamic EQ applies identically to all channels even while Stereo or Mid/Side editing is selected. Therefore independent dynamic Mid and Side detectors are **not** required for legacy parity.

### Commercial mapping

The commercial realtime kernel already has:

- separate left/right filter state per render slot,
- explicit Left/Right/Stereo channel masks,
- 128 realtime render slots for up to 64-band independent stereo state,
- independent Left/Right user-band collections,
- minimum- and linear-phase EQ paths.

That architecture can represent Mid/Side by interpreting the two channel lanes as Mid and Side only within the EQ region, but the encode/decode must wrap **both** the minimum-phase biquad path and the linear-phase convolution path. A Minimum-Phase-only implementation would be incomplete.

**Classification: MISSING / BLOCKER.**

Implementation should be a dedicated later slice in PR34 after the simple filter-family blockers, with deterministic identity, Mid-only, Side-only, stereo-image, Minimum-Phase, Linear-Phase, Reference and Delta tests.

---

## 2. Band Pass — confirmed simple filter-family blocker

The legacy filter picker exposes Band Pass as an ordinary per-band filter type. Its observable contract is:

- center frequency control,
- Q/bandwidth control,
- constant **0 dB peak gain** at the center frequency,
- no meaningful user gain parameter,
- no multi-slope behavior.

The commercial C biquad family currently has Peak, Low Shelf, High Shelf, Low Pass, High Pass, Notch and All-Pass, but no Band Pass.

### Independent implementation source

The commercial implementation should use the public W3C/Web Audio **Audio EQ Cookbook** Band-Pass definition (`BPF (constant 0 dB peak gain)`) rather than legacy implementation code:

`https://webaudio.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html`

**Classification: MISSING / BLOCKER — ready for immediate clean-room implementation.**

Acceptance requirements:

1. center-frequency magnitude approximately unity / 0 dB,
2. attenuation below and above the pass band,
3. higher Q narrows the pass band,
4. finite coefficients and output through every supported rate up to 384 kHz,
5. Minimum-Phase support,
6. Linear-Phase support through the existing magnitude-derived FIR designer,
7. no realtime allocation or coefficient design.

---

## 3. Constant-Q Parametric — confirmed distinct processor behavior

Legacy UI exposes Constant-Q only for Parametric bands. The product description states:

- Constant-Q ON: bandwidth remains fixed as gain changes.
- Constant-Q OFF: existing proportional-Q behavior remains the default.

Legacy regression tests explicitly require Constant-Q and proportional-Q to produce different responses for the same center frequency, Q and nonzero gain. Full preset reload and incremental live editing are also required to produce the same result.

The commercial model currently has only the existing peaking path and no per-band Constant-Q mode.

**Classification: MISSING / BLOCKER.**

This is a single-section capability but requires an independently sourced/design-reviewed constant-Q transfer function plus persistence/model state. It should follow Band Pass rather than be combined with the larger multi-section slope work.

---

## 4. Linkwitz Transform — confirmed four-parameter speaker-alignment filter

The legacy Linkwitz Transform is a real user-facing EQ type for sealed-box speaker alignment, not a generic shelf preset.

Observable controls/semantics:

- existing resonance frequency `f0`,
- existing enclosure Q `Q0`,
- target resonance / extension frequency `fp`,
- target Q `Qp`,
- `fp` is independently stored and must not be replaced by a fixed `f0 * 0.7` assumption,
- UI labels explicitly expose Resonance (`f0`), Box Q (`Q0`), Target Freq (`fp`) and Target Q (`Qp`).

Legacy regression tests specifically guard that an explicit `fp` changes behavior relative to the default/fallback.

The commercial `EQBand` currently has only frequency, gain and Q, so the product model cannot yet represent all four parameters.

**Classification: MISSING / BLOCKER.**

This needs a model extension plus an independently authored digital Linkwitz Transform design. Do not overload ordinary gain semantics internally without a typed model field for `Qp` / target alignment.

---

## 5. Tilt EQ — confirmed compound two-sided tonal control

Legacy filter metadata defines Tilt EQ as simultaneous complementary low/high shelving around a pivot frequency. The legacy product exposes it as one band in the filter picker.

Observable contract:

- one pivot frequency,
- one signed tilt amount,
- complementary low/high tonal movement around that pivot,
- represented to the user as one band even though it is a compound response.

The commercial one-section-per-band snapshot cannot express this compound response without either expanding the model band into multiple realtime sections or introducing a typed compound-band representation.

**Classification: MISSING / BLOCKER.**

Implement with the same section-expansion infrastructure chosen for slope control so compound bands remain one user band while compiling to multiple realtime sections.

---

## 6. Main-EQ slope control — confirmed 6 through 96 dB/oct

The legacy product exposes these values:

- 6
- 12
- 18
- 24
- 36
- 48
- 60
- 72
- 84
- 96 dB/oct

Slope is behaviorally meaningful for:

- Low Pass,
- High Pass,
- Low Shelf,
- High Shelf.

The default for legacy state that predates slope storage is 12 dB/oct.

The commercial realtime model currently stores exactly one biquad coefficient set per user band. That is insufficient for the high-order slope contract. Simply spending extra entries from the existing 128 render-slot pool is not robust: 64 user bands at up to 8 sections per band exceeds the slot budget and would make user-band capacity depend on filter choices.

**Classification: MISSING / BLOCKER — structural.**

Recommended clean commercial architecture:

- keep the product limit at 64 **user bands**,
- add a bounded per-band compiled-section representation or a separate compiled EQ program,
- design all section coefficients on the control plane,
- keep fixed/preallocated realtime state,
- retain click-free program/section transitions,
- expose diagnostics in user-band terms rather than leaking compiled section count as band count.

This same infrastructure should support Tilt EQ cleanly.

---

## 7. Per-band FIR

Resolved separately in `PR34_FIR_WORKFLOW_AUDIT.md`.

**Classification: MISSING / BLOCKER.**

Per-band FIR is its own kernel slot/workflow and must not be collapsed into the existing global convolution/room-correction slot without an explicit product redesign.

---

## 8. Mixed Phase — confirmed distinct from measurement excess-phase correction

Legacy `CompareMode` includes a distinct `mixedPhase` mode alongside normal EQ and Linear EQ.

The source-level product structure confirms that Mixed Phase is not merely another name for room-measurement excess-phase correction:

- Mixed Phase derives phase-correction/all-pass work from the active EQ chain itself.
- It has per-channel all-pass correction state.
- It includes the user EQ and room-correction EQ layers in its active-chain phase analysis.
- Measurement-derived excess-phase correction is a separate path with separate configuration and measurement inputs.

The commercial rewrite currently exposes Minimum Phase and Linear Phase only.

**Classification: MISSING / BLOCKER — structural.**

The commercial implementation should be independently designed around a documented target (for example group-delay reduction subject to magnitude transparency and bounded latency), not by translating the legacy fitting implementation. This should follow completion of the simpler core filter-family/model work because it depends on a stable compiled EQ representation.

---

# 9. Recommended PR34 core-EQ implementation order

The audit supports this order:

1. **Band Pass** — isolated one-section filter family; independently specified by W3C Audio EQ Cookbook.
2. **Constant-Q Parametric** — isolated one-section behavior plus model flag.
3. **Linkwitz Transform** — one logical band, extra typed parameters, independently designed transfer function.
4. **Compiled multi-section EQ program** — structural prerequisite for high-order slopes and compound Tilt.
5. **6–96 dB/oct slopes + Tilt EQ** on that compiled representation.
6. **Mid/Side EQ** wrapping both minimum- and linear-phase paths, while retaining linked Dynamic-EQ behavior.
7. **Per-band FIR** with explicit kernel ownership/latency contract.
8. **Mixed Phase** after the product's final compiled EQ representation is stable.

Optimization/profile work remains gated behind this parity work. PR34 should not optimize the old core-EQ representation first and then immediately replace it to satisfy known parity blockers.
