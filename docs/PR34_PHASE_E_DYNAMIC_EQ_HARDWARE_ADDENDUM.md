# PR34 Phase E Dynamic EQ Hardware Addendum

Status: **FOCUSED DYNAMIC EQ HARDWARE RETEST PASSED; PHASE E HARDWARE/LISTENING GATE CLOSED; PR34 FUNCTIONAL-PARITY GATE SATISFIED.**

This addendum records the only issue found during the first Phase E hardware/listening pass, the clean-room commercial correction that followed it, and the successful focused hardware retest. It supplements `PR34_PHASE_E_PARITY_REAUDIT.md` and is the controlling final hardware disposition where that earlier report still describes the hardware gate as pending.

## 1. Hardware observation

The first Phase E hardware/listening build was broadly successful. The reported exception was that, while editing Mid/Side EQ, a newly added Mid/Side band's Dynamic EQ toggle was non-responsive, whereas a Linked EQ band could be switched to Dynamic normally.

Investigation showed that this was not a failed UI action. The Phase C implementation had intentionally kept Dynamic EQ as one shared physical-stereo layer whose settings were sourced from the Linked band bank. That made Dynamic controls shown on Mid/Side bands misleadingly inert.

A temporary compatibility correction that sourced the shared layer from Linked / Left / Mid exposed a broader product-design problem: Independent L/R and Mid/Side editing should not present channel-domain independence while dynamics remain owned by only one lane.

## 2. Commercial Dynamic EQ contract adopted

The commercial product now uses domain-aware Dynamic EQ:

- **Linked:** one stereo-linked Dynamic EQ lane with linked detector/gain behavior.
- **Independent L/R:** independent Left and Right Dynamic EQ lanes with independent detector/gain state.
- **Mid/Side:** independent Mid and Side Dynamic EQ lanes in the Mid/Side domain, decoded back to physical L/R after dynamic processing.

Dynamic EQ follows the EQ band's active channel domain rather than a hidden owner bank.

## 3. Filter-family support

Ordinary Dynamic EQ is available for:

- Peak,
- Low Shelf,
- High Shelf,
- Tilt,
- Notch,
- Band Pass.

The following remain intentionally static or require a separately designed adaptive feature:

- Low Pass / High Pass — dynamic cutoff modulation is not treated as ordinary Dynamic EQ,
- Linkwitz Transform — speaker alignment remains static,
- user FIR band — adaptive FIR weighting is a separate problem,
- All-Pass — adaptive phase is not presented as Dynamic EQ.

Dynamic Notch is **cut-only**. Boost behavior belongs to a Peak-style dynamic band rather than a Notch control.

## 4. Phase-mode behavior

- **Minimum Phase:** Dynamic EQ operates natively as a minimum-phase time-varying layer.
- **Mixed Phase:** static Mixed Phase EQ is followed by the conventional minimum-phase Dynamic EQ layer. The static all-pass phase-correction program is not continuously redesigned as detector gain changes.
- **Linear Phase:** the static EQ remains linear-phase FIR; the time-varying Dynamic correction is a minimum-phase layer after the FIR. This is explicit in the UI and is not represented as continuously redesigned linear-phase dynamics.

## 5. Realtime implementation

The existing graph placement is retained. The realtime Dynamic EQ processor selects a domain internally:

- linked physical L/R,
- dual-mono L/R,
- or encoded Mid/Side with independent lanes followed by decode.

Filter/detector basis coefficients are designed on the control plane. The audio thread consumes fixed biquad coefficients, preallocated state and smoothed scalar gains; it does not allocate or redesign filters.

Automatic headroom accounts for possible Dynamic boost in the active domain: Linked uses the linked-bank boost envelope, Independent uses the larger of Left/Right, and Mid/Side uses the larger of Mid/Side.

## 6. Software verification

The verified source landed in commit `db1c93de800b5a6d65409d3d97960db5d405edec` (`Bake in domain-aware Dynamic EQ`). The integration gate passed before that source commit was published:

- source transformation / diff cleanliness,
- standalone Dynamic-domain DSP validation at 44.1, 48, 96, 192 and 384 kHz,
- independent L/R lane isolation,
- independent Mid/Side-domain isolation,
- supported shape validation and cut-only Notch enforcement,
- full application build,
- focused Swift graph regressions for Independent, Mid/Side, Mixed and Linear behavior,
- full XCTest suite.

The one-shot integration workflow was then retired, and the same Dynamic-domain validator was added to the permanent read-only PR34 parity regression gate.

## 7. Focused hardware retest result

The corrected hardware-test build was exercised after the software correction. The user reported that the corrected Dynamic EQ behavior **“works like a charm.”**

This accepts the focused retest across the intended corrected behavior: domain-aware Dynamic editing/processing is responsive and stable in real playback, and no new hardware-only blocker was reported.

The earlier broad Phase E listening pass remains accepted; it does not need to be repeated.

## 8. Final Phase E disposition

- Source discovery gate: **SATISFIED**.
- Phases A-D implementation blocker gate: **SATISFIED**.
- Phase E software re-audit / deterministic regression: **SATISFIED**.
- Broad hardware/listening validation: **PASSED**, with one Dynamic EQ defect found and corrected.
- Focused corrected Dynamic EQ hardware retest: **PASSED**.
- Overall PR34 functional-parity gate: **SATISFIED**.

**Phase E is CLOSED.**

The performance-profiling / optimization gate is now **OPEN** for subsequent work. That next phase should establish measured 48/96/192/384 kHz baselines and optimize only observed hotspots while preserving the accepted realtime and sonic contracts.
