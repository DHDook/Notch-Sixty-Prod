# PR33 — Residual Dynamics Parity and Gain Protection

## Purpose

PR33 closes the residual dynamics / conditioning / protection obligations identified by the PR32 parity audit before the bounded DSP optimization/enhancement milestone.

The commercial architecture remains unchanged:
- Swift product/control plane
- portable C realtime DSP data plane
- immutable/precomputed snapshots
- fixed/preallocated realtime state
- no render-callback allocation/free, locks, logging, file/device/UI access, or coefficient/filter design
- Processed / latency-matched Reference / Delta semantics preserved
- Global Bypass remains the true raw escape path

## Clean-room boundary

Historical Notch Sixty implementation source and tests are not implementation templates. Legacy configuration/UI/state may be inspected only to establish externally observable controls, defaults, ranges, modes, and intended behavior. PR33 algorithms, realtime state, tests, and graph integration are independently authored from public DSP mathematics/literature and the proprietary commercial architecture.

Explicitly excluded as coding references include historical `DynamicsProcessor.swift`, `PerBandLoudnessCompensator.swift`, `EQHeadroomCompensator.swift`, and historical DSP tests.

## Required PR33 scope

PR32 assigned these remaining required items to PR33:
1. General-purpose Dynamic EQ
2. Dynamic Gain Rider / auto-headroom
3. Explicit True-Peak Guard semantics
4. Clipper asymmetry trim
5. Per-band loudness compensation
6. De-Harsh tilt filter
7. EQ / DSP automatic-headroom compensation

Routing-, room-correction-, and output-format-dependent obligations remain attached to their explicit later milestones and are not silently claimed as PR33 parity.

## Slice 1 — General-purpose Dynamic EQ

Dynamic EQ is a first-class processor rather than an extension of the De-Esser.

### Verified observable legacy contract

Configuration/state inventory establishes:
- global enable
- up to 16 bands
- per-band bypass
- frequency: 20–20,000 Hz
- Q: 0.4–8.0
- static gain: −18…+6 dB
- cut threshold: −60…0 dBFS
- cut ratio: 1:1…10:1
- attack: 1…100 ms
- release: 10…1000 ms
- dynamic cut range, default −24 dB
- direction: Cut Only / Boost Only / Both
- boost threshold, default −40 dBFS
- boost ratio, default 2:1
- maximum boost, default +6 dB
- detector mode: Peak / RMS
- RMS detector window, default 50 ms, observable range 5…200 ms

The legacy state default direction is Cut Only and default detector mode is Peak. The historical state exposed up to 16 Dynamic EQ bands. The commercial product deliberately improves this: Dynamic is a capability of the normal EQ-band model and may be enabled on any supported linked minimum-phase Peak band, up to the commercial 64-band EQ capacity. The standalone `N60DynamicEQ` engine remains an internal realtime implementation detail.

### Commercial implementation contract

- independently authored portable C realtime processor
- Swift configuration / validation / immutable snapshot publication
- maximum 64 fixed/preallocated band runtimes, matching the commercial main-EQ capacity
- linked-stereo detector decisions unless a verified observable contract requires otherwise
- precomputed filter coefficients only; no realtime coefficient design
- zero intentional algorithmic look-ahead latency
- bounded dynamic gain per band
- click-safe enable/bypass/parameter changes
- explicit detector / current dynamic-gain telemetry for validation
- finite behavior through 384 kHz where the band frequency remains below Nyquist
- no unexplained broadband level shift

### Detector semantics

Peak and RMS are product-visible detector choices. The commercial RMS implementation may use an independently authored bounded power-envelope time constant corresponding to the user-visible RMS window rather than reproducing a historical implementation structure. The observable time-scale/control remains the contract.

### Acceptance tests

At minimum:
- disabled processor is transparent
- enabled processor with zero bands is transparent
- bypassed band is transparent
- neutral/no-dynamic operating point is bounded and deterministic
- Cut Only attenuates an in-band over-threshold signal while leaving an out-of-band signal substantially unaffected
- Boost Only raises eligible low-level in-band material but never exceeds Max Boost
- Both direction exercises both branches without sign inversion or runaway feedback
- dynamic cut never exceeds configured range
- Peak vs RMS detector modes produce measurably different transient behavior
- longer RMS windows respond more slowly than shorter windows
- attack/release behavior is monotonic
- linked-stereo image/ratio remains stable
- 64-dynamic-band worst case remains finite through supported high sample rates
- live snapshot changes remain finite/click-bounded
- no regression to PR25–32 audition/bypass behavior

## Slice 2 — coherent gain / protection integration

These controls are implemented together so Notch Sixty has one understandable gain/protection ownership model rather than several hidden attenuators.

### Dynamic Gain Rider / auto-headroom
Observable contract:
- target sustained limiter gain reduction
- maximum cut
- Fast / Medium / Slow response

Commercial goal:
- react to sustained protection stress, not isolated peaks
- slowly reduce upstream level before chronic limiting becomes audible
- bounded attenuation
- no pumping
- explicit current-rider attenuation telemetry

### True-Peak Guard
The commercial engine already has true-peak detection and oversampled protection. PR33 must close the separate observable TP Guard mode semantics without adding a redundant limiter/protection chain.

### Clipper asymmetry trim
Observable contract:
- independent ±3 dB asymmetry trim
- separate from choosing an asymmetric clipper curve

Commercial requirements:
- bounded behavior
- preserve oversampling/unity contracts
- no DC instability or unexplained broadband gain shift

### EQ / DSP automatic-headroom compensation
Observable contract:
- enable
- maximum attenuation

This must be explicitly reconciled with:
- input preamp
- headroom stage
- static EQ boost
- Dynamic EQ
- dynamics processors
- limiter / true-peak protection
- Dynamic Gain Rider

No multiple invisible gain reducers with unclear ownership.

## Slice 3 — perceptual conditioning parity

### Per-band loudness compensation
The verified legacy obligation is broader than the current volume-aware contour. PR33 will inventory and close the observable bass/treble compensation policy, reference listening-level behavior, boost/cut limits, and level-source policy while deliberately avoiding two overlapping loudness systems.

### De-Harsh
Observable product description: a configurable high-frequency tilt/attenuation intended to reduce harshness/tweeter fatigue above the upper-mid / treble region (nominal legacy description around 3.5 kHz).

Commercial implementation should be a simple transparent conditioning stage with:
- explicit enable
- configurable turnover frequency
- configurable attenuation/tilt amount
- deterministic frequency-response tests
- zero added algorithmic latency

## Validation UI

PR33 continues to use engineering validation surfaces. Production visual design remains later. Every new processor/control must be reachable and its essential telemetry visible before the hardware gate.

## Provenance

`docs/PROVENANCE.md` must receive explicit PR33 entries before hardware acceptance. Legacy DSP implementation source/tests are excluded from coding references.

## Exit gate

PR33 is complete only when:
- all three slices are implemented or explicitly dispositioned with no silent omission
- full Xcode suite is green
- deterministic high-rate coverage is green
- provenance is updated
- validation UI is complete
- focused exact-head hardware/listening validation passes
- no PR25–32 regression is introduced
- Processed / Reference / Delta and raw Global Bypass semantics remain intact

Only after PR33 hardware acceptance and merge does the roadmap advance to the bounded DSP optimization/enhancement pass.

## Slice 2 commercial semantics

The gain/protection controls share a single ownership model:

- **Predictive EQ/DSP headroom** is a control-plane pre-EQ attenuation. It is capped by the visible 3–24 dB maximum and is never applied during raw Global Bypass. The validation implementation is deliberately disabled by default so PR25–32 accepted listening baselines are not silently changed.
- **Dynamic Gain Rider** is a slow pre-protection attenuation driven only by sustained limiter gain reduction. Target GR is 0.5–6 dB, maximum rider cut is 3–12 dB, and Fast/Medium/Slow correspond to approximately 3/10/30 second response constants. It does not chase isolated transient peaks.
- **TP Guard** is an explicit limiter reconstruction-quality mode. ON preserves the accepted PR27 4x true-peak reconstruction path; OFF lets the limiter use the selected 1x/2x/4x protection factor instead of silently forcing 4x.
- **Clipper Asymmetry Trim** is an independent ±3 dB half-cycle drive trim around the existing clipper curve. Zero is sample-identical to the established clipper behavior.

No new limiter or duplicate hidden master-gain stage is introduced.


## Slice 3 commercial semantics

### Per-band loudness compensation
The commercial implementation supersedes the shallow PR29 volume-aware contour while retaining its useful anchor points and the old C setter for compatibility. The advanced Swift path exposes the legacy observable controls: reference phons (60–95), maximum boost (6–20 dB), maximum cut (0–6 dB), and System Volume / Integrated level source.

The implementation is independently authored and does not claim calibrated SPL. In System Volume mode, master −6 dB is the configured reference-phons point and master −30 dB is 24 phons below reference. With the default response slopes this reproduces PR29's accepted +6 dB bass / +3 dB treble low-volume anchor. Integrated mode maps −16 LUFS to the configured reference-phons point. Low and high bands use fixed, precomputed filters with dynamically smoothed gains, so no coefficients are designed in the callback.

### De-Harsh
De-Harsh is an independently authored RBJ-style high-shelf conditioning stage. Observable contract: enable, amount −6…0 dB (default −1.5 dB), frequency 1.5–10 kHz (default 3.5 kHz). Coefficients are designed on the control plane, runtime state is fixed/preallocated, enable transitions are smoothed, and algorithmic latency is zero.
