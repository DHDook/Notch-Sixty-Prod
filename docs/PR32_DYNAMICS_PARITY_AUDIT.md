# PR32 Dynamics Parity Audit

## Purpose

This is the explicit closure ledger for the legacy Notch Sixty dynamics-related surface. The historical product exposed roughly thirty named dynamics/conditioning/protection capabilities; the number is a capability inventory, not a count of independent sliders.

A PR32 exit condition is that no observable legacy dynamics capability is left unexplained. A capability may be implemented now, improved/superseded by the commercial architecture, or assigned to a named later milestone. A later assignment remains a parity obligation; it is not considered finished merely because it is classified.

Legacy configuration and UI are behavioral inventory only. Historical DSP implementation and tests are not implementation references.

## Status vocabulary

- **PARITY** — commercial implementation covers the observable capability.
- **IMPROVED** — commercial implementation covers and deliberately strengthens the observable capability.
- **PR32** — implemented in PR32 and awaiting PR32 hardware acceptance.
- **PR33** — required residual dynamics/advanced-DSP work to be implemented in the immediately following parity PR before the optimization pass.
- **LATER — ROUTING / ROOM** — required behavior depends on a later physical-routing or room-correction milestone.
- **LATER — OUTPUT / HARDENING** — output-format or product-hardening behavior, not part of the realtime dynamics closure.
- **OUT OF PRODUCT SCOPE** — behavior conflicts with an explicit current product directive and is not part of the commercial feature set.

## Capability ledger

| # | Observable capability | Commercial disposition | Evidence / note |
|---:|---|---|---|
| 1 | Wideband compressor core | PARITY — PR26 | Linked-stereo threshold/ratio/knee/attack/release/makeup processor. |
| 2 | Compressor feed-forward / feed-back topology | PR32 | Slice 1 adds explicit detector topology while retaining the accepted feed-forward default. |
| 3 | Compressor program-dependent release | PR32 | Slice 1 adds bounded release-time adaptation using precomputed coefficients. |
| 4 | Compressor sidechain high-pass | PR32 | Slice 1 adds detector-only HPF; program audio is not filtered. |
| 5 | Downward expander | PARITY — PR26 | Linked-stereo threshold/ratio/range/attack/release. |
| 6 | Dynamic Pause Gate | PARITY — PR26 | Threshold, Hold, hysteresis, Attack = fade-out, Release = fade-in. |
| 7 | Pause Gate named operating points | SUPERSEDED BY PRODUCTION PRESETS MILESTONE | DSP parameter surface is present; named factory/user presentation belongs in the later preset system rather than the validation UI. |
| 8 | Soft clipper core | PARITY — PR27 | Oversampled nonlinear protection stage. |
| 9 | Clipper curve families | PARITY — PR27 | Quadratic, cubic, sine, and asymmetric-tube style curves are represented in the commercial protection configuration. |
| 10 | Clipper automatic level compensation | PARITY — PR27 | Explicit auto-compensate control is present. |
| 11 | Clipper phase/asymmetry trim | PR33 | Legacy exposes an independent ±3 dB asymmetry trim; current asymmetric curve does not fully replace that observable control. |
| 12 | Look-ahead / brickwall limiter | PARITY — PR27 | Linked-stereo limiter with explicit look-ahead and graph latency. |
| 13 | True-peak detector / telemetry | IMPROVED — PR27 | Commercial oversampled true-peak infrastructure participates in protection and telemetry. |
| 14 | Explicit True-Peak Guard mode | PR33 | Legacy exposes a distinct TP Guard toggle. Current true-peak infrastructure exists, but the separate mode semantics require explicit closure rather than silent equivalence. |
| 15 | 1× / 2× / 4× oversampling | IMPROVED — PR27 | Explicit unity-gain regression tests prevent the historical 4× attenuation failure. |
| 16 | De-Esser core | PARITY — PR28 | Frequency-selective linked-stereo dynamics. |
| 17 | De-Esser Dynamic-EQ mode | PARITY — PR28 | Selective attenuation mode retained. |
| 18 | De-Esser ratio / range / Q / attack / release | PR32 | Slice 1 exposes the previously hard-coded control depth. |
| 19 | Three-band multiband compressor core | PARITY — PR28 | Linked-stereo Low/Mid/High processing with transparent residual-mid reconstruction. |
| 20 | Multiband independent crossover slopes | PR32 | Slice 1 permits independent Low/Mid and Mid/High LR4/LR8 choices. |
| 21 | Multiband per-band ratio / timing / knee | PR32 | Slice 1 adds independent ratio, attack, release, and knee. |
| 22 | Multiband per-band sidechain HPF / makeup | PR32 | Slice 1 adds detector-only HPF and makeup per band. |
| 23 | LUFS loudness match | PARITY / IMPROVED — PR29 | Bounded, smoothed K-weighted loudness rider. Exact standards-certification semantics remain a separate validation question rather than a missing control. |
| 24 | Loudness Dialogue Gate | PARITY — PR29 | Optional low-level/dialogue gate prevents silence/noise-floor pumping in the loudness matcher. |
| 25 | Volume-aware loudness contour | IMPROVED — PR29 | PR28 static contour was upgraded to automatically back off as master level rises. |
| 26 | Per-band loudness compensation | PR33 | Legacy exposes independent bass/treble compensation policy including reference phons, boost/cut limits, and level source. Current contour does not fully cover this contract. |
| 27 | Dynamic Gain Rider / auto-headroom | PR33 | Legacy exposes target sustained limiter GR, max cut, and Fast/Medium/Slow response. Required before the optimization pass. |
| 28 | General-purpose Dynamic EQ | PR33 | Substantial independent processor: up to 16 bands with cut/boost direction, threshold/ratio/range, attack/release, Peak/RMS detector and RMS window. Too large to hide inside PR32. |
| 29 | Dialogue-Relative Leveler | PR32 | Slice 2 independently implements masking-gap-based dialogue-band rescue, bounded boost, program gate, and optional voice-confidence modulation gate. |
| 30 | Stereo / Wide Mono / True Mono | PARITY — PR29 | Deterministic fold-down modes. |
| 31 | Three-band stereo widener | PARITY / IMPROVED — PR29 | Linked M/S width processing with conservative commercial defaults. |
| 32 | DC-offset filter | PARITY — PR28 | Optional 0.5 Hz conditioning stage. |
| 33 | Infrasonic main-chain filter | PARITY — PR28 | 24/48/96 dB/oct main-chain protection. |
| 34 | Infrasonic sub-only / both targets | LATER — ROUTING | Requires an independently routable physical sub path; current stereo physical route cannot honestly provide the legacy semantics. |
| 35 | De-Harsh tilt filter | PR33 | Legacy exposes an independent high-frequency tilt control around a configurable frequency. Required residual advanced-DSP parity. |
| 36 | EQ / DSP automatic headroom compensation | PR33 | Legacy exposes enable + maximum attenuation. Must be reconciled with the commercial gain/protection architecture explicitly. |
| 37 | Spectral denoising | IMPROVED — PR31 | Independently authored WOLA/Wiener-style linked-stereo denoiser with profile capture; hardware accepted as notably transparent. |
| 38 | Mains-hum notch / detection / tracking | IMPROVED — PR31 | Harmonic notch, one-shot detect, confidence telemetry, continuous tracking and click-safe retune. |
| 39 | All-pass / signed fractional timing utilities | PARITY / IMPROVED — PR30 | Phase-only EQ plus signed fractional inter-channel alignment. |
| 40 | Independent sub/driver timing and phase alignment | LATER — ROUTING / ROOM | Requires meaningful separate physical paths and/or phase-resolved measurement data. |
| 41 | Excess/mixed-phase correction | LATER — ROOM | Requires phase-resolved measurement and belongs in room correction. |
| 42 | Dither modes | LATER — OUTPUT / HARDENING | Output-format concern rather than dynamics; retain as a later parity/output-stage obligation if still applicable to final device format. |
| 43 | Crosstalk / headphone-style spatial processing | OUT OF PRODUCT SCOPE where headphone-only | Current product directive excludes headphone-only features. Speaker-relevant balance/alignment behavior is handled separately. |

## PR32 conclusion

PR32 closes the **unexplained** dynamics inventory: every identified legacy capability now has an explicit disposition. It does **not** claim that all dynamics parity work is finished, because the ledger deliberately carries the following required items into PR33:

- general-purpose Dynamic EQ
- Dynamic Gain Rider / auto-headroom
- explicit True-Peak Guard semantics
- clipper asymmetry trim
- per-band loudness compensation
- De-Harsh tilt filter
- EQ/DSP automatic-headroom compensation

PR33 must close those residual items before the bounded DSP optimization/enhancement pass begins. Routing- and room-dependent items remain attached to their already-defined later milestones.
