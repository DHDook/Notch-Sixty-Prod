# PR34 Legacy Dynamics Contract Audit — Source-Level Continuation

Status: **SOURCE AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This document records source-level behavioral findings that resolve or refine items in the PR34 parity ledger. Legacy code is used only as evidence of reachable product behavior, public state, defaults, parameter ranges, and observable semantics. Historical DSP implementation expression is not used as an implementation template.

## 1. Hardware Sync Buffer — confirmed legacy no-op

### Legacy evidence

`AdvancedProcessingConfig.hardwareSyncBufferEnabled` is persisted and exposed to the product surface.

In `DynamicsProcessor`, the corresponding private atomic `_syncBufferEnabled` has only three roles:

1. declaration,
2. initialization to disabled,
3. write through `setHardwareSyncBufferEnabled(_:)`.

No render-path or other runtime read of the private atomic exists.

### Disposition

**LEGACY-DEAD / NO-AUDIO-EFFECT.**

The commercial product does not need to reproduce this switch for functional parity. If historical state is imported later, the field may be ignored as a no-op compatibility field.

---

## 2. Latency Mode: Music / Movie — confirmed legacy no-op

### Legacy evidence

The legacy product persists and exposes `LatencyMode.music` / `LatencyMode.movie`.

In `DynamicsProcessor`, the corresponding private atomic `_latencyModeBits` has only three roles:

1. declaration,
2. initialization to `.music`,
3. write through `setLatencyMode(_:)`.

No render-path or other runtime read of the private atomic exists.

### Disposition

**LEGACY-DEAD / NO-AUDIO-EFFECT.**

The commercial product does not need a Music/Movie latency selector merely for parity. Actual commercial latency behavior remains governed by the explicit graph-latency and audition-alignment contracts.

---

## 3. Pause Gate semantics — intentional commercial correction

### Legacy observable contract

The legacy stored values and processor behavior use:

- `pauseGateAttackMs` = opening / resume / fade-in speed,
- `pauseGateReleaseMs` = closing / fade-out speed.

Legacy defaults are:

- threshold: -60 dBFS,
- hold: 500 ms,
- Attack: 10 ms,
- Release: 200 ms,
- hysteresis: 3 dB.

The legacy render path confirms that the Attack coefficient is selected when gain is increasing toward unity and the Release coefficient is selected when gain is decreasing toward zero.

### Commercial contract

The commercial rewrite deliberately uses the product convention approved during the rewrite:

- **Attack = close / fade-out**,
- **Release = open / fade-in**.

The current commercial defaults retain the same visible numeric defaults:

- threshold: -60 dBFS,
- hold: 500 ms,
- Attack: 10 ms,
- Release: 200 ms,
- hysteresis: 3 dB.

The C runtime explicitly applies the Attack coefficient while the gate is fading out and Release while it is fading in.

### Disposition

**IMPLEMENTED / IMPROVED — deliberate semantic correction.**

This is not a missing processor capability. The commercial naming is intentionally clearer and matches the established Notch Sixty product requirement.

### Persistence / migration requirement

Legacy-state import must translate the time constants to preserve audible behavior:

- legacy `Attack` (open/fade-in) -> commercial `Release`,
- legacy `Release` (close/fade-out) -> commercial `Attack`.

A migration test should explicitly guard this mapping when legacy preset/state import is implemented.

---

# 4. Parameter/default audit of rebuilt dynamics

The following comparison distinguishes **functional parity** from **fresh-install default tuning**. A commercial processor can satisfy parity when it supports the legacy observable parameter space even if the new product intentionally ships with a safer or better default. Legacy preset/state migration must preserve explicit stored values regardless of the new-product defaults.

## Compressor

### Legacy defaults

- enabled: false
- threshold: -16 dB
- ratio: 3.5:1
- Attack: 25 ms
- Release: 150 ms
- makeup gain: **+2.5 dB**
- knee: 6 dB
- program-dependent release: false
- sidechain HPF: 0 Hz / disabled
- topology: Feed-Forward

### Commercial defaults

- enabled: false
- threshold: -16 dB
- ratio: 3.5:1
- Attack: 25 ms
- Release: 150 ms
- makeup gain: **0 dB**
- knee: 6 dB
- program-dependent release: false
- sidechain HPF: 0 Hz / disabled
- topology: Feed-Forward

### Disposition

**IMPLEMENTED / IMPROVED, with explicit fresh-default divergence.**

The processor/control model includes the legacy capability, including makeup gain. The commercial rewrite intentionally avoids a hidden +2.5 dB level increase at the default setting. Legacy state import must retain an explicitly stored +2.5 dB value.

## Expander

### Legacy defaults

- enabled: false
- threshold: -35 dB
- ratio: 1.5:1
- range: -12 dB
- Attack: 5 ms
- Release: 200 ms

### Commercial defaults

The commercial Expander matches these defaults and exposes a wider validated operating range.

### Disposition

**IMPLEMENTED / IMPROVED.**

## De-Esser

### Legacy defaults

- enabled: false
- frequency: 6.0 kHz
- threshold: -20 dB
- ratio: 10:1
- range: -12 dB
- detection Q: 2.0
- Attack: 1 ms
- Release: 50 ms
- Dynamic-EQ mode: false in the surrounding advanced-processing state

### Commercial defaults

- enabled: false
- frequency: 6.5 kHz
- threshold: -24 dB
- ratio: 4:1
- range: -24 dB
- detection Q: 2.0
- Attack: 1 ms
- Release: 50 ms
- Dynamic-EQ mode: true

The commercial parameter ranges include the legacy frequency, threshold, ratio, range, Q, and timing values.

### Disposition

**IMPLEMENTED / IMPROVED at processor-capability level; fresh-default retune explicitly recorded.**

The commercial rewrite has a materially different initial tuning, but legacy settings remain representable. Persistence migration must import stored legacy values rather than substituting commercial defaults.

## Three-band Multiband Compressor

### Legacy defaults

- crossovers: 150 Hz / 3.0 kHz
- slopes: gentle / gentle
- thresholds: 0 / 0 / 0 dB
- ratios: 4 / 4 / 4
- Attack: 40 / 20 / 10 ms
- Release: 200 / 100 / 50 ms
- knee: 6 / 6 / 6 dB
- sidechain HPF: 0 / 0 / 0 Hz
- makeup: 0 / 0 / 0 dB

### Commercial defaults

- crossovers: 120 Hz / 3.5 kHz
- slopes: gentle / gentle
- thresholds: -18 / -18 / -18 dB
- ratios: 3 / 3 / 3
- Attack: 10 / 10 / 10 ms
- Release: 150 / 150 / 150 ms
- knee: 6 / 6 / 6 dB
- sidechain HPF: 0 / 0 / 0 Hz
- makeup: 0 / 0 / 0 dB

The commercial control model retains independent crossover slopes and per-band threshold, ratio, Attack, Release, knee, sidechain HPF, and makeup controls. Its supported ranges contain the legacy values audited above.

### Disposition

**IMPLEMENTED / IMPROVED at processor-capability level; fresh-default retune explicitly recorded.**

The default voicing is not a parity blocker because the historical values remain representable. Legacy preset/state import must restore the explicit legacy values.

## Soft Clipper

### Legacy defaults

- enabled: false
- drive: 0 dB
- threshold: -1.5 dBFS
- knee smooth: 0.5
- curve: Quadratic
- automatic gain compensation: true

### Commercial defaults

The commercial Soft Clipper retains those defaults and adds the PR33 asymmetry trim at neutral 0 dB.

### Disposition

**IMPLEMENTED / IMPROVED.**

## Look-ahead / Brickwall Limiter

### Legacy defaults

- **enabled: true**
- ceiling: -0.2 dB
- Attack: 0.1 ms
- Release: 20 ms
- look-ahead: 2 ms

### Commercial defaults

- **enabled: false**
- ceiling: -0.2 dB
- Attack: 0.1 ms
- Release: 20 ms
- look-ahead: 2 ms
- True-Peak Guard: true

The commercial source explicitly documents the disabled-by-default decision: the rewrite does not introduce hidden limiting at first launch; presets/users opt in deliberately.

### Disposition

**IMPLEMENTED / IMPROVED, with intentional fresh-default safety change.**

Legacy state/preset import must preserve the stored limiter-enabled state. New commercial state remains disabled by default.

---

# 5. Migration implications captured for the later persistence milestone

The source audit now establishes these concrete migration rules:

1. Ignore legacy Hardware Sync Buffer as a no-audio-effect compatibility field.
2. Ignore legacy Music/Movie Latency Mode as a no-audio-effect compatibility field.
3. Swap legacy Pause Gate Attack/Release fields into the commercial semantic convention so the audible open/close times remain unchanged.
4. Preserve explicitly stored legacy compressor makeup, De-Esser parameters/mode, multiband parameters, and limiter enabled state rather than replacing them with commercial fresh-install defaults.
5. Keep the commercial fresh defaults independent from legacy migration; parity does not require recreating weaker or less transparent first-launch defaults when all legacy settings remain representable.

---

# 6. Effect on PR34 blocker ledger

These findings remove two pending items from parity debt:

- Hardware Sync Buffer -> **LEGACY-DEAD / NO-AUDIO-EFFECT**.
- Music/Movie Latency Mode -> **LEGACY-DEAD / NO-AUDIO-EFFECT**.

They also refine existing dynamics parity:

- Pause Gate -> **IMPLEMENTED / IMPROVED**, with explicit migration mapping.
- Compressor / Expander / De-Esser / Multiband / Soft Clipper / Limiter -> processor capability remains **IMPLEMENTED / IMPROVED**; default divergences above are now documented rather than left ambiguous.

No realtime/DSP code is changed by this audit slice. The optimization phase remains gated behind completion of the broader source-level parity inventory and disposition of the unresolved core-EQ/spatial blockers in the living ledger.
