# PR34 Parity Disposition and Execution Plan

Status: **SOURCE DISCOVERY SATISFIED; PHASES A-D IMPLEMENTED; PHASE E SOFTWARE GATE SATISFIED; FOCUSED HARDWARE / LISTENING VALIDATION PENDING.**

This document consolidates the source-level audit performed in PR34 and defines the execution order before performance optimisation begins.

It does **not yet declare overall functional parity**. The current stereo product's software blocker queue has been retired and the Phase E software re-audit/regression gate has passed. PR34 must still complete the focused hardware/listening validation before the functional-parity gate can be declared satisfied and performance optimisation can open.

The clean-room rule remains unchanged: legacy source establishes observable contracts and defects only. New production DSP is independently authored.

# 1. Current PR34 blocker queue — CLOSED through Phase D

## Phase A — isolated EQ blockers: COMPLETE

1. **Band Pass — CLOSED**
   - independently implemented constant-0-dB-peak band-pass behavior
   - deterministic validator across supported sample rates
   - available in Minimum- and Linear-Phase projection paths

2. **Constant-Q Parametric — CLOSED**
   - distinct from the retained proportional-Q/default Peak behavior
   - dedicated independently authored transfer function
   - model/UI projection and high-rate validation complete

3. **Linkwitz Transform — CLOSED**
   - typed f0, Q0, fp, Qp contract
   - independently authored digital implementation and regression coverage

## Phase B — compiled main-EQ architecture: COMPLETE

4. **Bounded compiled multi-section main-EQ program — CLOSED**
   - user-band limit remains distinct from compiled section count
   - coefficient design remains off the realtime thread

5. **6–96 dB/oct main-EQ slope control — CLOSED**
   - LP / HP / Low Shelf / High Shelf supported through the compiled representation

6. **Tilt EQ — CLOSED**
   - one logical band compiles to complementary low/high shelving sections

## Phase C — channel / phase architecture: COMPLETE

7. **Mid/Side EQ — CLOSED**
   - independently editable Mid and Side lanes
   - encode/decode wraps the static Minimum-/Linear-/Mixed-Phase EQ path
   - Dynamic EQ remains one linked physical-stereo dynamics layer as audited

8. **Per-band FIR — CLOSED**
   - user-band kernel contract integrated into the commercial convolution path
   - explicit kernel ownership/latency validation retained

9. **Mixed Phase EQ — CLOSED**
   - distinct from room-correction excess phase
   - bounded all-pass correction architecture with no hidden FIR substitution

## Phase D — current stereo spatial / alignment parity: COMPLETE

10. **Symmetry Balance — CLOSED**
    - separate constant-power listening-position compensation
    - center-normalized law; distinct from ordinary attenuation-style Balance

11. **Panning Gain Matrix / speaker crossfeed — CLOSED**
    - speaker feature retained with the audited effective 0...0.5 range
    - 0 = identity; 0.5 = mono collapse

12. **Speaker Crosstalk Cancellation — CLOSED**
    - independently authored bounded feed-forward cancellation stage
    - Amount and Head-Shadow controls retained without recursive instability

13. **Sub-Bass Phase Alignment — CLOSED**
    - independent all-pass phase-alignment stage on the mono sub leg
    - separate from polarity, sub gain and ordinary time delay

14. **Advanced standalone FIR Impulse Response mapping — CLOSED**
    - product disposition resolved as a third independent global **Speaker IR** convolution slot
    - remains separate from the main-EQ/per-band FIR convolver and room-correction convolver
    - all three FIR workflows can be active simultaneously
    - additive latency and independent prepared-program generations are regression tested
    - raw Global Bypass remains untreated
    - production WAV/AIFF import and resource persistence remain assigned to the later persistence milestone rather than being falsely claimed in PR34

# 2. Explicit later-milestone parity — not current stereo-core blockers

## Active Crossover Matrix / physical multi-output

- per-output driver processing
- per-output EQ/gain/delay/polarity
- Speaker IR / acoustic-center alignment
- output protection and per-output telemetry
- Aggregate Device routing
- Software PLL routing
- explicit arbitrary/fractional SRC
- per-device clock lock/drift/latency telemetry
- group-delay crossover analysis/correction
- predicted acoustic summation
- crossover-frequency optimisation
- per-output EQ optimisation
- broadband driver time alignment
- polarity diagnosis
- crossover-frequency acoustic-center refinement
- baffle-step recommendations
- diaphragm-resonance suggestions
- combined-system verification
- CamillaDSP advanced export

Known legacy defects intentionally excluded from this future milestone:

- no-op crossover slope-optimisation toggle
- no-op optimiser delay toggle
- ambiguous delta-vs-absolute optimiser Apply-All EQ result semantics
- comments claiming output-channel controls that were not actually rendered/reachable

## Room Correction / measurement

- physical microphone capture
- 20 Hz–20 kHz logarithmic sweeps
- multiple sweeps per position
- multiple microphone positions / seats
- SNR/quality reporting and improved retry/exclusion handling
- reflection-reduced/time-windowed IR analysis
- microphone calibration, including hybrid free/diffuse-field workflow
- complex-domain response averaging
- built-in/custom target curves
- IIR room correction
- minimum-phase FIR correction
- measurement-derived excess-phase correction
- individual-vs-combined verification
- measurement/correction asset persistence
- impulse/step/energy-decay/group-delay views

The commercial convolution/room-correction runtime is an **IMPLEMENTED / IMPROVED foundation**; the complete measurement/design/product workflow is later.

## Metering / RTA / production analysis UI

- calibrated Peak/RMS meters
- VU meters
- RTA through 384 kHz
- phase correlation
- explicitly located crest-factor telemetry
- gain-structure meters
- continuous true-peak/dBTP display
- stereo goniometer
- per-output matrix/protection telemetry when the matrix exists
- honest processing-format/sample-rate display

Legacy analytics defects intentionally excluded:

- sample-peak latch mislabeled as ISP
- `DR Factor` presented as though it were a standardized DR statistic
- 24-bit Bit Stream LEDs derived from one quantized peak scalar rather than source-bit analysis
- `Bit Rate` wording that can be mistaken for source-media bitrate

## Persistence / import-export

- new versioned commercial preset schema
- v1/v2 legacy `.eqpreset` migration
- Pause Gate Attack/Release semantic translation
- REW import
- EasyEffects import/export
- room-correction project/measurement persistence
- resource-backed FIR / Speaker IR persistence
- factory/product preset pack
- advanced CamillaDSP export after output-matrix completion

Historical Constant-Q and Linkwitz target values cannot be assumed recoverable from legacy `.eqpreset` files because the audited legacy serializer did not actually encode/decode/apply them.

## Output format / release hardening

- Dither only where Notch Sixty intentionally owns a fixed-bit-depth terminal conversion or export boundary
- no legacy 24-bit quantizer inserted into the current Float32 realtime transport merely for historical parity

# 3. Implemented / improved current-scope behavior

The audit confirms the commercial rewrite now has implemented/improved foundations or complete current-scope behavior for:

- first-party stereo output lifecycle
- output enumeration/selection by stable UID
- sample-rate-change rebuild/recovery
- selected-output disappearance/return recovery
- hardware volume/mute synchronization where available
- software gain fallback for fixed-volume devices
- current stereo Reference / Delta / audition-alignment architecture
- broad dynamics/protection chain built through PR33
- compressor/expander/de-esser/multiband/clipper/limiter processor capability
- commercial Pause Gate convention with clearer Attack=fade-out and Release=fade-in semantics
- compiled multi-section EQ, high-order slopes, Tilt, Band Pass, Constant-Q and Linkwitz Transform
- linked/independent/Mid-Side static EQ modes
- Minimum-, Linear- and Mixed-Phase EQ architecture
- per-band FIR plus independent global main-EQ convolution
- room-correction runtime/convolution foundation
- independent global Speaker IR convolution
- true-peak protection/telemetry foundation
- bass-management crossover/gain/polarity/time-alignment foundation
- sub-bass all-pass phase alignment
- Symmetry Balance, speaker crossfeed and speaker crosstalk cancellation
- ordinary user Balance control
- signed L/R speaker-alignment delay
- current single-output transport and deterministic high-rate tests

Fresh-install default tuning differences documented in the dynamics audit are intentional product choices where legacy parameter values remain representable.

# 4. Proven legacy dead/no-op behavior

These do not require commercial recreation:

- Hardware Sync Buffer setter/state
- Music/Movie Latency Mode setter/state
- crossover optimiser `optimise slopes` toggle in the audited implementation
- crossover optimiser `optimise delay` toggle in the audited implementation

# 5. Out of current product scope

Consistent with the speaker-focused Notch Sixty product definition:

- headphone-only processing/workflows
- headphone automatic-output-switch policy
- headphone-focused AutoEQ export/workflows unless a separate speaker-oriented interchange case is later defined

# 6. Known migration corrections / legacy defects to preserve as knowledge, not behavior

- legacy Pause Gate Attack=open/fade-in -> commercial Release
- legacy Pause Gate Release=close/fade-out -> commercial Attack
- legacy Panning Crossfeed UI exposed 0...1 but runtime effectively clamped to 0...0.5
- legacy Constant-Q / Linkwitz target preset persistence was incomplete
- legacy `ISP` latch was sample-peak-based, not true inter-sample peak
- legacy DR/Bit Stream/Bit Rate analytics labels overclaimed what the implementation measured
- legacy active-crossover optimiser had delta-vs-absolute Apply-All ambiguity
- stale target-curve comments included terminology inconsistent with the actual loudspeaker-room use

# 7. PR34 execution queue

## Phase A — COMPLETE

- Band Pass
- Constant-Q Parametric
- Linkwitz Transform

## Phase B — COMPLETE

- bounded compiled multi-section EQ program
- 6–96 dB/oct slopes
- Tilt EQ

## Phase C — COMPLETE

- Mid/Side EQ
- per-band FIR
- Mixed Phase EQ

## Phase D — COMPLETE

- Symmetry Balance
- Panning Gain Matrix / speaker crossfeed
- Crosstalk Cancellation
- Sub-Bass Phase Alignment
- independent global Speaker IR mapping

## Phase E — SOFTWARE COMPLETE; HARDWARE VALIDATION PENDING

Completed software checks:

- reran the legacy behavior ledger against the current commercial graph and recorded the reconciliation in `PR34_PHASE_E_PARITY_REAUDIT.md`,
- verified every current-scope audited capability is implemented/improved or explicitly assigned to the correct later milestone / out-of-scope / legacy-dead disposition,
- verified no current software blocker remains unexplained,
- ran the accumulated deterministic high-rate regression coverage through the supported sample-rate set including 384 kHz where applicable,
- verified the three FIR workflows remain simultaneously representable with independent program generations and additive latency,
- verified Reference / Delta / Global Bypass latency semantics against the cumulative graph-latency contract,
- reviewed the new structural paths for realtime allocation/design/blocking regressions,
- normal macOS build/XCTest and the read-only PR34 Parity Regression Gate are green on the Phase E software baseline.

Remaining exit gate:

- focused hardware/listening validation on the structural audio changes using the checklist in `PR34_PHASE_E_PARITY_REAUDIT.md`.

Only after that hardware pass does PR34 move to performance optimisation.

# 8. Performance optimisation gate

Once Phase E hardware validation passes, establish repeatable baseline profiles at:

- 48 kHz
- 96 kHz
- 192 kHz
- 384 kHz

and for representative/worst-case combinations including:

- 64-band EQ / Dynamic EQ
- high-order slopes
- Linear Phase
- Mixed Phase
- per-band FIR + main-EQ/global convolution + room correction + Speaker IR
- denoiser Quality/High/Ultra
- 4x protection
- bass management
- full current stereo processing chain

Only measured hotspots should be changed. Every optimisation must retain sonic/functional acceptance and realtime-safety contracts.

# 9. Gate result

**PR34 source-discovery gate: SATISFIED for the current stereo product.**

**PR34 implementation blocker gate (Phases A-D): SATISFIED.**

**PR34 Phase E software parity/regression gate: SATISFIED.**

**PR34 focused hardware/listening gate: PENDING.**

**PR34 functional-parity gate: NOT YET SATISFIED solely because the required hardware/listening validation remains open.**

**PR34 optimisation gate: CLOSED until the hardware/listening pass is accepted.**

The next PR34 activity is the **focused hardware/listening test build** defined in `PR34_PHASE_E_PARITY_REAUDIT.md`.
