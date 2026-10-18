# PR34 Legacy FIR Workflow Audit

Status: **SOURCE AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This audit resolves the previously pending question of whether the legacy product's per-band FIR, advanced `FIR Impulse Response`, and global `FIR Correction` controls were merely duplicate UI labels for one convolution path.

They were not. The legacy source exposes three distinct user-facing FIR concepts.

# 1. Per-band FIR is a real EQ-band mode

`EQBandSliderView` exposes `.fir` as an ordinary EQ band filter type with its own per-band `Load IR…` / `Clear` actions and per-band IR display name.

When a band is FIR:

- ordinary Frequency editing is disabled,
- ordinary Gain editing is disabled,
- ordinary bandwidth/Q editing is disabled,
- ordinary slope editing is disabled,
- the band's own FIR kernel load/clear controls are shown.

This establishes a genuine **per-band kernel slot**, not merely a shortcut to a global convolution file picker.

### Disposition

**MISSING / BLOCKER — core EQ parity.**

The commercial main-EQ product model does not currently expose the legacy per-band FIR/IR filter type. This remains a real core-EQ parity item in PR34.

The clean-room reimplementation does not need to copy the legacy convolution implementation. It must independently define the commercial per-band FIR contract, including realtime-safe kernel staging, state transitions, latency accounting, and interaction with Minimum/Linear/Mixed phase modes.

---

# 2. Advanced `FIR Impulse Response` is a separate global processor

The legacy Dynamics UI explicitly describes `FIR Impulse Response` as loading a user-supplied IR and states that it is **distinct from FIR Correction's convolution slot**.

It has its own:

- enable state under `AdvancedProcessingConfig.firImpulseResponse`,
- left/right IR arrays,
- sample-rate/tap-count state,
- `Load IR…` action via `loadFIRImpulseResponse(url:)`,
- `Clear` action via `clearFIRImpulseResponse()`,
- processor enable state (`_firEnabled`),
- independent render-stage execution inside `DynamicsProcessor` before stereo-mode fold-down and the later core dynamics chain.

The loader writes the IR into `advanced.firImpulseResponse` and applies it through the DynamicsProcessor FIR stage; it does not write the global `convolutionConfig` slot.

### Disposition

**CONFIRMED DISTINCT LEGACY CAPABILITY.**

For commercial parity this must not be dismissed merely because a separate global convolution engine already exists.

However, the legacy definition explicitly covered both headphone and speaker correction. Headphone-only behavior is outside current Notch Sixty product scope, while raw speaker-correction IR loading is in scope. Therefore the required commercial behavior should be resolved by product semantics rather than by reproducing duplicate architecture mechanically.

The parity question is:

> Must the commercial product support two simultaneously active independent global speaker-correction convolution slots, or can the observable in-scope speaker behavior be represented coherently through the existing global FIR/room-correction convolution architecture without loss of supported presets/workflows?

Until that is explicitly resolved, classify the advanced FIR-IR slot as **MISSING / PRODUCT-DISPOSITION BLOCKER**, not as implemented and not as dead.

---

# 3. `FIR Correction` is the other global convolution slot

The legacy Dynamics UI separately exposes `FIR Correction` with its own enable control, filename state, and `Load IR…` / `Clear` actions.

Legacy product text describes it as a user-supplied WAV/AIFF convolution slot processed after the EQ chain, suitable for speaker/room FIR filters and other correction profiles.

The app-store coordinator keeps this in a separate `convolutionConfig`; `loadConvolutionIR(url:)` updates the routing/render-pipeline convolution IR and `clearConvolutionIR()` clears that slot.

This is independent from `advanced.firImpulseResponse` and its DynamicsProcessor FIR stage.

### Commercial disposition

**IMPLEMENTED / IMPROVED foundation.**

The commercial rewrite already has the portable-C convolution/FIR runtime and room-correction deployment path. Exact production file-import/persistence UX belongs to the planned persistence/room-correction milestones, but the underlying global convolution capability is not the same missing item as legacy per-band FIR.

---

# 4. Resulting PR34 classification

PR34 should track the three FIR concepts separately:

1. **Per-band FIR EQ type** — **MISSING / BLOCKER** in core EQ parity.
2. **Advanced standalone FIR Impulse Response slot** — **MISSING / PRODUCT-DISPOSITION BLOCKER** until the in-scope speaker use case is explicitly mapped to either a second independent commercial slot or a defensible unified workflow.
3. **Global FIR Correction / room-correction convolution** — **IMPLEMENTED / IMPROVED foundation**, with import/persistence/room-correction UX still attached to later milestones.

This source evidence closes the earlier ambiguity: the two global FIR controls were independently wired and the per-band FIR mode was a third independent user workflow.

No realtime code is changed by this audit slice.
