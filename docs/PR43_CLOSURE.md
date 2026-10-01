# PR43 — Advanced Acoustic & Speaker Optimization Closure

Status: **SOFTWARE IMPLEMENTATION CLOSURE — REAL-MAC ACOUSTIC ACCEPTANCE PENDING**

PR43 remains stacked on PR42 and preserves the 1.0 speaker-focused product boundary. Headphone-specific workflows and semantic surround/multichannel expansion remain deliberately deferred until after 1.0.

## Shipped in PR43

### Advanced measurement diagnostics

- Impulse Response, aligned to measured direct arrival.
- Step Response.
- Energy Time Curve (ETC).
- reverse-integrated Energy Decay Curve (EDC).
- Group Delay derived from the measured unwrapped transfer-function phase.
- analysis is offline/demand-gated and adds no realtime callback work.

### Per-driver speaker processing

Playback-System-owned processing on the PR41 logical speaker buses:

- bounded per-driver PEQ/shelf/notch/all-pass EQ;
- trim/gain;
- polarity inversion;
- broadband + fractional delay;
- optional per-driver limiter/protection;
- production Active Crossover editor with progressive disclosure;
- version-safe persistence in Playback System Profiles;
- immutable control-plane compilation and fixed-size realtime runtime.

The mandatory crossover/speaker-bus splitter always executes before optional driver processing, so Global Bypass or driver-processing bypass cannot restore unsafe full-range signal to a protected split-driver bus.

### Existing Room Correction foundation retained

The PR40 bounded minimum-phase FIR designer remains the authoritative automatic correction path in this PR43 close. PR43's advanced diagnostics make the retained raw measurement assets substantially more inspectable without changing daily DSP unexpectedly.

## Explicitly removed from PR43 before closure

The kickoff scope intentionally listed several measurement-assisted optimizers as candidates. They are **not shipped or claimed** in PR43 because the current calibration transport does not yet collect the evidence needed to support them safely and honestly.

The current measurement session captures sequential whole-system Left and Right sweeps while ordinary DSP playback is idle. It does **not** currently provide:

- isolated Low/Mid/High/Sub logical-bus acoustic captures;
- repeatability/coherence statistics across controlled repeated sweeps;
- a measurement path through a candidate/deployed per-driver processing graph;
- processed-vs-baseline verification under identical routing conditions.

Therefore the following are deferred to a dedicated post-1.0 measurement/optimization milestone rather than implemented with guessed or geometry-only evidence:

- automatic driver arrival-time/acoustic-center alignment;
- automatic polarity/phase diagnosis;
- measured individual-driver vs combined-system summation;
- automatic crossover-frequency optimization;
- automatic per-driver EQ optimization;
- baffle-step and diaphragm-resonance recommendation assistants;
- automatic processed-path repeat-measurement verification;
- automatic measurement-derived excess-phase inversion.

A future optimizer must first add a driver-safe isolated-bus/processed-path calibration transport and a confidence model based on repeatability, SNR, timing stability, and appropriate coherence/consistency evidence. Recommendations must remain advisory, complete-state, reversible, and explicitly applied.

## Also deferred

- automatic low-latency IIR Room Correction fitting: the commercial graph intentionally keeps Content-Preset EQ separate from the dedicated Playback-System Room Correction lane. Shipping an automatic IIR fitter now would either hide system filters inside the content EQ bank or require a new system-IIR render lane immediately before 1.0. PR43 preserves the bounded minimum-phase FIR correction path and defers system-owned automatic IIR until that lane can be designed, persisted, bypassed, and verified explicitly;
- per-driver realtime meter UI: the PR43 driver runtime is deliberately bounded and safe, but adding independent bus telemetry requires a separately demand-gated bridge/transport design so it does not impose unconditional realtime work;
- richer portable CamillaDSP physical speaker-matrix export: PR42's deterministic Content-EQ/FIR export remains available. A speaker-system exporter should follow only when its logical-bus/crossover semantics can be represented faithfully without implying that private Core Audio Aggregate Device identities are portable;
- fixed-bit-depth export/dither: still depends on a future app-owned file/export boundary.

## Product boundary

PR43 does not add headphone switching, AutoEQ/headphone target workflows, headphone crossfeed/HRTF/spatialization, surround/home-theater semantic channel layouts, Atmos/object audio, or arbitrary multichannel mixing. PR41's 2–8 physical outputs remain speaker-integration buses for Mains+Sub, Bi-Amp, and Tri-Amp systems.

## Acceptance before merge

Software closure still requires exact-head validators, Debug/Release builds, XCTest, realtime benchmarks, sandbox validation, and DMG packaging. Keep PR43 draft until a real Mac safely verifies:

- ordinary stereo and Mains+Sub playback;
- any available Bi-Amp/Tri-Amp topology only with safely connected hardware;
- per-driver EQ/trim/polarity/delay/limiter edits while idle and persistence after relaunch;
- mandatory crossover safety under Global Bypass and driver-processing neutral/bypass state;
- no channel swaps, clicks, level jumps, unexpected latency, or instability;
- advanced acoustic diagnostic presentation against a real microphone measurement.

The expected stacked merge order remains PR40 -> PR41 -> PR42 -> PR43 after the combined acceptance pass.
