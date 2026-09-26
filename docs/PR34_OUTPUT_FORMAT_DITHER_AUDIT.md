# PR34 Legacy Dither / Output-Format Contract Audit

Status: **SOURCE AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This audit resolves the outstanding question of whether legacy Dither is current DSP parity debt or belongs to the later output-format/release-hardening milestone.

## 1. Legacy Dither is live, reachable processing

Legacy advanced state persists a user-selectable `DitherMode` with four values:

- Bypass — default,
- TPDF,
- Shaped,
- High Order.

The dynamics UI has a live Dither picker bound to that state, and the processor reads the selected mode in the realtime chain. This is therefore not dead UI/state.

The legacy processor applies the stage at a **24-bit quantisation grid** (`1 / 8,388,608`) and includes:

- flat TPDF noise,
- first-order shaped dither,
- a fifth-order high-order noise-shaping mode,
- rate-dependent high-order shaping behavior with flat-TPDF fallback when high-order shaping is not considered appropriate at very high sample rates.

**Classification of legacy reachability: CONFIRMED LIVE.**

---

## 2. Dither is semantically tied to the output bit-depth boundary

Dither is not equivalent to oversampling, clipping protection, or ordinary floating-point DSP. Its useful place is immediately before a deliberate reduction to a fixed-point output representation.

The current commercial realtime/output architecture processes and transports stereo **Float32** audio. There is no commercial product contract today that says the app itself must truncate the internal signal to 24-bit fixed-point before handing it to CoreAudio.

Reintroducing the legacy stage now would therefore impose a 24-bit quantisation step on an otherwise floating-point path even when the selected device/transport does not require the app to make that reduction.

That would reproduce historical behavior mechanically rather than preserve the best observable commercial behavior.

---

## 3. Commercial disposition

**LATER MILESTONE — final output-format / device-capability / release hardening.**

Dither is not a blocker to the current floating-point DSP graph.

Before commercial dither is implemented, the product must first define:

1. which actual output paths, if any, are intentionally quantized by Notch Sixty,
2. the target bit depth for each such path,
3. whether hardware/CoreAudio already performs the terminal format conversion,
4. whether app-side dither is useful or merely double-dithers an already managed conversion,
5. whether the user should see Dither as a manual expert control or whether it should be selected automatically from the terminal format,
6. whether shaped modes are appropriate at the selected sample rate.

If the commercial app introduces export/render-to-file functionality, Dither also naturally belongs at that explicit fixed-bit-depth export boundary.

---

## 4. Required behavioral compatibility if/when a fixed-point boundary exists

If a later commercial path intentionally reduces to a fixed bit depth, the product should provide at least:

- Bypass,
- unbiased TPDF,
- a documented noise-shaped option where technically appropriate,
- deterministic bounds and finite output,
- no realtime allocations,
- no DC bias introduced by the dither process,
- correct amplitude scaling for the selected bit depth,
- rate-aware behavior for shaped modes,
- explicit tests showing that dither is only applied at the intended terminal quantization boundary.

The commercial algorithm should be independently designed/reviewed rather than copied from the legacy implementation.

---

## 5. Migration rule

Legacy presets may contain a stored Dither selection.

Until the commercial product has an applicable fixed-point output boundary:

- preserve the legacy value in migration metadata if feasible,
- do **not** silently insert a 24-bit quantizer into the Float32 commercial signal path merely to honor that field,
- surface/restore the selected mode once an applicable commercial output/export format supports it.

This is an intentional product-quality improvement, not missing current realtime-DSP parity.

---

# PR34 result

The pending Dither question is resolved:

**Legacy Dither -> CONFIRMED LIVE, but LATER MILESTONE: output-format/release hardening.**

It is removed from the current core-DSP blocker set while remaining an explicit release-parity requirement if Notch Sixty owns a fixed-point terminal conversion.

No production DSP code is changed by this audit slice.
