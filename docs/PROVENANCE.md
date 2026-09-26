# Provenance Register

This file is the commercial repository's living provenance register.

## Classification

Each nontrivial imported/reused implementation should be classified as one of:

- **Original commercial implementation** — written in this repository from product requirements/public specifications.
- **POC-derived, owner-authored** — deliberately reused or adapted from `CoreAudioTapPOC-N60` after review.
- **Third-party permissive** — external component with compatible license and notice.
- **Specification-derived** — implemented from a public mathematical/technical specification.
- **Asset with verified rights** — images/audio/fonts/resources whose commercial rights are documented.

Historical GPL Notch Sixty / Equaliser source is not a permitted production source category.

## Initial register

| Area | Classification | Source of truth | Notes |
|---|---|---|---|
| Commercial repo bootstrap/docs | Original commercial implementation | Product requirements + clean-room architecture decisions | No GPL source imported |
| Production Xcode project and Swift app shell | Original commercial implementation | `DHDook/Notch-Sixty-Prod` bootstrap requirements | Freshly and independently generated for this repository. No source, project file, test, asset, configuration, or Git history was imported from historical Notch Sixty, Equaliser, BlackHole, or `CoreAudioTapPOC-N60`; the app shell is newly generated bootstrap material. |
| Core Audio device discovery and output-selection foundation | Specification-derived / original commercial implementation | Apple public Core Audio property APIs + production architecture requirements | Independently implemented in this repository. Uses `AudioObjectGetPropertyData` / `AudioObjectGetPropertyDataSize` and public device-property selectors. No POC or historical source copied. |
| Core Audio process-tap and aggregate transport | Specification-derived / original commercial implementation | Apple public `CATapDescription`, process-tap, aggregate-device, IOProc, and property-listener APIs + product requirements | Independently implemented in this repository. Behavior is informed by prior product validation, but no POC or historical source code/project metadata was copied. |
| Realtime transport bridge | Original commercial implementation | `docs/REALTIME_RULES.md` + SPSC transport requirements | New fixed-capacity stereo C11-atomic ring bridge. No third-party atomics dependency; no allocation/locking/logging in capture/render callbacks. |
| Audio lifecycle state machine and diagnostics foundation | Original commercial implementation | `docs/ARCHITECTURE.md` lifecycle and output-policy requirements | Production control plane includes intentional reconfiguration, same-UID recovery, sleep/wake handling, graceful Stop/Quit, and cumulative transport diagnostics. |
| Realtime DSP kernel and graph-publication foundation | Original commercial implementation | Product requirements + `docs/REALTIME_RULES.md` + `docs/DSP_KERNEL.md` | Independently implemented in the commercial repository. C11-atomic preallocated snapshot publication, unity/reference render stage, gain/bypass/latency contracts, and numerical-safety diagnostics. No historical GPL or POC source copied; PR #12 contains no substantive EQ/filter algorithm. |
| Parametric EQ, crossover, convolution, and linear-phase EQ | Specification-derived / original commercial implementation | Standard digital biquad equations + independently written product architecture + `docs/PARAMETRIC_EQ.md`, `docs/BASS_MANAGEMENT.md`, `docs/FIR_CONVOLUTION.md`, `docs/LINEAR_PHASE_EQ.md` | Net-new commercial DSP implementations. No historical GPL implementation source was copied or adapted. |
| Room-correction runtime FIR stage | Original commercial implementation | Product requirements + `docs/REALTIME_RULES.md` + `docs/FIR_CONVOLUTION.md` + `docs/ROOM_CORRECTION.md` | Net-new independent room-correction convolver instance, graph state, latency accounting, ownership validation, diagnostics, and deterministic tests. No historical GPL or POC source was used as implementation reference. Measurement, multi-seat averaging, target-curve generation, and correction-filter design remain deferred. |
| Room-correction control plane and validation path | Original commercial implementation | Product requirements + PR #20 runtime contract + `docs/ROOM_CORRECTION_CONTROL_PLANE.md` | Net-new Swift/C bridge integration, filter validation/model state, safe program-slot lifecycle, transport rebuild behavior, deterministic validation FIR, diagnostics/UI validation surface, and focused tests. No historical GPL or POC implementation, tests, project files, or assets were used as coding references. |
| Product control/state boundary | Original commercial implementation | Commercial product architecture requirements + `docs/ROADMAP.md` | Net-new product-level ownership/configuration snapshot introduced after PR #21 so future persistence, presets, stereo controls, dynamics, and production UI can grow without recreating the historical `EqualiserStore` or coupling product state to transport lifecycle. No historical GPL implementation or tests were used as coding references. |
| Stereo EQ and playback controls | Original commercial implementation | Product requirements + existing proprietary PR #13–22 DSP architecture + standard biquad/FIR behavior | Net-new channel-scoped EQ graph state, independent L/R minimum- and linear-phase control, attenuation-only balance, global bypass/Flat audition, diagnostics, and deterministic tests. No historical GPL implementation, tests, project files, presets, or assets were used as coding references. |
| Master volume, mute, and fixed-output keyboard volume | Specification-derived / original commercial implementation | Product requirements + proprietary realtime master-gain architecture + public Core Audio HAL and Core Graphics APIs | PR #24 independently implements device volume/mute observation where writable and a listen-only `CGEventTap` fallback for fixed-volume outputs. The event-tap path observes system-defined auxiliary-control Volume Up/Down events, maps them to the commercial software master, never seizes/suppresses/synthesizes/reposts input, treats Input Monitoring permission separately from audio-route validity, and does not reproduce the historical virtual/HAL driver implementation. An earlier `IOHIDManager` attempt was independently implemented but removed after hardware validation showed no Volume Up/Down delivery on the macOS 26 + Modi 5 test chain. |
| Latency-matched Reference / Delta audition | Original commercial implementation | Product audition requirements + proprietary graph latency contract + existing PR #12–24 render architecture | PR #25 adds a preallocated stereo reference-delay lane keyed directly to the published graph latency, explicit Processed/Reference/Delta semantics, and deterministic null/latency tests. Global Bypass remains a separate raw escape path. No historical GPL implementation or tests were used as implementation references. |
| Realtime dynamics foundation: compressor, expander, Pause Gate | Specification-derived / original commercial implementation | Product behavior requirements + standard dynamics gain-computer/envelope mathematics + proprietary PR #12–25 graph architecture | PR #26 independently implements a portable linked-stereo dynamics core with immutable precomputed time constants, soft-knee compression, bounded downward expansion, product-specific Pause Gate semantics (Attack = fade-out, Release = fade-in), buffer-rate telemetry, and deterministic tests. Legacy UI/config was used only to inventory externally visible controls/ranges. Historical processor algorithms/tests were not used as implementation reference. |
| Oversampling, true-peak detection, soft clipping, and look-ahead limiting | Specification-derived / original commercial implementation | Product protection requirements + standard multirate/interpolation, true-peak, waveshaping, and limiter concepts + proprietary PR #12–26 realtime/latency architecture + `docs/PROTECTION_OVERSAMPLING.md` | PR #27 independently implements the portable `N60Protection` runtime, 1×/2×/4× paths, linked-stereo soft clipping and limiter protection, true-peak telemetry, explicit latency contribution, and product schema v5 state. Deterministic tests make 2×/4× unity gain a release-blocking invariant and specifically guard against the historical 4× attenuation defect. Historical GPL/legacy processor algorithms, tests, and source expression were not used as implementation references. |
| DSP implementations not yet listed above | Pending | Public specs / independent derivations | Add per-module entries as substantive processors are implemented or independently cleared for reuse. |
| Third-party dependencies | None approved | — | Update before adding any dependency |
| Assets | None added | — | Verify rights before inclusion |

## Required entry for reused POC source

If code is intentionally reused from the POC, add:
- production path
- POC source path/commit
- ownership basis
- changes made for production
- reviewer/date

Do not treat architectural similarity by itself as source reuse.

## PR28 — De-Esser and Multiband Compressor

- **Classification:** independent commercial rewrite.
- **Behavioral references:** documented user-visible legacy control names/ranges and observable stage ordering only.
- **Implementation sources:** current proprietary `N60Dynamics`, `N60Biquad`, and `N60Crossover` primitives; standard feed-forward dynamics and digital-filter mathematics independently implemented for this repository.
- **Legacy implementation reuse:** none. No legacy DSP source, inherited test vectors, or historical implementation structure was copied or adapted.
- **Architecture review:** fixed-size realtime state, control-plane coefficient preparation, zero added algorithmic latency, linked-stereo detection, exact-unity residual multiband recombination at 0 dB band gains.
- **Validation:** deterministic tests plus focused hardware/listening acceptance before merge.



## PR30 — Phase & Time Alignment Foundation

- **Classification:** specification-derived / original commercial implementation.
- **Behavioral references:** legacy user-facing inventory establishes that All-Pass is an EQ filter type used for phase alignment/group-delay correction and that inter-channel timing alignment is a supported product need. Legacy DSP implementation source and tests are not implementation references.
- **Implementation sources:** standard second-order digital all-pass equations from public DSP literature plus the proprietary `N60Biquad`/render-graph architecture.
- **All-Pass contract:** unity magnitude, phase rotation controlled by frequency and Q, minimum-phase/IIR mode only.
- **Realtime contract:** coefficient design remains off the render callback; fixed-size state only; no allocation, locks, logging, file/device I/O, or coefficient construction in realtime.
- **Follow-on in this PR:** independently designed signed fractional inter-channel delay with click-safe transitions. Excess-phase room correction remains deferred to the measurement/room-correction milestone because it requires phase-resolved measurements.


### PR30 fractional inter-channel delay

- **Classification:** specification-derived / original commercial implementation.
- **Implementation source:** standard Thiran maximally-flat group-delay all-pass mathematics, independently implemented around the proprietary render snapshot/runtime architecture.
- **Observable legacy contract used:** signed ±20 ms user-facing range and sign convention only (positive delays Right, negative delays Left).
- **Commercial improvements:** higher-order fractional-delay approximation where possible, exact integer-delay bypass, queued click-safe transitions, explicit audition/Global-Bypass semantics, and deterministic 384 kHz-capable fixed storage.
- **Legacy implementation reuse:** none. Historical fractional-delay source/tests were not used as implementation references.


## PR31 — Noise / Hum suppression

PR31 is a clean-room implementation. Historical Notch Sixty documentation, UI, and configuration state are used only to inventory observable behavior for Mains Hum Notch and spectral denoising. Historical `SpectralDenoiser`, `MainsHumDetector`, `GoertzelEstimator`, `MainsNotchCoefficients`, and DSP tests are explicitly excluded as implementation references.

The first slice implements the static harmonic-notch signal path independently from standard parametric-biquad mathematics already present in the commercial engine. Mains-notch coefficients and states are intentionally double precision because 50/60 Hz high-Q filters at 384 kHz operate at numerically extreme low normalized frequencies; float coefficient quantization measurably reduces requested center depth. Nominal 50/60 Hz selection, harmonic count, Q, and per-harmonic attenuation are product controls; coefficients are designed on the control plane and consumed by fixed realtime state. Detector/tracker and spectral-denoising mathematics will be independently derived in later PR31 slices from public DSP references and synthetic test vectors.


### PR31 Slice 2 — mains detector/tracker

The mains detector/tracker is independently authored. It uses a conventional quadrature/correlation frequency-bank design derived from general Fourier analysis principles, with fixed precomputed oscillator increments, bounded decimation, synthetic test tones, and no reference to the excluded historical `MainsHumDetector` or `GoertzelEstimator` implementations/tests. Detector telemetry is observational; coefficient redesign remains on the Swift/control plane. Realtime notch retuning uses a proprietary dual-bank crossfade rather than coefficient construction in the render callback.


### PR31 Slice 3 — spectral denoiser

- **Classification:** specification-derived / original commercial implementation.
- **Behavioral references:** legacy materials were used only to inventory the visible Natural / Standard / Aggressive / Dehiss / Custom workflow, Reduction Amount, Threshold, Quality modes, protected range, and Capture / Reset controls.
- **Excluded implementation references:** historical `SpectralDenoiser` source, algorithms, tests, tuning internals, and implementation structure were not used as coding references.
- **Independent technical basis:** general public short-time Fourier analysis/weighted overlap-add mathematics, Hann-family perfect-reconstruction windowing concepts, Wiener-style spectral gain estimation, decision-directed a-priori SNR estimation concepts, and conservative low-envelope/minimum-statistics noise estimation. The implementation is independently authored for the proprietary N60 realtime graph and does not reproduce a third-party codebase.
- **Commercial design choices:** linked-stereo common gain, threshold-gated adaptive learning, explicit user-directed one-second Capture, bounded upward noise-floor adaptation, protected unity bands, Dehiss high-frequency weighting, preset-specific gain floors/smoothing, explicit Quality/High/Ultra FFT and latency contracts, and exact disabled passthrough with warm analysis.
- **Realtime implementation:** all FFT/window/profile/OLA scratch is fixed and preallocated when the runtime is created; no allocation, locks, logging, file/device I/O, or plan construction occurs in the render callback.
- **Validation:** synthetic deterministic tests cover exact disabled transparency, captured stationary-noise reduction, linked-stereo ratio, profile Reset, program-material resistance, protected-band behavior, latency-matched WOLA reconstruction, graph latency, and finite operation through 384 kHz. Hardware listening acceptance remains required before PR31 merge.

## PR32 — Dynamics parity closure and dialogue processing

- **Classification:** specification-derived / original commercial implementation.
- **Behavioral references:** historical Notch Sixty configuration and UI were used only to inventory externally observable control names, ranges, defaults, modes, and intended behavior for compressor topology/release/sidechain, De-Esser control depth, multiband control depth, and dialogue-relative leveling.
- **Excluded implementation references:** historical `DynamicsProcessor`, `DialogueRelativeLeveler`, historical dynamics helper implementations, and historical DSP tests were not used as coding templates, translated, or adapted.
- **Commercial implementation basis:** standard feed-forward/feed-back dynamics concepts, one-pole envelope smoothing, detector-only high-pass filtering, standard digital biquad mathematics, linked-stereo gain computation, RMS/power-domain level comparison, and independently derived bounded modulation-energy confidence estimation.
- **Slice 1:** extends the existing proprietary C dynamics core with compressor feed-forward/feed-back topology, precomputed program-dependent release behavior, detector-only sidechain HPF, De-Esser ratio/range/Q/timing controls, and independent/per-band multiband control depth. Existing accepted defaults remain neutral/compatible where practical.
- **Slice 2:** independently implements a dialogue-relative leveler that compares smoothed full-program energy with smoothed dialogue-band energy, reacts to excess masking gap, applies bounded boost only to the extracted dialogue band, and optionally scales correction with a speech-like syllabic-modulation confidence measure. The linked gain decision preserves stereo image.
- **Realtime contract:** fixed/preallocated state; immutable/precomputed snapshots; no allocation/free, locks, logging, file/device/UI access, filter design, or coefficient construction in the render callback; zero added algorithmic latency for PR32 stages.
- **Validation:** deterministic coverage includes high-rate finite operation, new-parameter validation, feed-back compressor stability, bounded De-Esser attenuation, multiband independent controls, dialogue disabled transparency, program gating, relative-masking response, maximum-boost bounds, and voice-confidence bounds. Full integration suites were green before the hardware gate.
- **Residual audit:** `docs/PR32_DYNAMICS_PARITY_AUDIT.md` explicitly routes remaining required observable items rather than silently omitting them. General Dynamic EQ, Dynamic Gain Rider/auto-headroom, explicit True-Peak Guard semantics, clipper asymmetry trim, per-band loudness, De-Harsh, and EQ/DSP automatic-headroom compensation are assigned to the immediately following parity PR before optimization.


## PR33 Slice 2 — gain/protection integration

Classification: **specification-derived / independently authored commercial implementation**.

Behavioral inventory references are limited to observable legacy configuration/UI state: Dynamic Gain Rider enable/target/max-cut/Fast-Medium-Slow controls; the distinct TP Guard toggle; ±3 dB clipper asymmetry trim; and EQ Headroom Compensation enable/3–24 dB maximum attenuation. Historical gain-rider, limiter, clipper, or EQ-headroom DSP implementations and historical DSP tests are not implementation references.

The commercial algorithms are derived independently from standard level/envelope smoothing, oversampled peak protection, bounded gain-riding, and pre-EQ gain-staging principles. The realtime path remains fixed/preallocated and performs no allocation, locking, logging, file/device/UI access, or coefficient/filter design.


## PR33 Slice 3 — per-band loudness and De-Harsh

Classification: **specification-derived / independently authored commercial implementation**.

Observable legacy configuration/UI state was used only to establish controls, ranges, defaults, labels, and intended user-facing semantics for Per-Band Loudness Compensation and De-Harsh. The historical `PerBandLoudnessCompensator` implementation, historical dynamics processor implementation, and historical DSP tests were not used as coding templates.

Commercial Per-Band Loudness uses independently defined reference-point mapping, fixed precomputed low/high analysis bands, smoothed linked-stereo gain offsets, and explicit caps. De-Harsh uses public RBJ-style high-shelf biquad mathematics already used elsewhere in the clean-room commercial engine. Both remain zero-lookahead and fixed/preallocated in realtime.
