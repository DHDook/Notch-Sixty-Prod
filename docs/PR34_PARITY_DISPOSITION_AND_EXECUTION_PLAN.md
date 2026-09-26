# PR34 Parity Disposition and Execution Plan

Status: **SOURCE DISCOVERY GATE SATISFIED FOR THE CURRENT STEREO PRODUCT; PARITY IMPLEMENTATION REMAINS ACTIVE.**

This document consolidates the source-level audit performed in PR34 and defines the execution order before performance optimisation begins.

It does **not** declare overall functional parity. It declares that the legacy source/test/UI inventory has been inspected deeply enough that the current stereo product's unexplained capability set is no longer open-ended. Known gaps are now either:

- current PR34 blockers,
- explicitly assigned to a later existing milestone,
- intentionally outside current product scope,
- proven legacy dead/no-op behavior,
- or already implemented/improved in the commercial rewrite.

The clean-room rule remains unchanged: legacy source establishes observable contracts and defects only. New production DSP is independently authored.

# 1. Current PR34 parity blockers — implement before performance optimisation

## Core EQ / phase architecture

1. **Band Pass**
   - simple one-section filter family
   - clean-room implementation can use the public W3C/Web Audio Audio EQ Cookbook constant-0-dB-peak BPF definition
   - lowest-risk first blocker

2. **Constant-Q Parametric**
   - per-band mode distinct from current proportional-Q behavior
   - requires independent transfer-function design and model/persistence state

3. **Linkwitz Transform**
   - four physical parameters: f0, Q0, fp, Qp
   - requires typed model extension and independent digital design

4. **Compiled multi-section main-EQ program**
   - structural prerequisite for high-order slopes and compound filters
   - must preserve the 64-user-band product limit independently of compiled section count
   - all coefficient design stays off the realtime thread

5. **6–96 dB/oct main-EQ slope control**
   - LP / HP / Low Shelf / High Shelf
   - implemented on the compiled multi-section representation

6. **Tilt EQ**
   - one logical user band compiling to complementary low/high shelving sections

7. **Mid/Side EQ**
   - independently editable Mid and Side EQ
   - encode/decode must wrap both Minimum-Phase and Linear-Phase paths
   - legacy Dynamic EQ remains linked/identical across M/S lanes; independent M/S dynamic detectors are not required

8. **Per-band FIR**
   - distinct user-band IR/kernel slot
   - requires explicit kernel ownership, latency and transition contract

9. **Mixed Phase EQ**
   - distinct from measurement-derived excess-phase room correction
   - should be built only after the final compiled EQ representation is stable

## Current stereo spatial / alignment parity

10. **Symmetry Balance**
    - distinct constant-power listening-position compensation
    - does not replace the commercial ordinary Balance control

11. **Panning Gain Matrix / speaker crossfeed**
    - confirmed speaker feature
    - effective legacy crossfeed range is 0...0.5 despite a misleading 0...1 UI range

12. **Speaker Crosstalk Cancellation**
    - distinct speaker-processing stage with Amount and Head-Shadow controls
    - must be independently designed with stability/headroom/mono-compatibility tests

13. **Sub-Bass Phase Alignment**
    - tunable all-pass phase alignment near crossover
    - distinct from polarity and ordinary time delay

## FIR product disposition still required inside parity implementation

14. **Advanced standalone FIR Impulse Response slot**
    - confirmed separate legacy global convolution slot from FIR Correction
    - headphone use is outside current scope; speaker raw-IR use is in scope
    - implementation must decide whether the commercial product genuinely needs two simultaneously active global speaker-correction convolution slots or whether one coherent global correction architecture can preserve every in-scope workflow without loss
    - this remains a product-disposition blocker until that mapping is demonstrated explicitly

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
- resource-backed FIR persistence
- factory/product preset pack
- advanced CamillaDSP export after output-matrix completion

Historical Constant-Q and Linkwitz target values cannot be assumed recoverable from legacy `.eqpreset` files because the audited legacy serializer did not actually encode/decode/apply them.

## Output format / release hardening

- Dither only where Notch Sixty intentionally owns a fixed-bit-depth terminal conversion or export boundary
- no legacy 24-bit quantizer inserted into the current Float32 realtime transport merely for historical parity

# 3. Implemented / improved current-scope behavior

The audit confirms the commercial rewrite already has implemented/improved foundations or complete current-scope behavior for:

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
- global convolution/FIR correction runtime foundation
- room-correction runtime/convolution foundation
- true-peak protection/telemetry foundation
- bass-management crossover/gain/polarity/time-alignment foundation
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

## Phase A — retire isolated parity blockers

1. Band Pass
2. Constant-Q Parametric
3. Linkwitz Transform

Each slice requires:

- independently sourced/designed DSP math,
- control-plane validation,
- Minimum-Phase tests,
- Linear-Phase compatibility tests where applicable,
- finite behavior at 44.1/48/88.2/96/176.4/192/352.8/384 kHz,
- full macOS CI before moving on.

## Phase B — replace the main-EQ compiled representation once

4. bounded compiled multi-section EQ program
5. 6–96 dB/oct slopes
6. Tilt EQ

Do this once instead of layering temporary section-expansion hacks onto the current user-band representation.

## Phase C — channel/phase extensions

7. Mid/Side EQ
8. per-band FIR
9. Mixed Phase EQ

Focused hardware/listening validation becomes mandatory for these structural audio changes.

## Phase D — remaining current stereo spatial parity

10. Symmetry Balance
11. Panning Gain Matrix
12. Crosstalk Cancellation
13. Sub-Bass Phase Alignment
14. resolve/implement the in-scope advanced FIR-IR product mapping

## Phase E — parity re-audit / regression gate

After the blockers above are implemented:

- rerun the legacy behavior ledger against the commercial graph,
- verify no current blocker remains unexplained,
- run deterministic 384-kHz high-rate regression coverage,
- run focused hardware/listening validation on structural audio changes.

Only then does PR34 move to the optimisation phase.

# 8. Performance optimisation gate

Once Phase E passes, establish repeatable baseline profiles at:

- 48 kHz
- 96 kHz
- 192 kHz
- 384 kHz

and for representative/worst-case combinations including:

- 64-band EQ / Dynamic EQ
- high-order slopes
- Linear Phase
- Mixed Phase
- FIR/per-band FIR/global convolution
- denoiser Quality/High/Ultra
- 4x protection
- bass management
- full current stereo processing chain

Only measured hotspots should be changed. Every optimisation must retain sonic/functional acceptance and realtime-safety contracts.

# 9. Gate result

**PR34 source-discovery gate: SATISFIED for the current stereo product.**

**PR34 functional-parity gate: NOT YET SATISFIED.**

**PR34 optimisation gate: CLOSED until the current blocker queue above is retired and re-audited.**

The next production-code slice is **Band Pass parity**.
