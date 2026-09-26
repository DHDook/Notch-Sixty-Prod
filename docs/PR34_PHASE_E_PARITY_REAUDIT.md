# PR34 Phase E Parity Re-Audit and Regression Result

Status: **SOFTWARE PARITY RE-AUDIT PASSED; FOCUSED HARDWARE / LISTENING VALIDATION REMAINS OPEN.**

This document is the Phase E reconciliation layer for PR34. It supersedes stale inline `MISSING / BLOCKER` and `AUDIT PENDING` classifications that remain in the chronological living ledger (`PR34_LEGACY_SOURCE_PARITY_AUDIT.md`) from before Phases A-D were implemented and before the focused audit continuations resolved later-milestone, no-op, and product-scope questions.

The living ledger remains useful as discovery history and legacy evidence. Current disposition is governed by this Phase E result together with the focused audit documents and `PR34_PARITY_DISPOSITION_AND_EXECUTION_PLAN.md`.

The clean-room restriction remains unchanged: legacy source establishes observable contracts and defects only; production DSP is independently authored.

---

# 1. Phase E software gate result

The current stereo product has no unexplained current-scope software blocker remaining from the PR34 source audit.

At the software level:

- Phase A isolated EQ blockers are implemented and regression tested.
- Phase B compiled multi-section EQ architecture, 6-96 dB/oct slopes and Tilt are implemented and regression tested.
- Phase C Mid/Side, per-band FIR and Mixed Phase are implemented and regression tested.
- Phase D Symmetry Balance, speaker crossfeed, speaker crosstalk cancellation, sub-bass phase alignment and the standalone advanced FIR-IR mapping are implemented and regression tested.
- all remaining source-audit findings are explicitly classified as implemented/improved, later milestone, out of current scope, or legacy-dead/no-audio-effect.

**Phase E software re-audit: PASSED.**

**Phase E hardware/listening validation: PENDING.**

Performance optimisation remains closed until the focused hardware/listening pass is completed and any hardware-only regression is dispositioned.

---

# 2. Reconciliation of the old current-blocker ledger

The chronological living ledger still contains older blocker text. Those entries now reconcile as follows.

| Historical ledger item | Phase E disposition |
|---|---|
| Mid/Side EQ editing/processing | **IMPLEMENTED / IMPROVED** — independent Mid and Side static EQ lanes; Minimum, Linear and Mixed phase support; Dynamic EQ remains the audited linked physical-stereo dynamics layer. |
| Band Pass | **IMPLEMENTED / IMPROVED** — dedicated clean-room filter family with supported-rate validation. |
| Per-band FIR / loaded-IR EQ band | **IMPLEMENTED / IMPROVED** — explicit FIR user-band kernel contract integrated with the main-EQ convolution path. |
| Linkwitz Transform | **IMPLEMENTED / IMPROVED** — typed f0/Q0/fp/Qp model and independent digital design. |
| Tilt EQ | **IMPLEMENTED / IMPROVED** — one user band compiles to complementary shelf sections. |
| 6-96 dB/oct main-EQ slopes | **IMPLEMENTED / IMPROVED** — bounded compiled multi-section representation. |
| Constant-Q parametric | **IMPLEMENTED / IMPROVED** — separate from retained proportional-Q Peak behavior. |
| Mixed Phase EQ | **IMPLEMENTED / IMPROVED** — bounded all-pass phase correction, distinct from room-measurement excess phase. |
| Symmetry Balance | **IMPLEMENTED / IMPROVED** — separate center-normalized constant-power listening-position control; ordinary Balance remains separate. |
| Panning Gain Matrix / speaker crossfeed | **IMPLEMENTED / IMPROVED** — true effective 0...0.5 range, 0 identity and 0.5 mono. |
| Crosstalk Cancellation | **IMPLEMENTED / IMPROVED** — independently authored bounded feed-forward speaker cancellation with Amount and Head-Shadow controls. |
| Sub-Bass Phase Alignment | **IMPLEMENTED / IMPROVED for the current logical mono-sub path** — independent all-pass stage; future independently routed physical sub outputs remain part of Active Crossover Matrix. |
| Standalone advanced FIR Impulse Response | **IMPLEMENTED / IMPROVED as independent global Speaker IR** — third independent convolution workflow, not collapsed into main-EQ FIR or room correction. |

There is therefore no remaining item in the old current-blocker list that is still an unexplained blocker.

---

# 3. Three distinct FIR workflows are preserved

The FIR workflow audit established three separate legacy use cases. The commercial graph now preserves all three without aliasing them onto one state slot:

1. **Main-EQ / per-band FIR** — the main-EQ convolution program.
2. **Advanced standalone FIR Impulse Response** — mapped to the independent global **Speaker IR** program.
3. **FIR Correction / room correction** — the independent room-correction program.

Regression coverage prepares all three simultaneously, attaches them to one graph with separate slots/generations, verifies cumulative latency, verifies independent diagnostics, and rejects an unprepared/stale Speaker IR generation.

Production file import/resource persistence for Speaker IR remains deliberately assigned to the later Persistence / Import-Export milestone. PR34 proves the current stereo runtime and product-state mapping; it does not falsely claim the later file-management workflow.

---

# 4. High-rate regression / legacy Hi-Res Coefficient Decoupling disposition

The old ledger left the legacy Hi-Res Coefficient Decoupling switch pending because the legacy implementation used it as a high-rate coefficient workaround.

The commercial implementation instead requires deterministic numerical behavior at the actual supported rates. The accumulated PR34 validators exercise the independently authored filter/phase/spatial implementations through the supported high-rate set, including 384 kHz where applicable, and the full macOS test suite remains green.

**Disposition: IMPLEMENTED / IMPROVED BY ARCHITECTURE.**

A user-visible compatibility switch whose purpose was an implementation workaround is not recreated merely for historical surface parity. If future profiling or hardware measurements expose a real high-rate accuracy problem, it should be fixed directly rather than reintroducing the legacy workaround control.

---

# 5. Dynamics / conditioning reconciliation

The focused dynamics audit resolves the older pending entries:

- Hardware Sync Buffer -> **LEGACY-DEAD / NO-AUDIO-EFFECT**.
- Music/Movie Latency Mode -> **LEGACY-DEAD / NO-AUDIO-EFFECT**.
- Pause Gate -> **IMPLEMENTED / IMPROVED** with the intentional commercial naming convention:
  - commercial Attack = close / fade-out,
  - commercial Release = open / fade-in.
  Legacy import must swap the historical fields to preserve audible timing.
- Compressor, Expander, De-Esser, Multiband, Soft Clipper and Limiter -> **IMPLEMENTED / IMPROVED** at processor-capability level. Audited fresh-default differences are intentional product choices because the historical values remain representable.
- EQ Headroom / predictive attenuation -> **IMPLEMENTED / IMPROVED** through Automatic Headroom / conservative static headroom logic.

No remaining dynamics feature-existence blocker is open in PR34.

---

# 6. Dither / output format reconciliation

Legacy Dither is confirmed live behavior, but its semantics are tied to a deliberate fixed-bit-depth terminal conversion.

The current commercial realtime graph is Float32 and does not intentionally quantize itself to a fixed 24-bit boundary before CoreAudio. Reproducing the legacy 24-bit quantizer in this graph would reduce quality rather than preserve the best observable behavior.

**Disposition: LATER MILESTONE — output-format / export / release hardening, only where Notch Sixty owns the terminal fixed-bit conversion.**

This is explicit later work, not current realtime-DSP debt.

---

# 7. Routing / device reconciliation

For the current single physical stereo output, the focused routing audit classifies the following as **IMPLEMENTED / IMPROVED**:

- output enumeration and stable UID selection,
- sample-rate-change rebuild/recovery,
- selected-output disappearance and return recovery,
- hardware volume/mute capability synchronization,
- software gain fallback where device controls are unavailable,
- propagation of external device volume state into product state.

Legacy virtual-driver choreography is not itself a parity requirement where the clean commercial transport supplies the same end-user behavior.

Remaining route policy and multi-device behavior is explicitly dispositioned:

- follow-system-output vs pinned-output product policy -> **production UI / persistence follow-up**,
- headphone plug auto-switch -> **OUT OF CURRENT PRODUCT SCOPE**,
- output-channel/device matrix -> **LATER MILESTONE: Active Crossover Matrix**,
- Aggregate Device synchronization -> **LATER MILESTONE**,
- Software PLL synchronization -> **LATER MILESTONE**,
- arbitrary/fractional SRC -> **LATER MILESTONE**,
- per-device lock/drift/latency telemetry -> **LATER MILESTONE**.

No multi-device synchronization implementation is required to close the current single-output stereo-core parity gate.

---

# 8. Active Crossover / physical multi-output reconciliation

The source audit established extensive per-output driver processing and optimization behavior. It remains an explicit later **Active Crossover Matrix / physical multi-output** milestone, including:

- physical source/target matrix,
- per-output EQ/gain/delay/polarity,
- per-output Speaker IR / acoustic-center alignment,
- per-output limiter/protection/telemetry,
- Aggregate Device / Software PLL / explicit SRC,
- crossover group-delay/summation/frequency optimization,
- driver time alignment and polarity diagnosis,
- baffle-step and diaphragm-resonance tooling,
- combined-system verification,
- advanced CamillaDSP export.

Confirmed legacy defects remain intentionally excluded:

- no-op `optimise slopes` toggle,
- no-op `optimise delay` toggle,
- ambiguous delta-vs-absolute Apply-All EQ semantics.

This later milestone is explicitly preserved; it is not silently called superseded.

---

# 9. Room correction / measurement reconciliation

The commercial app has the runtime/convolution foundation, but the complete measurement-and-design workflow remains an explicit later **Room Correction** milestone:

- physical microphone capture and permissions,
- logarithmic sweeps,
- multiple sweeps / multiple positions,
- microphone calibration,
- SNR/quality reporting with improved retry/exclusion policy,
- time-windowed/reflection-reduced IR analysis,
- complex response averaging,
- built-in/custom target curves,
- IIR and minimum-phase FIR correction design,
- measurement-derived excess-phase correction,
- verification workflows,
- measurement/correction asset persistence,
- impulse/step/decay/group-delay views.

The audited legacy minimum-SNR control was primarily warning/reporting behavior; the commercial milestone may improve it rather than recreate weak automatic acceptance semantics.

**Disposition: LATER MILESTONE — explicit and fully scoped.**

---

# 10. Metering / RTA / analytics reconciliation

The dedicated production meters/RTA stack remains a later milestone / dedicated follow-up PR. It includes:

- calibrated Peak/RMS,
- VU,
- RTA through 384 kHz,
- phase correlation,
- crest factor,
- gain structure,
- continuous true peak/dBTP,
- stereo goniometer,
- honest processing-format/sample-rate display,
- later per-output telemetry once the physical output matrix exists.

Misleading legacy analytics are not parity targets:

- old `ISP` latch was sample-peak-based rather than true inter-sample peak,
- `DR Factor` was a simple clamped peak/RMS ratio rather than a standardized DR metric,
- `Bit Stream` LEDs were derived from one quantized peak scalar rather than source-bit analysis,
- `Bit Rate` described nominal Float32 stereo processing throughput rather than source-media bitrate.

True-peak protection/telemetry already has an implemented/improved commercial foundation.

**Disposition: LATER MILESTONE with misleading legacy labels/metrics intentionally corrected rather than reproduced.**

---

# 11. Persistence / presets / interchange reconciliation

Persistence remains a release-parity milestone, not a current realtime-DSP blocker. The focused audit establishes the required compatibility contract:

- a versioned commercial native schema,
- one-way import of legacy v1/v2 `.eqpreset`,
- v1 bandwidth-to-Q migration and historical filter mapping,
- legacy Pause Gate Attack/Release translation,
- preservation of explicit dynamics settings rather than substitution of commercial fresh defaults,
- no invention of missing historical Constant-Q / Linkwitz target state because the audited old serializer did not actually round-trip it,
- REW import,
- EasyEffects import/export,
- resource-backed FIR / Speaker IR persistence,
- room-correction project persistence,
- commercial factory/product presets,
- CamillaDSP export after the physical output-matrix milestone.

A/B/C/D in-memory snapshots likewise belong to this product/persistence/UI milestone rather than the current realtime parity blocker set.

**Disposition: LATER MILESTONE — explicit and testable.**

---

# 12. Out-of-scope reconciliation

The current Notch Sixty product is speaker-focused. The following remain intentionally out of current scope:

- headphone-only DSP workflows,
- headphone automatic-output-switch policy,
- headphone-focused AutoEQ interchange unless a future speaker-oriented use case is independently defined.

No speaker-oriented Panning/Crosstalk feature is excluded under this rule; those were implemented in Phase D after the source audit corrected the earlier blanket classification.

---

# 13. Reference / Delta / Global Bypass latency contract

The realtime graph maintains one explicit cumulative `snapshot.latencyFrames` contract.

At frame entry, the raw reference signal is fed into the reference delay using that cumulative latency. Processed mode follows the DSP graph. Reference mode substitutes the latency-aligned raw reference. Delta subtracts that same aligned reference from the processed output.

The graph then applies the same inter-channel speaker-alignment stage to Processed / Reference / Delta. During Global Bypass the alignment history stays warm, but the aligned copy is deliberately discarded so Global Bypass remains the true raw escape path.

The three convolution workflows all contribute their engine + declared filter latency to the graph latency contract, and denoiser/protection latency is added by the graph compiler. The focused three-FIR regression verifies additive FIR latency.

**Disposition: SOFTWARE CONTRACT VERIFIED.**

Focused hardware/listening validation remains required to catch transport/device behavior not represented by deterministic software tests.

---

# 14. Realtime-safety review of the new structural paths

Phase E review confirms the new Phase C/D structural paths preserve the control-plane/realtime split:

- filter coefficients and compound EQ programs are designed off the audio thread,
- FIR program memory is allocated when convolvers are created, not during sample processing,
- FIR kernels/FFT partitions are prepared on the control plane,
- `N60PartitionedConvolverProcessSample` consumes preallocated buffers/state and performs no allocation,
- Speaker IR reuses that same partitioned-convolution contract with independent prepared storage,
- snapshot publication validates prepared program generations before exposing a graph,
- the render thread acquires a bounded snapshot and never mutates control-plane configuration,
- Symmetry Balance, speaker crossfeed and crosstalk cancellation consume precomputed/smoothed scalar state,
- sub-bass phase-alignment coefficients are designed off-thread and consumed by the crossover runtime,
- no legacy implementation expression was imported to implement the new clean-room stages.

**Realtime-safety review: PASSED for the Phase E software gate.**

Performance profiling may still identify CPU hotspots; that is the next milestone after parity, not evidence of an unresolved functional parity contract.

---

# 15. CI / deterministic regression evidence

On the Phase E software baseline, both CI paths are green:

## Normal macOS workflow

- validator step: PASS,
- application build: PASS,
- complete XCTest suite: PASS.

## PR34 Parity Regression Gate

- Band Pass validator: PASS,
- Constant-Q validator: PASS,
- Linkwitz validator: PASS,
- compiled EQ / high-order slopes / Tilt validator: PASS,
- Mid/Side validator: PASS,
- per-band FIR validator: PASS,
- Mixed Phase validator: PASS,
- Symmetry Balance validator: PASS,
- speaker crossfeed validator: PASS,
- crosstalk cancellation validator: PASS,
- sub-bass phase-alignment validator: PASS,
- application build: PASS,
- three independent FIR workflow tests: PASS,
- complete XCTest suite: PASS.

The accumulated high-rate validators retain deterministic coverage through the supported high-rate set, including 384 kHz where applicable.

---

# 16. Remaining Phase E gate: focused hardware / listening validation

The only remaining PR34 functional-parity exit gate is a focused hardware/listening pass on the structural audio changes.

The listening pass should specifically verify:

1. Global Bypass is genuinely raw and level-stable.
2. Processed <-> Reference remains perceptually time-aligned when FIR/denoiser/protection latency is present.
3. Delta does not reveal an obvious latency-offset comb caused by incorrect graph-delay accounting.
4. Minimum / Linear / Mixed phase mode switching is stable and does not drop audio.
5. Mid/Side enable/editing does not swap or collapse the stereo image unexpectedly.
6. Per-band FIR and the three global FIR workflows can be enabled/disabled without large gain discontinuities or channel swaps.
7. Symmetry Balance center is neutral; off-center movement is smooth and behaves differently from ordinary Balance.
8. Speaker crossfeed is neutral at 0 and reaches mono at 0.5 without unexpected level jump.
9. Crosstalk Cancellation remains bounded, does not howl/oscillate, and sounds stable during live Amount / Head-Shadow changes.
10. Sub-Bass Phase Alignment changes phase/integration rather than obvious level, polarity or broadband delay.
11. 96 kHz normal listening remains stable on the reference hardware chain; one high-rate spot check should also confirm no gross high-rate failure.

If this hardware pass is clean, Phase E may be closed and the PR34 performance-optimisation gate may open.

---

# 17. Phase E conclusion

**Source discovery gate: SATISFIED.**

**Implementation blocker gate (Phases A-D): SATISFIED.**

**Phase E software re-audit / deterministic regression gate: SATISFIED.**

**Focused hardware/listening validation: PENDING.**

**Overall PR34 functional-parity gate: NOT YET SATISFIED solely because the required hardware/listening validation has not yet been completed.**

**Performance optimisation gate: CLOSED until that hardware pass is accepted.**
