# PR34 Comprehensive Legacy Source Parity Audit

Status: **IN PROGRESS — do not claim full parity from this document yet.**

This ledger is source-driven. The legacy user guide is supplementary evidence only. The audit uses the legacy source tree, configuration/state models, reachable UI wiring, routing/pipeline code, preset models, and tests as behavioral evidence while respecting the clean-room restriction against copying or translating historical DSP implementation expression.

## Classification

- **IMPLEMENTED / IMPROVED** — commercial product already covers the observable capability.
- **LATER MILESTONE** — required parity capability belongs to an explicit later roadmap milestone.
- **OUT OF CURRENT PRODUCT SCOPE** — excluded by current product directive.
- **MISSING / BLOCKER** — required observable capability currently has neither equivalent commercial behavior nor an adequate later disposition.
- **LEGACY-DEAD / UNREACHABLE** — source exists but is not reachable product behavior; requires source evidence.
- **AUDIT PENDING** — evidence has not yet been sufficient to classify safely.

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

Important distinction: this legacy Mixed Phase mode is a user-selectable EQ processing mode and is not automatically the same thing as measurement-derived excess-phase room correction. The previous roadmap grouping of “mixed/excess phase” must be split during PR34 planning.

## A/B/C/D snapshot compare

**Legacy evidence**
- `EQWindowView` exposes four in-memory EQ snapshot slots A/B/C/D with recall/save/clear behavior.

**Commercial**
- Not yet implemented as product state.

**Classification:** **LATER MILESTONE — Persistence / Presets / Interchange + production UI.**

# Wave B — Output matrix / crossover / speaker channel processing

## Output channel matrix

**Legacy evidence**
- `OutputChannelMatrixConfig`: enabled matrix with 2–8 output channels.
- Each output channel has a named signal source and physical device/channel target.
- `SignalSource` includes full-range mains, Left/Right Low/Mid/High, and Sub Mono.
- Band-split sources depend on bi-amp/tri-amp Active Crossover state.

**Classification:** **LATER MILESTONE — Active Crossover Matrix.**

The later milestone must account for the source/target matrix itself, not just crossover coefficients.

## Per-output channel processing attached to matrix

`OutputChannelConfig` includes observable state for:
- per-output EQ
- pre-EQ gain trim ±24 dB
- polarity inversion
- user delay 0–100 ms
- computed FIR compensation delay
- per-output limiter with ceiling/attack/release/look-ahead
- fitted group-delay all-pass coefficients
- optional 2× per-output EQ oversampling
- excursion protection based on driver Fs/Qts and bounded protection amount/cutoff

**Classification:** **LATER MILESTONE — Active Crossover Matrix / driver-processing parity.**

These must be explicit acceptance items for that milestone. The current simple stereo bass-management crossover is not equivalent.

## Active crossover topology

**Legacy evidence**
- `ActiveCrossoverConfig`: Full Range / Bi-Amp / Tri-Amp.
- Lower and upper crossover points.
- Independent LP/HP frequency, slope, and filter type per crossover point via asymmetric controls.
- Crossover types include Linkwitz-Riley, Butterworth, and FIR Linear Phase.
- `ActiveCrossoverEngine` produces Left/Right Low/Mid/High buses.

**Classification:** **LATER MILESTONE — Active Crossover Matrix.**

Note: the source also contains a placeholder/comment indicating FIR crossover kernel generation was not fully implemented in `ActiveCrossoverEngine` at that point. Reachability and final behavior must therefore be audited before assigning exact FIR-crossover parity requirements.

# Wave C — Multi-device routing / SRC

## Explicit sample-rate conversion

**Legacy evidence**
- `src/dsp/src/SRCProcessor.swift`: arbitrary-rate polyphase SRC up to 384 kHz.
- `src/pipeline/routing/PLLSRCWriter.swift`: SRC used for secondary physical devices.
- `src/pipeline/routing/DeviceClockPLL.swift`: software PLL adjusts secondary-device SRC rate for clock-drift tracking.

**Commercial**
- Current product transport handles its selected output route/sample-rate lifecycle, but no equivalent multi-device secondary-output PLL/SRC matrix has been established.

**Classification:** **LATER MILESTONE — Active Crossover Matrix / physical multi-device routing**, subject to source reachability audit.

This should not be confused with ordinary DSP oversampling.

# Wave D — Metering / analysis

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

Other source modules include `RTAAnalyzer` and `GoniometerEngine`; persisted meter state includes RTA, level meters, VU meters, and source selection.

**Classification:** **LATER MILESTONE — Metering / RTA / Analysis + production UI.**

The current planned metering milestone must be expanded/audited for:
- ISP latch
- DR factor
- bit-stream / effective bit-depth analysis
- VU meters and source selection
in addition to peak/RMS, true peak, RTA/spectrum, phase correlation, crest factor, balance, GR, and goniometer.

# Wave E — Room correction / measurement

Source-level inventory confirms the later room-correction milestone includes significantly more than applying an FIR:
- microphone capture/calibration
- sweep generation/capture/deconvolution
- impulse response
- complex transfer function
- SNR estimation / measurement quality
- multi-position and multi-sweep averaging
- individual output-channel measurement
- combined-channel measurement
- target curves
- parametric correction fitting
- minimum-phase FIR correction
- excess-phase correction
- transfer-function dataset storage
- band-level calibration
- multi-channel correction presets
- diaphragm resonance analysis
- measurement displays including impulse, step, group delay, and energy decay

**Classification:** **LATER MILESTONE — Room Correction**, with exact contract still AUDIT PENDING.

# Wave F — Persistence / presets / interchange

Initial source evidence confirms:
- versioned native preset model and migrations
- `.eqpreset`
- factory-preset metadata
- dynamics and compare-mode persistence
- per-band slope / Dynamic state / constant-Q / Linkwitz state in presets
- dedicated REW import/export
- AutoEQ export
- CamillaDSP export
- EasyEffects import/export
- multi-channel correction presets
- room-correction presets

**Classification:** **LATER MILESTONE — Persistence / Presets / Interchange.**

Exact round-trip semantics and legacy version compatibility remain AUDIT PENDING.

# Wave G — App state / settings

Initial state audit confirms persistence for:
- input/output device choices
- bandwidth display mode
- appearance
- interface style (Dock / menu-bar behavior)
- manual/capture mode
- meter-window state
- VU source
- channel mode/focus
- EQ/dynamics state
- corrupt-state recovery behavior

**Classification:** mostly **LATER MILESTONE — Persistence / production UI / hardening**, with exact disposition AUDIT PENDING.

# Known source areas still to inspect before declaring the audit complete

- full `AdvancedProcessingConfig` field inventory and UI reachability
- all crossover analysis utilities (acoustic summation, baffle-step, group delay, optimizer, path alignment, resonance detection, driver time alignment, excursion limiter)
- full room-correction controls and target-curve library
- `OutputChannelMatrixView` and routing coordinator reachability
- per-output EQ phase modes, including pre-ringing blend
- convolution configuration / standalone IR-loading workflow outside per-band FIR
- RTA / meter implementation contracts and source selectors
- native preset managers, migrations, factory presets, and import/export adapters
- automatic/manual routing modes and capture modes
- device-change / route-recovery / headphone-switch policies
- secondary-output writer and cross-device clock synchronization reachability
- test suite inventory for observable behavior that is not obvious from UI/state
- any dead/experimental source that should be classified LEGACY-DEAD rather than treated as parity debt

# Preliminary conclusion

**We should not claim comprehensive parity yet.** The source-level audit has already uncovered reachable legacy behavior that was not captured in the previous user-guide-driven inventory, especially:

1. Mid-Side EQ editing/processing.
2. Band-Pass, per-band FIR, Linkwitz Transform, and Tilt EQ filter types.
3. 6–96 dB/oct main-EQ slope control.
4. Constant-Q parametric EQ.
5. General Mixed-Phase EQ mode distinct from measurement-derived excess-phase correction.
6. A richer output-channel matrix/driver-processing contract for the later Active Crossover milestone.
7. Additional metering/analysis items such as ISP latch, DR Factor, Bit Stream, and VU behavior.
8. Explicit multi-device PLL/SRC routing behavior.

PR34 optimization work should remain behind this audit until these gaps are dispositioned. Core-EQ gaps that do not belong to an existing later milestone should be closed before the project treats advanced DSP parity as complete.
