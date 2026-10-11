# PR104 — Measurement-Driven Speaker Optimization Engine

Status: **SLICE 4 IMPLEMENTED — EXACT-HEAD CI PENDING**

Stack: PR102 remote release handoff → PR103 Speaker Optimizer measurement
foundation → **PR104 optimization engine** → PR105 guided apply/verification →
PR106 advanced measurement lab.

## Scope

Build an offline source-by-source optimizer based on *qualified* PR103 repeated
microphone measurements. No generic Room Correction duplication and no unguarded
whole-output bypass of speaker crossovers or per-driver protection.

**Slice 1 — Safe optimization objective and bounded proposal (implemented)**

- Accept only PR103 `baseline` sets whose independently re-evaluated confidence
  says `optimizerReady == true`. Refuse incomplete, changed-route, poor-SNR,
  clipped or incoherent measurements.
- Require every mic position to be represented by a positive finite weight;
  default to equal multi-position weighting.
- Design independently per whole-speaker or subwoofer acoustic source, and
  only within that source's *common usable frequency band*.
- Average repeated measurements at each stationary microphone position and
  derive a spectral objective from the measured broadband reference, avoiding
  amplification based on arbitrary mic gain.
- Apply log-frequency smoothing and bounded magnitude-envelope design.
  Default: cut-only, at most 6 dB; optional boost never more than 3 dB.
- Evaluate modeled error before/after at every included position. Revert any
  proposal that worsens weighted aggregate error or a position beyond the
  bounded per-seat tolerance.
- Produce a `SpeakerOptimizerPreviewPlan`, not executable FIR/PEQ filters,
  and explicitly label modeled improvement **prediction, not verification**.
- No DSP mutation, direct speaker routing, crossover changes, automatic Apply,
  or authorization of protected-driver excitation.

## Next slices

2. **Constrained correction parameterization (PEQ implemented):** Converts freshly
   evaluated qualified baseline measurement sets into preview-only digital RBJ
   peaking-EQ biquads. Fits at most six bands per acoustic source with explicit
   Q and gain limits, full-band peak/headroom audits, out-of-band skirts audit,
   aggregate and per-position regression rejection, and no deployment path.
   FIR is deliberately deferred: it requires a separate verified synthesis and
   latency/deployment safety contract, not relabeling the PEQ result as FIR.
3. **Multi-source integration:** Optimize sub/mains crossover region, timing,
   polarity and source interaction only where real isolated measurements and
   identity are sufficient; do not assume phase-safe summation.
4. **Optimization alternatives:** Rank candidate objectives against response,
   headroom, seat-to-seat consistency and complexity; preserve A/B preview.
5. **PR104 closure:** Full deterministic and macOS regression, clear PR105
   explicit-apply and real-measurement verification handoff.

## Evidence and safety boundary

Synthetic unit tests and macOS CI can verify mathematical determinism, bounds
and fail-closed identity checks. They cannot establish real acoustic benefit,
microphone accuracy, driver safety, or physical crossover preservation.
PR103 continues to block protected Low/Mid/High driver-bus measurement until a
dedicated crossover-preserving measured/safety-qualified path exists.

PR105 owns guided approval, application, rollback, and *new measured* candidate
and verification sets. No PR104 prediction may become measured verification.

## Slice 2 checkpoint

- `SpeakerOptimizerPEQCandidateDesigner` recomputes PR103 readiness and Slice 1 from baseline evidence; it never accepts externally supplied/forged correction envelopes.
- Greedy digital-biquad fitting tests each RBJ response against all included microphone positions, a maximum band count, Q and gain bounds, positive headroom reserve, and frequency skirts beyond the common measured band.
- The resulting candidate contains coefficients, modeled response, and explicit recommended preamp attenuation. This is **preview-only**: nothing loads coefficients into a DSP chain, reconfigures crossovers, or claims measured acoustic verification.
- Protected active-crossover individual-driver measurements remain unavailable. The data is for whole speakers/subs only.
- A preview-only PEQ candidate must not be interpreted as a guarantee of speaker safety under live playback; PR105/physical acceptance remain required.


## Slice 3 — Offline linear-phase FIR candidates

- Independently regenerate Slice 1 from PR103's requalified baseline rather than accepting an external, stale preview curve.
- Construct a Hermitian correction magnitude spectrum, take the inverse Accelerate DFT, window/truncate a centered symmetric odd-length impulse into causal Float taps, then run a **separate forward DFT of the actual taps**.
- Restrict corrections to each source's common usable measurement band, taper at its edges, and audit all Fourier bins (including outside the band).
- Declare exact constant linear-phase group delay (N-1)/2 frames. Default 2049 taps means 1024 frames (~21.33 ms at 48 kHz); configurations above their declared latency budget fail closed.
- Predict weighted residual error from the independently measured positions, enforce position degradation limits, and reject candidates without meaningful modeled improvement.
- Enforce actual synthesized gain/cut bounds, out-of-band leakage, and explicit recommended preamp reserve. Rejected candidates hold **no taps**.
- No live audio-engine modification, no Apply action, no protected-driver sweep, no promise of real acoustic response. This is an alternative **FIR preview**, not a room correction copy, deployable preset, or measurement-based verification.
- Unlike minimum-phase PEQ, a causal symmetric FIR incurs fixed group delay, which matters for video synchronization; PR105 must explicitly coordinate latency before any application.

Next: measured-source multi-channel/subwoofer feasibility, phase/timing boundaries and candidate ranking. Any actual speaker correction requires explicit later commissioning and new microphone verification.


## Slice 4 — Speaker/subwoofer crossover phase and arrival feasibility

- Requires re-qualified PR103 **baseline** evidence and explicit whole-speaker/subwoofer pair. Refuses sub/sub, speaker/speaker, unplanned sources, low-frequency-effects as speaker, unqualified repeats or changed routing/microphone identity.
- For each stationary microphone position and isolated source, interpolates magnitude and circular phase over the shared usable crossover band (default center 80 Hz and one octave). Interpolation refuses undersampled response grids.
- The existing room-measurement analyzer explicitly REMOVES bulk arrival from the stored phase. Reconstructs relative complex transfer by adding the separately recorded direct-arrival delay **exactly once**, rather than summing delay-compensated phases or double-counting timing.
- Compares isolated main and subwoofer complex responses, then explores **hypothetical positive-only** additional delay to either source (default ±8 ms range in 0.25 ms increments) and optional sub polarity inversion. Zero remains the baseline.
- Rejects hypotheses that decrease any listening-position crossover-band energy beyond tolerance or cause excessive estimated coherent sum relative to the strongest isolated source. Provides explicit per-position and aggregate modeled crossover-region changes.
- Does **not** change amplifier crossover frequency, driver filters, bass-management configuration, timing, polarity, or limiter routing.
- **Important measurement-provenance limitation:** PR103 evidence records a common microphone and route but does not separately authenticate cross-source sweep clock origin. Therefore modeled phase-coherent sums, timing and polarity are *conditional feasibility hypotheses*, not certified adjustments. A future provenance and synchronized-capture contract is essential before PR105 could safely apply them.
- Crossover performance/extra relative energy does not equal absolute digital headroom. Explicit limiter and clipping verification is still required.
- These models cannot prove real-room improvements; new physical microphone verification remains mandatory.


## Slice 5 — Offline alternative ranking and visual A/B

- Rebuild **all** correction models from the same requalified PR103 baseline, seat weights, microphone, playback system, sample rate and route; cross-check before-error and frequency-grid agreement before comparing alternatives.
- Every source has three choices: bypass/unity, bounded digital PEQ, and audited linear-phase FIR. Rejected contenders remain visible with reasons, but their correction curves revert to zero and they cannot be selected for visual A/B.
- Rank solely **within** one acoustic source, using modeled RMSE improvement minus explicit headroom, filter-complexity, FIR delay and worst-seat-regression penalties. These are UI preference scores, not verified acoustic sound-quality scores.
- The per-source top choice can remain bypass when correction costs dominate predicted benefit; comparison does not force a filter.
- Provide side-by-side A/B correction curves, an optional per-frequency difference curve, and separate predicted target errors. **No live-audio switching or coefficient loading.**
- The existing cross-source speaker/subwoofer analyzer can be invoked as its own isolated baseline-versus-hypothesis diagnostic: comparison does not mix a coherent-sum energy objective with single-source magnitude-RMSE scores.
- Cross-source phase/sweep reference authentication is absent from the persisted PR103 schema. Diagnostic rankings remain conditional and cannot be applied. Room measurements and user approval remain necessary in PR105.
