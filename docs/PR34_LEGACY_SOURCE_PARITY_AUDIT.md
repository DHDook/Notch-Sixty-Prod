# PR34 Comprehensive Legacy Source Parity Audit

Status: **IN PROGRESS — do not claim full parity from this document yet.**

This ledger is source-driven. The legacy user guide is supplementary evidence only. The audit uses the legacy source tree, configuration/state models, reachable UI wiring, routing/pipeline code, preset models, measurement/metering modules, and tests as behavioral evidence while respecting the clean-room restriction against copying or translating historical DSP implementation expression.

## Classification

- **IMPLEMENTED / IMPROVED** — commercial product already covers the observable capability.
- **LATER MILESTONE** — required parity capability belongs to an explicit later roadmap milestone.
- **OUT OF CURRENT PRODUCT SCOPE** — excluded by current product directive.
- **MISSING / BLOCKER** — required observable capability currently has neither equivalent commercial behavior nor an adequate later disposition.
- **LEGACY-DEAD / UNREACHABLE** — source exists but is not reachable product behavior; requires source evidence.
- **AUDIT PENDING** — evidence is not yet sufficient to classify safely.

# Wave A — Core EQ / phase / audition

## Band capacity

**Legacy evidence**
- `src/dsp/config/EQConfiguration.swift`: `maxBandCount = 64`.
- UI band-count controls use that model.

**Commercial**
- `N60_MAX_EQ_BANDS = 64`.

**Classification:** IMPLEMENTED / IMPROVED.

## Channel modes: Linked / Stereo / Mid-Side

**Legacy evidence**
- `src/dsp/config/ChannelMode.swift`: `.linked`, `.stereo`, `.midSide`.
- `src/ui/views/main/EQWindowView.swift`: segmented `Linked / Stereo / M/S` picker and independent Mid/Side editing.

**Commercial**
- `StereoEQConfiguration` currently supports `.linked` and `.independent` L/R only.

**Classification:** **MISSING / BLOCKER — Mid-Side EQ editing/processing.**

This is separate from the stereo widener; the legacy app exposes a true Mid/Side EQ editing mode.

## Main EQ filter types

**Legacy reachable UI contract**
`FilterType.allCasesInUIOrder` and `EQBandSliderView` expose:
- Parametric
- Low Pass
- High Pass
- Low Shelf
- High Shelf
- Band Pass
- Notch
- All-Pass
- per-band FIR
- Linkwitz Transform
- Tilt EQ

**Commercial currently exposes**
- Peak
- Low Shelf
- High Shelf
- Low Pass
- High Pass
- Notch
- All-Pass

**Classification**
- Parametric / LP / HP / shelves / notch / all-pass: IMPLEMENTED / IMPROVED.
- **Band Pass: MISSING / BLOCKER.**
- **Per-band FIR / user-loaded IR: MISSING / BLOCKER.** Existing graph convolution and linear-phase EQ are not automatically equivalent to a user-selected FIR band.
- **Linkwitz Transform: MISSING / BLOCKER.**
- **Tilt EQ: MISSING / BLOCKER.**

## Filter slope control

**Legacy evidence**
- `src/dsp/config/FilterSlope.swift` exposes 6, 12, 18, 24, 36, 48, 60, 72, 84, and 96 dB/oct.
- Applies to LP / HP / Low Shelf / High Shelf.
- `EQBandSliderView` exposes the full slope picker.

**Commercial**
- Main EQ bands currently do not carry this slope contract.

**Classification:** **MISSING / BLOCKER.**

## Constant-Q parametric option

**Legacy evidence**
- `EQBandConfiguration.constantQ`.
- `EQBandSliderView` exposes a `Constant-Q` toggle for parametric bands.
- Help text identifies it as fixed-bandwidth constant-Q versus standard proportional-Q behavior.

**Commercial**
- No main-EQ constant-Q mode currently exposed.

**Classification:** **MISSING / BLOCKER.**

## Linkwitz Transform target frequency

**Legacy evidence**
- `EQBandConfiguration.linkwitzTargetHz`.
- UI exposes target frequency when Filter Type is Linkwitz Transform.

**Classification:** part of the **MISSING Linkwitz Transform** capability above.

## Per-band FIR / IR loading

**Legacy evidence**
- `EQBandConfiguration` stores left/right FIR kernels and display name.
- `EQBandSliderView` exposes `Load IR…` and Clear controls for FIR bands.
- `EQCoefficientStager` routes FIR-band data into the linear-phase path.

**Commercial**
- Has general FIR/convolution infrastructure and a linear-phase EQ engine, but no equivalent user-visible FIR filter type on an ordinary EQ band.

**Classification:** **MISSING / BLOCKER** unless a future product decision deliberately supersedes the workflow with equivalent import behavior. No such disposition is recorded yet.

## Dynamic EQ integration

**Legacy evidence**
- Dynamic parameters are stored inline on each EQ band and UI toggles Parametric / Dynamic.
- Legacy UI enforced up to 16 simultaneous Dynamic bands.
- In Stereo/Mid-Side mode, UI explicitly states Dynamic EQ applies identically to all channels.

**Commercial**
- PR33 intentionally improved capacity to 64 and unified Dynamic state into ordinary EQ bands.
- Current supported contract is linked-stereo Minimum Phase peaking bands.

**Classification:**
- Inline product model + 64-band capacity: IMPLEMENTED / IMPROVED.
- **Stereo/Mid-Side compatibility semantics: AUDIT PENDING / likely gap** once the missing Mid-Side mode is implemented. Do not silently treat linked-only behavior as full legacy equivalence.

## Compare / phase modes

**Legacy evidence**
- `CompareMode`: EQ, Linear EQ, Flat, Delta, Mixed Phase.
- `EQWindowView` exposes all five modes in the main UI.
- `EQCoefficientStager.refreshMixedPhaseIRIfNeeded()` confirms Mixed Phase is not dead UI state; it builds all-pass phase-complement data for the active EQ layers.

**Commercial**
- Minimum Phase and Linear Phase are implemented.
- Processed / latency-matched Reference / Delta plus raw Global Bypass cover the comparison use cases with an improved latency contract.
- No general main-EQ Mixed Phase mode exists.

**Classification:**
- EQ / Linear: IMPLEMENTED.
- Flat / Delta comparison semantics: IMPLEMENTED / IMPROVED by Processed / Reference / Delta + raw Global Bypass.
- **Mixed Phase EQ: MISSING / BLOCKER.**

Important distinction: this legacy Mixed Phase mode is a user-selectable EQ processing mode and is not automatically the same thing as measurement-derived excess-phase room correction. The previous roadmap grouping of “mixed/excess phase” must remain split.

## A/B/C/D snapshot compare

**Legacy evidence**
- `EQWindowView` exposes four in-memory EQ snapshot slots A/B/C/D with recall/save/clear behavior.

**Commercial**
- Not yet implemented as product state.

**Classification:** **LATER MILESTONE — Persistence / Presets / Interchange + production UI.**

# Wave B — Advanced dynamics / conditioning / spatial controls

A source-level pass through `AdvancedProcessingConfig` plus the reachable `DynamicsInlineView` shows that the legacy product surface is larger than the earlier user-guide inventory. This section distinguishes controls already rebuilt in PR28–33 from still-missing reachable behavior.

## Already rebuilt / improved in the commercial engine

Legacy UI contains reachable controls for Infrasonic Filter, Mains Hum Notch, Spectral Denoiser, DC Filter, Stereo Widener, LUFS Loudness Match, Loudness Contour, De-Esser, Multiband Compressor, Compressor, Expander, Dynamic Gain Rider, Soft Clipper, Limiter, De-Harsh, Dialogue-Relative Leveler, Pause Gate, and oversampling.

Commercial `DynamicsConfiguration` and `N60Dynamics` currently carry corresponding production structures/runtime for these features, including De-Harsh, Dialogue Relative Leveler, Dynamic EQ, compressor topology/time constants, multiband makeup/sidechains, Gain Rider, Automatic Headroom, Mains Hum detection/tracking, Spectral Denoising, and linked stereo processing.

**Classification:** **IMPLEMENTED / IMPROVED**, subject to the remaining parameter-by-parameter contract audit rather than feature-existence audit.

The audit still must verify all legacy parameter ranges/defaults where they are product-visible. A differently named or improved control may satisfy parity only where its observable purpose is actually equivalent.

## Standalone FIR Impulse Response vs FIR Correction

**Legacy evidence**
- `DynamicsInlineView` exposes a reachable `FIR IR` control described as a user-supplied impulse response slot distinct from `FIR Correction`.
- `AdvancedProcessingConfig.firImpulseResponse` persists its own IR state.
- The same UI separately exposes `FIR Correction` later in the chain.
- `DynamicsProcessorTests.testApplyConfigChangeDetection()` configures `firImpulseResponse`, applies it to the live processor, records the convolution delay, changes the IR, and verifies that the live convolution program changes only when the FIR config changes. This confirms the raw FIR IR slot is not dead state.

**Commercial**
- Has general convolution infrastructure and a room-correction runtime FIR slot, but the audit has not yet established two separately user-addressable raw-IR/correction workflows matching this legacy surface.

**Classification:** **AUDIT PENDING / likely gap.** This must be resolved together with per-band FIR and the Persistence/Interchange milestone so multiple legacy FIR workflows are not accidentally collapsed without an explicit product decision.

## Speaker IR Alignment

**Legacy evidence**
- `AdvancedProcessingConfig.speakerIRAlignmentEnabled` and `speakerIRDelayMs`.
- Reachable `IR Align` toggle/settings in `DynamicsInlineView`.
- UI describes fractional-sample delay compensation for multi-driver speaker acoustic centres.

**Commercial**
- Has signed inter-channel fractional delay for L/R alignment, but not a verified independent per-driver physical path at present.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / driver time alignment**, where independent physical outputs make the feature meaningful.

## Sub-Bass Phase Alignment

**Legacy evidence**
- Reachable `Sub Align` control.
- Config exposes enable, target frequency, and Q for an all-pass sub-bass alignment network.

**Commercial**
- Current stereo transport cannot independently apply relative sub-path phase correction to a separate physical sub output.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / room-correction-assisted sub integration.**

## Symmetry Balance

**Legacy evidence**
- Legacy has ordinary `channelBalance` and, separately, `symmetryBalanceEnabled` using `stereoBalancePosition`.
- Reachable `Sym. Bal.` control is described as correction for asymmetric listening positions.
- `DynamicsProcessor` confirms the two paths have different observable laws: ordinary channel balance linearly attenuates the opposite channel, while enabled Symmetry Balance applies a separate constant-power sine/cosine L/R law with unity gain at centre.

**Commercial**
- `PlaybackControlConfiguration.balanceLinearGains` implements the ordinary linear balance law, not the separate constant-power legacy symmetry mode.

**Classification:** **MISSING / BLOCKER.** Ordinary channel balance does not satisfy this separate reachable legacy capability.

## Panning Gain Matrix

**Legacy evidence**
- Reachable `Panning` control and `panningCrossfeedAmount`.
- UI describes a bilinear cross-channel blend.
- `DynamicsProcessor` reads the enable flag on the render path and conditionally executes `processPanningMatrix` after true-peak measurement and before Crosstalk Cancellation / Pause Gate.

**Commercial**
- No corresponding control is presently identified in `DynamicsConfiguration`.

**Classification:** **MISSING / BLOCKER pending product-scope decision.** It is a reachable legacy speaker-processing feature; it must not be silently discarded merely because headphone crossfeed is out of scope.

## Crosstalk Cancellation Matrix

**Legacy evidence**
- Reachable `Crosstalk` toggle/settings.
- Persisted amount and head-shadow frequency controls.
- UI describes a recursive binaural inversion filter for reducing **inter-speaker acoustic leakage**.
- `DynamicsProcessor` reads the enable flag on the render path and executes `processCrosstalkCancellation` after the Panning Matrix.

**Commercial**
- No corresponding current production configuration has been identified.

**Classification:** **MISSING / BLOCKER pending product-scope decision.** This is source-reachable and speaker-oriented, not automatically excluded by the no-headphone directive.

### Correction to the earlier PR33 audit

`PR33_FINAL_DYNAMICS_PARITY_AUDIT.md` grouped “headphone-only spatial/crossfeed/crosstalk features” as out of current scope. The source-level PR34 audit supersedes that blanket classification for the reachable Panning Gain Matrix and Crosstalk Cancellation controls: the actual UI describes speaker-oriented behavior and the render path executes both. They therefore require an explicit commercial disposition.

## Hi-Res Coefficient Decoupling

**Legacy evidence**
- Reachable `Hi-Res Coef` toggle; persisted `coefficientDecouplingEnabled` and runtime active status.
- Legacy processing stores the setting and uses it when designing/staging high-rate coefficients.

**Commercial**
- Current C filter engine has deterministic coverage through 384 kHz and independently authored high-rate numerical handling, but no equivalent user-visible decoupling switch.

**Classification:** **AUDIT PENDING, likely IMPLEMENTED / IMPROVED if the PR34 high-rate accuracy baseline demonstrates no need for the legacy workaround.** Do not recreate a compatibility toggle solely because the legacy implementation needed one.

## Hardware Sync Buffer

**Legacy evidence**
- Reachable `Sync Buffer` toggle through `hardwareSyncBufferEnabled`.
- In `DynamicsProcessor`, the setting is declared, initialised, and written by a setter, but the audit has not found a read or render-path use of `_syncBufferEnabled`.

**Classification:** **AUDIT PENDING — likely LEGACY-DEAD / NO-AUDIO-EFFECT.** Complete repo-wide search before making the dead-code classification final.

## Latency Mode: Music / Movie

**Legacy evidence**
- Reachable segmented `Latency Mode` picker with Music and Movie values.
- `DynamicsProcessor` declares, initialises, and sets `_latencyModeBits`, but no render-path read has yet been identified.

**Classification:** **AUDIT PENDING — likely LEGACY-DEAD / NO-AUDIO-EFFECT.** Complete repo-wide search before final disposition.

## Dither

**Legacy evidence**
- Reachable picker exposes Off / TPDF / Shape / 5th.
- `DynamicsProcessor` reads `ditherMode` every callback and executes the dither stage on the live signal before Delta Solo / active-crossover splitting.
- Legacy source identifies the modes as flat TPDF, first-order noise-shaped, and fifth-order noise-shaped dither at a 24-bit LSB scale.

**Commercial**
- No equivalent current product control has yet been identified.

**Classification:** **LATER MILESTONE — final output-format / hardening.** Dither is confirmed live legacy behavior, but the commercial disposition should be made against the final device/output format architecture rather than inserted blindly into the current floating-point graph.

## EQ Headroom Compensation

**Legacy evidence**
- Reachable `EQ Headroom` toggle/settings, described as predictive static preamp attenuation based on EQ/correction boosts.

**Commercial**
- `AutomaticHeadroomConfiguration` plus conservative static headroom computation are present in the current commercial configuration, alongside the separate reactive Gain Rider.

**Classification:** **IMPLEMENTED / IMPROVED**, pending final range/default comparison.

# Wave C — Output matrix / crossover / speaker channel processing

## Output channel matrix

**Legacy evidence**
- `OutputChannelMatrixConfig`: enabled matrix with 2–8 output channels.
- Each output channel has a named signal source and physical device/channel target.
- `SignalSource` includes full-range mains, Left/Right Low/Mid/High, and Sub Mono.
- Band-split sources depend on bi-amp/tri-amp Active Crossover state.
- `SettingsView` directly embeds `OutputChannelMatrixView` as the reachable `Crossover` settings tab.

**Classification:** **LATER MILESTONE — Active Crossover Matrix.**

The later milestone must account for the source/target matrix itself, not just crossover coefficients.

## Per-output channel processing attached to matrix

`OutputChannelRowView` and `OutputChannelConfig` expose reachable state for:
- named channel and enable state
- source assignment
- physical output device/channel assignment
- per-output EQ
- pre-EQ gain trim ±24 dB
- polarity inversion
- user delay
- computed FIR compensation delay
- per-output limiter
- fitted group-delay all-pass coefficients
- optional 2× per-output EQ oversampling
- excursion protection based on driver Fs/Qts and bounded protection amount
- baffle-step compensation calculator/application
- diaphragm resonance detection and one/all-notch application
- pre/post-limiter channel metering

**Classification:** **LATER MILESTONE — Active Crossover Matrix / driver-processing parity.**

## Output-channel EQ capability matrix

**Legacy evidence**
- `OutputChannelEQView` is reachable from each matrix output row.
- Stereo-capable outputs expose EQ / Linear / Mixed / Flat / Delta and Linked / Stereo / Mid-Side channel modes.
- Band-split mono-per-side outputs suppress channel modes but retain advanced phase and Delta capability.
- Sub Mono is deliberately restricted to 16 bands and suppresses advanced phase / Delta.
- Output EQ exposes input/output gain, global bypass/flatten, and optional 2× EQ oversampling for advanced-phase-capable outputs.

**Important dead/unimplemented nuance**
- `OutputChannelEQConfig.preRingingBlend` exists in model state, but the actual `OutputChannelEQView` phase-shaping slider is hard-coded to `0.0`, disabled, ignores writes, and explicitly states that minimum-phase blending is not implemented.

**Classification:**
- Output-channel EQ feature family: **LATER MILESTONE — Active Crossover Matrix.**
- Adjustable output-EQ pre-ringing blend: **LEGACY-DEAD / UNIMPLEMENTED CONTROL; not a parity requirement.**
- Exact per-output filter-type/slope UI parity remains **AUDIT PENDING** because comments claim full mains-EQ reuse while the current view body must still be checked against the actual controls rendered.

## Active crossover topology

**Legacy evidence**
- Full Range / Bi-Amp / Tri-Amp.
- Lower and upper crossover points.
- Configuration model permits independent LP/HP frequency, slope, and filter type per crossover point via asymmetric controls.
- Crossover types include Linkwitz-Riley, Butterworth, and FIR Linear Phase.
- `ActiveCrossoverEngine` produces Left/Right Low/Mid/High buses.
- UI includes Single Amp, Vertical/Horizontal Bi-Amp, and Vertical/Horizontal Tri-Amp quick topology templates.

**Classification:** **LATER MILESTONE — Active Crossover Matrix.**

**Audit caution:** the source also contains a placeholder/comment indicating FIR crossover kernel generation was not fully implemented at that point. Exact FIR-crossover parity requirement remains **AUDIT PENDING** until end-to-end reachability/behavior is confirmed.

## Multi-device synchronization

**Legacy reachable UI evidence**
- Device Synchronisation section appears when matrix channels target more than one physical device.
- User can choose Aggregate Device or Software PLL.
- Aggregate mode exposes clock-master choice.
- Software PLL exposes primary-device choice and lock/status UI.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / physical multi-device routing.**

## Crossover analysis suite

`CrossoverAnalysisView` is embedded directly in the output matrix and exposes five analysis tabs:
- Group Delay
- Summation
- Optimise
- Time Alignment
- Verification

Reachable behaviors found so far include:
- compute per-channel group-delay curves
- detect adjacent-driver group-delay mismatch near crossover points
- auto-correct group delay with persisted per-output all-pass coefficients
- predicted acoustic summation
- live microphone/RTA overlay on the summation display
- crossover optimisation using measured transfer-function data
- driver time alignment
- polarity detection
- crossover-frequency alignment refinement
- combined multi-driver verification measurement

**Classification:** **LATER MILESTONE — Active Crossover Matrix + Room Correction measurement infrastructure.** The crossover milestone must not be reduced to routing/filter creation alone.

## Band-level calibration and system presets

**Legacy reachable UI evidence**
- Level Calibration workflow using pink noise/SPL measurement.
- Speaker System Preset save/load controls.
- Coordination warnings for overlap/notch/subwoofer conditions.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / Persistence.**

# Wave D — Multi-device routing / SRC / device lifecycle

## Explicit sample-rate conversion

**Legacy evidence**
- `src/dsp/src/SRCProcessor.swift`: arbitrary-rate polyphase SRC up to 384 kHz.
- `src/pipeline/routing/PLLSRCWriter.swift`: SRC used for secondary physical devices.
- `src/pipeline/routing/DeviceClockPLL.swift`: software PLL adjusts secondary-device SRC rate for clock-drift tracking.

**Commercial**
- Current product transport handles its selected output route/sample-rate lifecycle, but no equivalent multi-device secondary-output PLL/SRC matrix has been established.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / physical multi-device routing.**

This must not be confused with DSP oversampling.

## Automatic vs Manual routing and capture modes

**Legacy reachable Settings UI**
- Automatic routing mode managed by the virtual driver.
- Manual routing with explicit input/output selection.
- Manual mode microphone-permission flow.
- Automatic-driver capture supports `Shared Memory` and `HAL Input` modes.
- Shared Memory is described as the preferred lock-free path without microphone indicator; HAL Input is the fallback and requires microphone permission.

**Classification:** **AUDIT PENDING — commercial transport / App Store architecture.** The clean commercial product may intentionally replace legacy-driver mechanics, but equivalent end-user routing/recovery behavior must be accounted for explicitly rather than copied mechanically.

## Device disconnect / replacement recovery

**Legacy evidence**
- `DeviceChangeCoordinator` monitors selected-output loss, maintains output-device history, and selects a replacement from history or currently valid devices.
- Built-in-device add/remove behavior is separately handled for headphone switching.

**Classification:**
- General selected-output loss/replacement behavior: **LATER MILESTONE — hardening / device recovery**, subject to comparison with current `AudioIOEngine` recovery.
- Headphone-specific automatic switching: **OUT OF CURRENT PRODUCT SCOPE** under the explicit no-headphone-feature directive, while retaining the non-headphone recovery semantics above.

# Wave E — Metering / analysis

**Legacy reachable UI evidence**
`EQWindowView` exposes dedicated RTA, Levels, and Analytics windows. Analytics definitions include:
- Gain Structure
- Phase Correlation
- Crest Factor
- ISP Latch
- DR Factor
- Bit Stream
- True Peak
- Stereo Goniometer

Other source modules include `RTAAnalyzer`, `GoniometerEngine`, peak/RMS/VU views, and persisted VU source selection.

The legacy RTA is not a generic single FFT display: source identifies a dual pre-EQ/post-processing 31-band ISO 1/3-octave analyzer with peak hold, standard/slow-average modes, multi-resolution FFT lanes, and analysis gating by window visibility/enabled state.

**Classification:** **LATER MILESTONE — Metering / RTA / Analysis + production UI.**

The metering milestone must explicitly audit:
- peak / RMS
- dual pre/post RTA
- 31-band 1/3-octave display contract
- peak hold and slow averaging
- true peak / ISP latch
- phase correlation
- crest factor
- DR factor
- bit-stream / effective bit-depth analysis
- gain structure
- stereo goniometer
- VU meters and source selection
- per-stage / per-output GR and level telemetry where exposed elsewhere

# Wave F — Room correction / measurement

Source-level inventory confirms the later room-correction milestone includes substantially more than applying an FIR:
- microphone enumeration/selection and permission flow
- microphone calibration
- sweep generation/capture/deconvolution
- impulse response
- complex transfer function
- magnitude response
- SNR estimation / measurement quality
- individual output-channel measurement
- combined-channel measurement
- multi-position measurement with explicit microphone reposition prompts
- multiple sweeps per position and averaging
- transfer-function dataset state
- reflection/time-window controls elsewhere in the room-correction flow
- target-curve selection
- parametric correction fitting
- minimum-phase FIR correction
- excess-phase correction
- band-level calibration
- multi-channel correction presets
- diaphragm resonance detection
- measurement displays including impulse response, step response, group delay, and energy decay

`MultiChannelMeasurementView` exposes:
- Individual vs Combined measurement mode
- Main Chain and individual output-channel selection
- microphone selection
- 1–5 mic positions
- 1–5 sweeps per position
- 5–30 second sweep duration
- 20–50 dB minimum SNR control
- result comparison/overlay and correction-preset controls

The legacy target library contains named targets:
- Flat
- Harman room
- B&K house
- Home theater
- X-Curve (cinema)
- Sub-only

**Classification:** **LATER MILESTONE — Room Correction**, with exact correction-generation and import/export contract still **AUDIT PENDING**.

The commercial room-correction design may improve these algorithms, but the named user workflows and observable controls must be dispositioned.

# Wave G — Persistence / presets / interchange

Source evidence confirms:
- versioned native preset model and migrations
- `.eqpreset`
- factory-preset metadata / factory preset definitions
- dynamics and compare-mode persistence
- per-band slope / Dynamic state / constant-Q / Linkwitz state in presets
- dedicated REW import/export
- AutoEQ export
- CamillaDSP export
- EasyEffects import/export
- multi-channel correction presets
- room-correction presets
- Speaker System presets for the output matrix

**Classification:** **LATER MILESTONE — Persistence / Presets / Interchange.**

Exact round-trip semantics, which legacy versions must import, factory-preset content, and FIR-kernel embedding behavior remain **AUDIT PENDING**.

# Wave H — App state / settings / shell behavior

Initial state audit confirms persistence/reachability for:
- input/output device choices
- bandwidth display mode (Q vs octaves)
- appearance
- interface style (Dock / menu-bar / both behavior)
- automatic/manual routing mode
- capture mode
- meter-window state
- VU source
- channel mode/focus
- EQ/dynamics state
- corrupt-state recovery behavior
- virtual-driver installation/update status and capture capability fallback

**Classification:** mostly **LATER MILESTONE — Persistence / production UI / hardening**, with exact disposition **AUDIT PENDING**.

Driver-specific mechanics should not automatically be reproduced if the commercial App Store architecture supersedes them; equivalent user-facing routing capability, permissions, recovery, and migration still require explicit disposition.

# Wave I — Legacy test-suite behavioral inventory

The repository contains a substantial root `tests/` tree; parity must therefore not be audited from UI/state alone. Tests are used only to establish observable contracts and known failure modes, never as implementation templates.

Confirmed test families include:
- application/store snapshot and dynamic-band merge behavior
- device change detection, output-device history, and device enumeration
- Active Crossover config decoding and engine behavior
- Baffle Step and resonance behavior
- Bass Management crossover
- Crossover Group Delay
- DC blocker
- Diaphragm Resonance detection
- Dynamics processor
- EQ coefficient-stager consistency
- Excursion Protection limiter
- FFT round-trip
- Infrasonic change/race/stability behavior
- Look-Ahead Limiter
- Loudness Contour
- main-chain limiter regressions
- oversampling
- all-pass chain
- biquad design/filter/math, including Linkwitz-specific tests

The remaining test subtrees still need a complete inventory for room correction, meters, routing/pipeline, presets/interchange, and any legacy-dead feature evidence.

# Known source areas still to inspect before declaring the audit complete

- complete parameter-by-parameter comparison of the legacy dynamics chain against PR28–33 commercial controls
- repo-wide confirmation that Hardware Sync Buffer and Music/Movie Latency Mode are setter-only/no-op state
- exact output-format/release disposition for confirmed-live Dither
- standalone FIR IR slot vs FIR Correction vs per-band FIR distinctions
- full `OutputChannelEQView` parity: verify actual rendered filter-type/slope controls rather than relying on comments/spec text
- crossover optimiser parameters/results and exact apply semantics
- driver time-alignment / polarity / crossover-refinement exact observable contracts
- baffle-step and diaphragm-resonance acceptance semantics
- full room-correction settings UI, microphone calibration file formats, time-windowing, target import/custom editing, correction range/smoothing/boost limits
- `MeterStore` analytics equations, VU calibration/ballistics/source choices, ISP/DR/bitstream contracts
- native preset managers, migrations, factory presets, and every import/export adapter’s supported subset
- automatic/manual routing orchestration, sample-rate changes, sleep/wake, default-device changes, disconnect/reconnect, volume/mute synchronization
- Aggregate Device path vs Software PLL path end-to-end reachability
- complete repository test-suite inventory for observable behavior that is not obvious from UI/state
- any dead/experimental source that should be classified LEGACY-DEAD rather than treated as parity debt

# Current blocker ledger

The source audit has already established these core parity items as unresolved blockers rather than later-milestone work:

1. Mid-Side EQ editing/processing.
2. Band-Pass main-EQ filter.
3. Per-band FIR / loaded-IR main-EQ filter.
4. Linkwitz Transform main-EQ filter.
5. Tilt EQ main-EQ filter.
6. 6–96 dB/oct main-EQ slope control.
7. Constant-Q parametric mode.
8. General Mixed-Phase EQ mode.
9. Symmetry Balance.
10. Panning Gain Matrix unless explicitly superseded/out-scoped by product decision.
11. Crosstalk Cancellation unless explicitly superseded/out-scoped by product decision.

Additional likely gaps remain under AUDIT PENDING and must not be silently treated as parity.

# Preliminary conclusion

**We should not claim comprehensive parity yet.** The source-level audit has already uncovered reachable legacy behavior that was not captured in the previous user-guide-driven inventory. It has also clarified that several major systems already belong cleanly to later roadmap milestones: metering/analysis, persistence/interchange, room correction, Active Crossover Matrix, and final output-format/hardening work.

PR34 optimization work remains behind this audit until the remaining source domains are dispositioned. Core-EQ and other reachable DSP gaps that do not belong to an existing later milestone should be closed before the project treats advanced DSP parity as complete. Missing work must not be silently relabeled as “superseded” without an explicit product rationale and equivalent observable behavior where parity requires it.
