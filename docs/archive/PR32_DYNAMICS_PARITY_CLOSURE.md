# PR32 — Dynamics Parity Closure

## Purpose

PR32 closes the remaining legacy dynamics-control and dialogue-processing surface that belongs coherently in the existing compressor / De-Esser / multiband architecture, and it performs the explicit residual-dynamics audit before the next parity PR.

The commercial engine keeps the established architecture:
- Swift product/control plane
- portable C realtime DSP
- immutable/precomputed snapshots
- fixed/preallocated runtime state
- no render-callback allocation/free, locks, logging, file/device/UI access, or coefficient construction
- Processed / latency-matched Reference / Delta semantics preserved
- Global Bypass remains the raw escape path

## Clean-room boundary

Historical Notch Sixty implementation source is not an implementation template. Legacy configuration and user-facing UI/state were inspected only to establish externally observable controls, defaults, ranges, modes, and intended behavior. Production algorithms, realtime state, tests, and graph integration are independently authored from public DSP mathematics/literature and the proprietary commercial architecture.

## Starting point

PR31 merged to `main` at:

`c5abc91453d8b23df450a36152ed8ce620cc922d`

PR31 hardware/listening acceptance established that mains-hum suppression and the independently authored spectral denoiser were both effective, with the denoiser notably transparent.

## Slice 1 — detector/control-depth parity: COMPLETE / GREEN

Final substantive Slice 1 source commit:

`991adb645b8cfd5068576e6983268e3a11a66175`

Full integration suite: green.

### Wideband compressor
- feed-forward / feed-back detector topology
- program-dependent release
- detector-only sidechain high-pass filtering
- accepted feed-forward/no-sidechain/default-release behavior retained when new controls are neutral

### De-Esser
- ratio
- maximum attenuation/range
- detector Q / bandwidth control
- attack / release
- existing Dynamic-EQ mode retained
- maximum attenuation explicitly bounded in realtime

### Three-band multiband compressor
- independent Low/Mid and Mid/High LR4/LR8 crossover slopes
- per-band ratio
- per-band attack / release
- per-band knee width
- per-band detector-only sidechain HPF
- per-band makeup gain
- linked-stereo gain remains image-stable
- residual-mid reconstruction remains the unity-recombination contract when no gain reduction/makeup is active

### Slice 1 validation
- feed-forward/feed-back finite and bounded through high sample rates
- De-Esser range bound regression
- independent multiband control regression
- invalid new control ranges rejected
- full existing suite green

## Slice 2 — Dialogue-Relative Leveler: COMPLETE / GREEN

Final substantive Slice 2 source commit:

`2995adfa321da870643b60e9acacc4a304d0c831`

Integration workflow:
- `PR32 Slice 2 Integration`
- run `36215500162`
- full Xcode suite green

### Commercial design
The Dialogue-Relative Leveler is independently authored. It does not simply boost a fixed vocal EQ band when that band is quiet. It compares smoothed full-program energy with smoothed dialogue-band energy and responds to the **relative masking gap**.

Controls:
- dialogue band low / high limits
- target program/dialogue gap
- correction ratio
- maximum boost
- detector window
- attack / release
- near-silence program gate
- optional voice-activity confidence gate

Realtime behavior:
- dialogue band extracted with prepared HP/LP filters
- target correction engages only when the program/dialogue gap exceeds the configured target
- correction is bounded by maximum boost
- same correction is applied to L/R dialogue-band components to preserve image
- only the extracted dialogue band is boosted; the entire program is not gain-ridden
- program gate prevents chasing near-silence/noise floor
- optional speech-confidence gate derives a bounded confidence value from normalized syllabic-rate modulation energy and retains a configurable confidence floor
- no added algorithmic latency
- fixed realtime state and precomputed coefficients only

### Slice 2 validation
- disabled transparency
- program-gate suppression
- relative-masking response
- maximum-boost bound
- voice-confidence floor
- finite operation through 384 kHz
- full existing suite green

## Hardware-validation surface: COMPLETE / GREEN

Validation-surface source commit:

`53292506e8dc1a9cdfd533cca2fd065aceeaab24`

Integration workflow:
- `PR32 Validation Integration`
- run `36215735029`
- full Xcode suite green

The engineering surface exposes all PR32 controls needed for hardware acceptance, including:
- compressor topology / program-dependent release / sidechain HPF
- De-Esser ratio / range / Q / attack / release
- independent multiband slopes and per-band ratio/timing/knee/sidechain/makeup
- full Dialogue-Relative Leveler controls
- voice-confidence-gate controls
- realtime dialogue program level, dialogue-band level, masking gap, confidence, and applied boost

Production visual design remains a later milestone.

## Slice 3 — residual dynamics parity audit: COMPLETE

The authoritative audit is `docs/PR32_DYNAMICS_PARITY_AUDIT.md`.

The audit explicitly accounts for the legacy dynamics-related surface rather than treating the old “roughly 30 dynamics features” statement as a vague checklist. No identified item is silently omitted.

### Required residual work routed to PR33
The audit found several real observable capabilities that should **not** be hidden inside PR32 merely to declare dynamics complete:
- general-purpose Dynamic EQ
- Dynamic Gain Rider / auto-headroom
- explicit True-Peak Guard semantics
- clipper asymmetry trim
- per-band loudness compensation
- De-Harsh tilt filter
- EQ/DSP automatic-headroom compensation

These are required parity items and must be closed in the immediately following advanced-dynamics PR before the bounded optimization/enhancement pass begins.

### Explicit later-milestone deferrals
- infrasonic sub-only / both-path targeting waits for meaningful separate physical sub routing
- independent sub/driver phase and timing waits for routing and/or measurement support
- excess/mixed-phase correction remains in room correction
- output dither remains an output-format/hardening concern
- headphone-only spatial processing remains outside the current product directive

## Hardware acceptance still required

PR32 is **not merge-ready** until the final exact-head hardware build is accepted.

Focused hardware/listening checks:
- Compressor: feed-forward vs feed-back, program-dependent release, detector HPF, no unexpected broadband filtering or gain jump
- De-Esser: ratio/range/Q/timing behave predictably without lispy or smeared artifacts at normal settings
- Multiband: independent slopes and per-band controls remain stable, linked stereo, and transparent at neutral/no-GR settings
- Dialogue Relative Leveler: improves genuinely masked dialogue, respects program gate/max boost, optional voice gate does not pump or wander, stereo placement remains stable
- rapid enable/disable and parameter changes remain click-safe
- Processed / Reference / Delta remain coherent
- Global Bypass remains raw
- no new underrun/overrun/recovery instability

## Exit gate

PR32 is complete only when:
- Slice 1 and Slice 2 deterministic regression coverage is green
- validation UI / telemetry is present
- no PR26–31 regression is introduced
- provenance documentation is updated
- residual audit has no unexplained item
- focused exact-head hardware/listening validation passes

After PR32 merge, proceed directly to the explicitly identified PR33 residual-dynamics parity work. The bounded DSP optimization/enhancement pass begins only after those required residual items are closed.
