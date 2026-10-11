# PR104 — Measurement-Driven Speaker Optimization Engine

Status: **SLICE 1 IMPLEMENTED — EXACT-HEAD CI PENDING**

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

2. **Constrained correction parameterization:** Translate preview envelopes
   into bounded PEQ/FIR candidate parameters, with filter count/Q limits,
   clipping/headroom accounting and explicit crossover/limiter protections.
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
