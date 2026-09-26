# PR32 — Dynamics Parity Closure

## Purpose

PR32 closes the remaining legacy dynamics-control and dialogue-processing surface before the dedicated DSP optimization/enhancement pass and production UI work.

The commercial engine keeps the established architecture:
- Swift product/control plane
- portable C realtime DSP
- immutable/precomputed snapshots
- fixed/preallocated runtime state
- no render-callback allocation/free, locks, logging, file/device/UI access, or coefficient construction
- Processed / latency-matched Reference / Delta semantics preserved
- Global Bypass remains the raw escape path

## Clean-room boundary

Historical Notch Sixty implementation source is not an implementation template. Legacy configuration and user-facing UI/state may be inspected only to establish externally observable controls, defaults, ranges, modes, and intended behavior. Production algorithms, realtime state, tests, and graph integration are independently authored from public DSP mathematics/literature and the proprietary commercial architecture.

## Verified observable gaps after PR31

The current commercial engine already includes compressor, expander, Pause Gate, soft clipping, look-ahead limiting, true-peak/oversampling, De-Esser, three-band multiband compression, loudness matching, loudness contour, stereo-format modes, widener, hum suppression, and spectral denoising.

The remaining verified dynamics-control gaps include:

### Wideband compressor depth
- feed-forward / feed-back detector topology
- program-dependent release
- sidechain high-pass filtering

### De-Esser control depth
- ratio
- maximum attenuation/range
- detector Q
- attack / release
- retain Dynamic-EQ mode

### Multiband compressor control depth
- independent Low/Mid and Mid/High crossover slopes
- per-band ratio
- per-band attack / release
- per-band knee width
- per-band sidechain high-pass
- per-band makeup gain

### Dialogue-relative leveler
- dialogue-band low/high limits
- target program/dialogue gap
- correction ratio and maximum boost
- detector window
- attack / release
- program gate
- optional voice-activity confidence gate based on speech-like modulation behavior

Additional small legacy dynamics/protection controls will be classified during this PR before parity closure; they must be implemented, explicitly superseded, or deliberately deferred to the correct later milestone rather than silently omitted.

## Planned slices

### Slice 1 — detector/control-depth parity
Extend the existing proprietary compressor, De-Esser, and multiband processors without replacing their validated cores:
- compressor topology, program-dependent release, sidechain HPF
- De-Esser ratio/range/Q/attack/release
- multiband per-band ratio/time/knee/sidechain/makeup and independent crossover slopes

Acceptance:
- existing default configurations remain behavior-compatible
- disabled/new-neutral controls preserve current output
- sidechain filtering changes detector behavior without filtering program audio
- feed-back compressor mode is stable and bounded
- per-band controls remain linked-stereo and recombination remains transparent at unity gain reduction
- deterministic tests through 384 kHz where applicable

### Slice 2 — dialogue-relative leveler
Add an independently authored dialogue intelligibility processor and optional voice-activity confidence gate.

Acceptance:
- no correction below the program gate
- bounded correction never exceeds configured maximum boost
- correction responds to relative program/dialogue masking rather than raw dialogue-band level alone
- voice gate reduces correction for sustained/non-speech-like modulation while retaining a configurable confidence floor
- linked-stereo gain preserves image
- no audible pumping/clicking during mode or parameter transitions

### Slice 3 — residual dynamics parity audit
Inventory the remaining observable dynamics/protection controls after Slices 1–2 and close each as PARITY, IMPROVED, SUPERSEDED, DEFERRED TO AN EXPLICIT LATER MILESTONE, or BLOCKED. No silent omissions.

This slice also determines whether a general-purpose Dynamic EQ belongs in PR32 or is better treated as a distinct advanced-DSP processor immediately after PR32. The decision must be based on the verified legacy contract and implementation risk, not convenience.

## Validation UI

PR32 keeps using engineering validation surfaces. New controls and telemetry must be reachable before hardware acceptance; production visual design remains later.

## Exit gate

PR32 is complete only when:
- all implemented slices have deterministic regression coverage
- no PR26–31 regression is introduced
- full Xcode suite is green
- provenance documentation is updated
- focused hardware/listening validation passes
- the remaining dynamics inventory has no unexplained item

After PR32, the roadmap moves to a bounded DSP optimization/enhancement pass before full analysis/RTA and production UI expansion.