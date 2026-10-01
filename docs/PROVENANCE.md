# Provenance Register

This file is Notch Sixty's living commercial provenance register. It records the implementation/source basis for nontrivial production code and assets.

## Classification

- **Original commercial implementation** — written in this repository from product requirements and the proprietary architecture.
- **Specification-derived** — independently authored from public mathematical/technical specifications or platform APIs.
- **POC-derived, owner-authored** — deliberately reused/adapted from owner-authored clean POC material after review.
- **Third-party permissive** — external code/component with a compatible license and required notice.
- **Asset with verified rights** — artwork/audio/font/resource whose commercial rights are documented.

Historical GPL Notch Sixty / Equaliser implementation source is **not** a permitted production source category. It may be consulted only to inventory externally observable behavior, data-format facts, reachability and known defects.

## Repository-wide rules

1. No historical GPL source expression, tests, project metadata or implementation structure may be copied/translated into production.
2. Public DSP/acoustic equations and Apple APIs may be used as specifications; implementations must be independently authored.
3. Any owner-authored legacy asset/code reused under independent ownership must be explicitly recorded.
4. Any future third-party dependency must be recorded here and in `THIRD_PARTY_NOTICES.md` before release.
5. GPL/AGPL dependencies are not permitted in production targets.

## Commercial implementation register

| Area | Classification | Source of truth / ownership basis | Notes |
| --- | --- | --- | --- |
| Repository bootstrap, Xcode project, app shell | Original commercial implementation | Commercial rewrite requirements | Fresh project/source/history; no Equaliser/legacy project import. |
| Core Audio device discovery/output selection | Specification-derived / original | Apple Core Audio HAL APIs + product requirements | Stable UID selection and capability inspection independently authored. |
| Process tap / first-party capture / Aggregate Device transport | Specification-derived / original | Apple process-tap, HAL, IOProc and aggregate-device APIs | No historical virtual-driver or Software-PLL code ported. |
| Realtime transport bridge | Original commercial implementation | `docs/REALTIME_RULES.md` | Fixed-capacity C11-atomic stereo bridge; no third-party atomics dependency. |
| Lifecycle/recovery/diagnostics | Original commercial implementation | `docs/ARCHITECTURE.md` | Explicit start/reconfigure/recovery/sleep/wake/termination state. |
| Realtime graph/snapshot publication | Original commercial implementation | `docs/DSP_KERNEL.md`, `docs/REALTIME_RULES.md` | Preallocated immutable snapshots and bounded transitions. |
| Parametric biquads / LP/HP/shelves/notch/band-pass/all-pass | Specification-derived / original | Standard public digital biquad mathematics | Coefficient design independently authored. |
| Constant-Q Peak / Linkwitz Transform / Tilt / compiled high-order filters | Specification-derived / original | Public filter mathematics + proprietary compiled-EQ architecture | PR34 clean-room implementations; legacy source only established observable contracts. |
| Linear Phase / convolution / per-band FIR | Specification-derived / original | Public FIR/convolution mathematics + proprietary graph | Independent control/runtime implementation and latency accounting. |
| Mixed Phase EQ | Specification-derived / original | Public all-pass/group-delay concepts + proprietary EQ graph | Distinct from measured acoustic excess-phase correction. |
| Room-correction runtime convolver | Original commercial implementation | Product requirements + proprietary convolution runtime | Dedicated ownership/program slots/latency/diagnostics. |
| Stereo playback controls, balance, audition | Original commercial implementation | Product requirements + proprietary graph | Includes latency-matched Reference/Delta and raw Global Bypass. |
| Master volume / mute / fixed-output keyboard volume | Specification-derived / original | Core Audio HAL + Core Graphics event APIs | Listen-only volume-key event tap; no legacy driver implementation reused. |
| Compressor / Expander / Pause Gate | Specification-derived / original | Standard dynamics mathematics + product controls | PR26; commercial Pause Gate Attack=fade-out, Release=fade-in. |
| Oversampling / true peak / soft clip / limiter | Specification-derived / original | Standard multirate, peak and dynamics concepts | PR27; deterministic 2x/4x unity-gain guards specifically prevent historical attenuation defect. |
| De-Esser / Multiband Compressor | Specification-derived / original | Standard feed-forward dynamics/filter mathematics | PR28 independent commercial rewrite. |
| Fractional inter-channel delay | Specification-derived / original | Public Thiran/maximally-flat delay mathematics | PR30; proprietary transition/runtime integration. |
| Mains hum detector/tracker/notches | Specification-derived / original | General Fourier/correlation + biquad concepts | PR31; legacy detector/source/tests excluded. |
| Spectral denoiser | Specification-derived / original | Public STFT/WOLA, Wiener-style estimation, minimum-statistics concepts | PR31 independently authored fixed/preallocated processor. |
| Advanced dynamics/dialogue processing | Specification-derived / original | Standard dynamics/envelope/filter concepts | PR32; historical processor source/tests excluded. |
| Dynamic Gain Rider / TP Guard / asymmetry / automatic headroom | Specification-derived / original | Standard bounded gain/peak-protection principles | PR33 independent implementations. |
| Per-band loudness / De-Harsh | Specification-derived / original | Public level mapping + shelf-filter mathematics | PR33 independent implementations. |
| Dynamic EQ | Specification-derived / original | Public biquad/detector/envelope concepts | PR33 independently authored engine integrated into ordinary commercial EQ bands. |
| PR34 stereo parity expansion | Specification-derived / original | `docs/PR34_*_AUDIT.md` behavioral inventory + public DSP math | Band Pass, Constant-Q, Linkwitz, high-order slopes, Tilt, M/S, per-band FIR, Mixed Phase, symmetry/spatial/sub-phase features independently authored. |
| PR35 realtime performance/readiness | Original commercial implementation | Proprietary graph performance requirements | Snapshot ownership, parking, demand gating, bounded resets/transitions and benchmarks. |
| PR36 production UI foundation | Original commercial implementation | Product UX requirements + SwiftUI APIs | New commercial navigation/workspace shell. |
| PR37 production Equalizer | Original commercial implementation | Proprietary EQ model + SwiftUI | No historical view code reused. |
| PR38 production Dynamics | Original commercial implementation | Proprietary dynamics model + SwiftUI | No historical view code reused; PR42 later modernizes presentation with semantic native controls. |
| PR39 metering/RTA/stereo analysis | Specification-derived / original | Standard meter/spectral/stereo-analysis concepts + proprietary telemetry | No external DSP/visualization library bundled. |
| PR39 Content Presets / Playback Systems | Original commercial implementation | Commercial ownership/persistence requirements | New two-layer archive; not a port of historical store. |
| PR39 app identity artwork | Asset with verified rights | User-authored Notch Sixty analog-meter artwork; `docs/PR39_APP_IDENTITY_STATUS.md` | Owner deliberately reuses the asset under independent ownership rights. Light/dark PNG derivatives and retained SVG sources are cleared production assets; no Equaliser branding/external font asset imported. |
| PR40 Room Correction measurement/workflow | Specification-derived / original | Apple capture APIs, public acoustic/DSP literature incl. exponential sine sweep method, proprietary RC runtime | Calibration controller, ESS path, deconvolution/analyzer, project store, spatial aggregation, target/FIR design and UI independently authored. |
| PR41 physical output routing / Active Crossover | Specification-derived / original | Apple Core Audio APIs + standard Linkwitz-Riley mathematics + product requirements | 2–8 route model, same-device/aggregate transport, reference clock/HAL drift, speaker-bus splitter and driver-safe bypass independently authored. Legacy Software PLL not ported. |
| PR42 Dynamics UI modernization | Original commercial implementation | Native SwiftUI semantic controls/materials | `LabeledContent`/native editable values/adaptive surface; DSP/control semantics unchanged. |
| PR42 legacy `.eqpreset` migration | Original commercial implementation | Data-format compatibility facts + proprietary state models | One-way reader; historical serializer/parser code not copied. |
| PR42 REW interoperability | Original commercial implementation | Public/user-visible REW filter-text format | Parser/exporter authored in commercial repository; REW software not embedded. |
| PR42 EasyEffects interoperability | Original commercial implementation | Public/user-visible EasyEffects preset JSON format | Import/export authored against proprietary EQ ownership model; EasyEffects not embedded. |
| PR42 CamillaDSP interoperability | Original commercial implementation | Public CamillaDSP YAML configuration specification | Text exporter only; CamillaDSP is not linked/embedded/redistributed. |
| Third-party production dependencies | None | `THIRD_PARTY_NOTICES.md` | No approved linked/bundled third-party production source as of PR42. |

## Detailed historical PR notes retained as provenance facts

### PR28 — De-Esser and Multiband Compressor

Legacy material established visible control names/ranges/stage intent only. Commercial code uses proprietary `N60Dynamics`, `N60Biquad` and crossover primitives plus standard feed-forward dynamics/filter mathematics. Historical DSP source/test vectors were not used as implementation references.

### PR30 — All-Pass / fractional delay

All-Pass EQ is independently implemented from standard second-order digital all-pass mathematics. Signed inter-channel fractional delay is independently implemented from public Thiran-style maximally-flat group-delay mathematics with proprietary preallocated runtime and click-safe transitions.

### PR31 — Noise / Hum suppression

Historical `SpectralDenoiser`, `MainsHumDetector`, `GoertzelEstimator`, notch helpers and tests are explicitly excluded implementation references. Commercial mains tracking uses independently authored correlation/frequency-bank analysis. Spectral denoising uses independently authored fixed/preallocated STFT/WOLA and conservative spectral estimation.

### PR32–PR33 — dynamics parity closure

Historical dynamics/UI/configuration was used only to establish externally observable controls/ranges/defaults and intended behavior. Compressor topology/release/sidechain depth, dialogue-relative leveling, gain riding, true-peak protection semantics, asymmetry, automatic headroom, loudness compensation, De-Harsh and Dynamic EQ are independent proprietary implementations from standard public DSP concepts.

### PR34 — source audits

`docs/PR34_*_AUDIT.md` files are clean-room behavioral inventories. They identify observable contracts, reachability and defects; they are not implementation sources. PR34 production work was independently authored against public DSP mathematics and the existing proprietary graph.

### PR40 — acoustic measurement references

The commercial ESS design may use the published exponential-sine-sweep measurement method described in public AES literature (including Angelo Farina's swept-sine work). The mathematics/method is a specification reference. No third-party measurement implementation source is bundled or copied.

### PR41 — Core Audio synchronization

The commercial design intentionally supersedes the legacy custom Software PLL with Core Audio Aggregate Device clocking/reference selection and HAL drift compensation. This is new code against Apple APIs, not a port.

### PR42 — interchange

Legacy JSON field names/enumerated values are compatibility facts necessary to read user-owned preset files. Migration terminates in current proprietary state. REW/EasyEffects/CamillaDSP support uses independently authored format readers/writers and does not add those projects as dependencies.

## POC reuse

No current production row is classified as **POC-derived, owner-authored**. If POC source is intentionally reused later, add the exact production path, POC path/commit, ownership basis, changes and review date here before merge.

## Final PR42 reconciliation

See `docs/PR42_PROVENANCE_CLOSURE.md` for the PR42 release-gate review.

As of that review:

- unexplained production source origin: **none identified**;
- unresolved GPL/AGPL production dependency: **none identified**;
- linked/bundled third-party production component requiring a notice: **none identified**;
- owner-authored reused asset without an ownership basis: **none identified**;
- substantive PR34–PR42 implementation area without a provenance classification: **none identified**.

### PR42 menu-bar artwork reuse

- `NotchSixty/Assets.xcassets/TrayIcon.imageset/notch_sixty_tray_icon_final_tightcrop.svg` is project-owner-controlled artwork carried from the legacy repository by explicit owner request.
- Only the visual asset is reused. The production `MenuBarExtra`, application preferences, processing controls, preset binding, Settings scene, and Dock/Menu Bar/Both behavior are newly authored against the proprietary production model.

