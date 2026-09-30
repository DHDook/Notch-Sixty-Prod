# PR43 — Advanced Acoustic & Speaker Optimization

Status: **KICKOFF / IMPLEMENTATION IN PROGRESS**

PR43 is stacked on the certified PR42 head and deliberately expands the existing speaker-focused product without broadening Notch Sixty into a headphone or surround/multichannel listening product before 1.0.

## Product boundary

PR43 remains focused on the current two-channel speaker/subwoofer and active-crossover use cases. Existing PR41 physical multi-output routing for Mains+Sub, Bi-Amp, and Tri-Amp systems remains supported because it is part of speaker integration, but PR43 does **not** introduce a surround-channel semantic model, home-theater speaker layouts, headphone-specific DSP, crossfeed, HRTF/spatial-headphone processing, or AutoEQ headphone workflows.

Those broader headphone and multichannel product directions remain explicitly deferred until after 1.0, when they can be designed intentionally rather than appended to the speaker architecture.

## Goals

PR43 promotes the useful post-1.0 acoustic/speaker ideas identified during PR42 into a deliberate pre-1.0 enhancement milestone, while preserving the commercial rewrite's clean-room, realtime-safety, and hardware-safety requirements.

The work is divided into four internal tranches so each layer can be reviewed and validated independently.

### A. Advanced Room Correction design and diagnostics

1. **Automatic low-latency IIR correction fitter**
   - Fit a bounded bank of parametric/shelf filters from the validated PR40 measurement/target data.
   - User-selectable FIR vs IIR correction design; no hidden conversion between the two.
   - Constrain correction range, boost/cut, Q, band count, and residual error.
   - Prefer broad, stable corrections over narrow high-Q overfitting.
   - Preserve the existing minimum-phase FIR path unchanged.

2. **Confidence-gated excess-phase correction**
   - Derive excess-phase candidates only from measurements meeting explicit timing/SNR/coherence/consistency criteria.
   - Never automatically invert non-minimum-phase behavior merely because phase is non-flat.
   - Bound correction latency, correction magnitude, time support, and frequency range.
   - Require an explicit user opt-in and expose predicted/verified effect before deployment.
   - Fall back cleanly to the existing minimum-phase path when confidence is insufficient.

3. **Advanced acoustic diagnostic views**
   - Impulse Response.
   - Step Response.
   - Energy Time Curve / Energy Decay Curve as appropriate to the available measurement data.
   - Group Delay.
   - Existing frequency/phase/quality views remain authoritative inputs rather than being duplicated.
   - Views are analysis-only and demand-gated; they must not add realtime callback work when closed.

### B. Per-driver DSP and telemetry

Add Playback-System-owned processing to the PR41 logical speaker buses without moving physical-system state into Content Presets.

Per logical driver/output bus:

- bounded parametric EQ;
- trim/gain;
- polarity;
- broadband/fractional delay for acoustic-center alignment;
- optional driver-specific limiter/protection;
- peak/RMS/true-peak telemetry where technically meaningful;
- bypass/solo/audition controls designed so they cannot defeat mandatory driver-safe crossover filtering.

Safety rules:

- mandatory topology crossover remains active under Global Bypass;
- no control may accidentally route full-range energy to a split driver;
- fan-out/routing ownership remains PR41's Playback System model;
- no dynamic allocation, locks, logging, UI callbacks, or file access on the realtime render path;
- driver DSP programs are compiled/control-plane objects and swapped through the existing immutable/acknowledged graph pattern.

### C. Measurement-assisted speaker optimization

Use PR40 measurements and PR41 logical speaker buses to assist setup rather than relying on geometry-only prediction.

1. **Driver arrival-time / acoustic-center alignment**
   - Estimate relative arrival timing from captured driver measurements.
   - Propose bounded delay changes; never silently apply them.
   - Show confidence and residual timing error.

2. **Polarity / phase diagnosis**
   - Compare measured crossover-region behavior under candidate polarity/phase states.
   - Recommend only when the evidence is sufficiently strong.
   - Preserve manual override.

3. **Measured acoustic summation view**
   - Overlay individual driver responses with measured combined-system response.
   - Distinguish measured data from any calculated prediction visually and semantically.

4. **Crossover optimization assistant**
   - Search only safe, user-bounded crossover frequencies/topologies already supported by the runtime.
   - Score candidate states from actual measurement objectives such as summed-response smoothness, phase compatibility, excursion/protection constraints where available, and correction burden.
   - Candidate state is always a complete explicit state; do not reproduce the legacy delta-vs-absolute Apply-All ambiguity.
   - Present recommendations and before/after prediction; user must explicitly apply.

5. **Per-driver EQ optimization assistant**
   - Use the new bounded per-driver EQ bank.
   - Penalize narrow/high-gain filters and excessive correction complexity.
   - Never optimize around invalid/low-confidence measurement regions.

6. **Baffle-step / resonance assistants**
   - Detect broad baffle-step-like trends and narrow resonance candidates from measurement evidence.
   - Present these as recommendations with confidence/evidence, not categorical diagnoses.
   - Suggested corrections enter the same explicit candidate/review/apply path as other optimizer output.

7. **Automated verification pass**
   - After applying alignment/crossover/EQ changes, guide the user through a repeat combined-system measurement.
   - Compare measured result against the pre-change baseline and target.
   - Clearly distinguish predicted improvement from verified acoustic improvement.

### D. Portable speaker-system export

Extend the existing PR42 CamillaDSP export only where it can faithfully represent the Notch Sixty speaker processing model:

- logical bus filters;
- per-driver EQ;
- gain;
- polarity;
- delay;
- crossover filters;
- FIR resources where portable;
- deterministic mixer/pipeline ordering.

Machine-specific private Core Audio Aggregate Device identity/routing remains authoritative inside Notch Sixty and is not exported as though it were portable configuration.

## Explicitly out of PR43

- AutoEQ/headphone targets or headphone switching;
- headphone crossfeed/HRTF/spatialization;
- surround/home-theater channel layouts or semantic multichannel mixing;
- Atmos/object-audio processing;
- arbitrary input-channel matrix expansion unrelated to the existing active-crossover speaker buses;
- fixed-bit-depth file export/dither (still dependent on a future app-owned export pipeline);
- recreating audited legacy no-op optimizer toggles or ambiguous Apply-All behavior.

## UX principles

- Measurement-driven automation is advisory first. Recommendations show evidence, confidence, and predicted effect before the user applies them.
- Destructive or driver-risking states are not reachable through Global Bypass, audition, optimizer previews, or routing edits.
- Advanced controls should use progressive disclosure so ordinary stereo + sub users are not forced through an active-speaker engineering workflow.
- Room Correction remains a Playback System concern. Content Presets remain media/voicing state.
- Every automated change must be reversible as one transaction.

## Validation requirements

Each tranche must add deterministic validators/tests before it is considered complete.

At minimum PR43 must finish with:

- numerical unit tests for IIR fitting, delay estimation, group-delay analysis, candidate scoring, and filter constraints;
- regression tests for immutable driver-DSP graph swaps and mandatory crossover safety under Global Bypass;
- realtime allocation/lock guards for all new render-path work;
- persistence round-trip tests for new Playback System state;
- migration/default behavior for pre-PR43 profile archives;
- measurement-quality/confidence tests that prevent low-quality measurements from driving aggressive optimization;
- CPU benchmarks for worst-case per-driver DSP on supported 2–8 physical-route configurations;
- UI guard coverage for diagnostics/optimizer workflow;
- exact-head Debug, Release Performance, XCTest, sandboxed Release app and DMG gates;
- manual real-Mac acoustic acceptance using only safely connected speaker topology/hardware.

## Internal execution order

1. Extend typed Playback System model for per-driver DSP, analysis products, optimizer candidate state, and versioned persistence.
2. Add analysis kernels/views: IR, step, decay, group delay, measured summation.
3. Add per-driver realtime EQ/trim/polarity/delay/protection/metering with mandatory-crossover safety invariants.
4. Add low-latency IIR Room Correction fitter.
5. Add timing/polarity diagnosis and alignment assistant.
6. Add crossover/per-driver-EQ optimization and baffle-step/resonance recommendation layer.
7. Add confidence-gated excess-phase correction after the measurement-confidence machinery is proven.
8. Add repeat-measurement verification workflow.
9. Extend portable CamillaDSP speaker export.
10. Run full software, performance, packaging, and hardware/acoustic acceptance gates.

## Exit criteria

PR43 can close only when:

- all scoped capabilities above are implemented or explicitly removed from PR43 with a documented product decision;
- no optimizer can silently apply a hardware-risking state;
- mandatory driver-safe crossover behavior remains invariant under all bypass/audition/preview modes;
- measurement-driven recommendations carry bounded confidence/quality requirements;
- pre-PR43 profile state migrates safely;
- realtime and CPU budgets remain acceptable;
- exact-head CI/package gates are green;
- real-Mac speaker/acoustic acceptance passes.
