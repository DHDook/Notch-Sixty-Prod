# Commercial Roadmap

## North star

Notch Sixty is the first commercial product built on a proprietary, high-end DSP platform.

Release goals:
- 100% functional feature parity with the legacy Notch Sixty application
- independent replacement of GPL-derived implementation expression
- deliberate reuse of later owner-authored code only after provenance and quality review
- improvements to touched subsystems rather than mechanical reproduction
- polished Mac App Store-ready UI and lifecycle
- world-class DSP quality with portable DSP/acoustics boundaries suitable for future Windows, iOS, Android, and other suite products

Legacy parity is the minimum capability floor. The commercial rewrite should exceed it where useful.

Future portability must not materially delay the flagship Mac launch.

## Migration rule

For each legacy capability:

1. **GPL-derived / inherited path** — specify behavior and independently reimplement from public specifications, Apple/platform APIs, DSP literature, and clean tests.
2. **Later owner-authored clean candidate** — verify authorship/source history and third-party licensing; deliberately port only if it also fits the new realtime architecture and quality bar.
3. **Clean but weak/obsolete** — preserve the product capability but reimplement it better.

Do not recreate the historical `EqualiserStore`, inherited routing hierarchy, or old implementation structure merely for parity.

## Completed foundation — PR #1 through PR #21

### Commercial / transport
- virgin proprietary repository and provenance policy
- App Sandbox from bootstrap
- Xcode / CI / hardware-test DMG
- device-scoped Core Audio process-tap transport
- selected physical output by stable UID
- native-rate operation through device-exposed rates up to 384 kHz
- idle-safe startup, Stop/Quit, rate rebuild, same-device recovery, sleep/wake

### Realtime DSP platform
- allocation-free render kernel
- immutable graph snapshots and atomic publication
- explicit latency and numerical-safety diagnostics
- 64-band parametric EQ
- input preamp, internal headroom, output gain, peak/RMS metering
- LR24/LR48 bass-management foundation
- partitioned FIR convolution
- native-rate linear-phase EQ and live minimum/linear switching
- independent room-correction convolution stage and control plane

## Current stage — PR #22

### Product control/state foundation
Keep this stage tight and behavior-preserving.

Goals:
- establish a product-level ownership boundary above AudioIO/transport
- provide a compact versioned product/DSP configuration snapshot for future persistence and presets
- prevent `AudioIOEngine` from becoming the new monolithic application store
- preserve all PR #1–21 audio behavior
- make subsequent parity/UI work target product-domain APIs rather than adding unrelated concerns to transport

This is an enabling stage, not a prolonged architecture rewrite.

## Aggressive parity roadmap

The stages below are major delivery slices. Exact PR numbering may move if review/CI risk requires a split.

### Stage B — stereo + playback-control parity
- linked vs independent L/R EQ
- left/right editing focus
- channel balance
- global bypass
- latency-matched Processed / Reference comparison
- Delta monitoring (`Processed − latency-matched Reference`)
- master volume and mute
- macOS volume-key / external-volume synchronization
- persistence hooks

### Stage C — full legacy dynamics parity + oversampling
The legacy application exposes roughly 30 dynamics-related capabilities. **Every one of them must be inventoried and reach PARITY, IMPROVED, PORT VERIFIED, or an explicit superseding implementation before parity closure.** This stage may span multiple implementation PRs for review and realtime-risk control; splitting the work does not reduce the parity requirement.

Foundation and known capabilities include:
- detector/envelope infrastructure
- compressor and all legacy compressor variants/modes
- expander and all legacy expander variants/modes
- pause gate and related gate controls
- look-ahead / brickwall limiting and all legacy limiter modes
- soft clipping / clipping protection
- de-essing and multiband dynamics
- loudness/dynamics compensation features where classified as dynamics
- true-peak infrastructure and legacy true-peak/clip trip behavior
- stage gain-reduction telemetry and metering
- automatic-headroom interactions
- 1x / 2x / 4x oversampling and every legacy oversampling-dependent dynamics path
- all additional legacy dynamics features discovered by the formal inventory, even if not named above

For each legacy dynamics capability, apply the provenance gate: inherited/GPL-path implementations are independently recreated; demonstrably owner-authored post-fork implementations may be deliberately ported only after provenance and quality review; clean but weak/buggy implementations are reimplemented or improved.

Pause gate semantics remain:
- Attack = fade-out
- Release = fade-in
- UI presents fade-out before fade-in while retaining conventional names

### Stage D — advanced DSP parity
After provenance review, implement or deliberately migrate all remaining legacy processing, including where applicable:
- multiband compressor
- de-esser
- loudness matching
- stereo widener
- all-pass / fractional-delay utilities
- mixed/excess-phase tools
- spectral denoising
- mains-hum detection/notching
- remaining advanced crossover/loudspeaker processing
- explicit SRC if retained as a product feature

No legacy feature is silently omitted. Each must end as parity, improved, deliberately ported, explicitly superseded, or a release blocker.

### Stage E — full analysis / RTA
- production peak/RMS
- true peak
- RTA / spectrum
- phase correlation
- crest factor
- balance metering
- per-stage gain reduction
- goniometer if required by final parity inventory

Begin replacing engineering validation UI with the real production shell no later than this stage.

### Stage F — complete room-correction suite

#### Measurement
- microphone discovery/selection and permission
- microphone calibration-file support
- deterministic sweep/excitation
- synchronized playback/capture
- cancellation and recovery

#### Acoustic analysis / multi-seat
- deconvolution
- impulse response and transfer function
- timing / magnitude / phase
- measurement quality/confidence checks
- named positions
- intended three-seat workflow
- alignment, weighting, averaging, dataset persistence

#### Correction design
- built-in and custom/imported target curves
- correction-range policy
- smoothing and boost/cut limits
- correction FIR generation
- automatic correction headroom
- optional mixed/excess-phase correction
- deployment into the existing room-correction runtime

### Stage G — persistence / presets / interchange
- versioned commercial state schema and migrations
- device preferences
- user and proprietary factory presets
- full DSP state
- room-correction state
- `.eqpreset`
- REW
- AutoEQ
- CamillaDSP
- EasyEffects where required for parity
- other required adapters

### Stage H — production UI completion
Complete the commercial interface for:
- playback/output/status
- master volume/mute/bypass
- EQ and response visualization
- linked/stereo editing and phase mode
- dynamics and gain reduction
- RTA/meters
- crossover/sub controls
- presets
- room correction
- settings/permissions/recovery

Engineering diagnostics move to an explicit debug/developer surface.

### Stage I — formal parity closure
For every externally observable legacy capability mark one of:
- PARITY
- IMPROVED
- PORT VERIFIED
- SUPERSEDED
- BLOCKED

Commercial launch requires zero unexplained omissions and zero unresolved release blockers.

Also complete the implementation provenance audit and third-party license review.

### Stage J — production hardening
- Instruments profiling
- allocation/leak analysis
- worst-case DSP CPU
- 44.1 / 48 / 96 / 192 / 384 kHz matrix where hardware permits
- rapid parameter/UI responsiveness
- long soak tests
- Stop/Start loops
- nominal-rate changes
- unplug/replug
- sleep/wake
- permission lifecycle
- corrupted-state recovery
- normal Quit and force-quit recovery
- accessibility and keyboard control

### Stage K — commercial launch
- Mac App Store signing/entitlements
- archive/export
- TestFlight
- clean-account / clean-machine validation
- App Review behavior
- SBOM / third-party notices
- final provenance and asset-rights audit
- targeted open-source/IP counsel review
- App Store submission

## Parallelization strategy

To preserve the aggressive schedule:
- **Engine/parity track:** continue DSP/domain implementation.
- **Production UI track:** begin once product APIs stabilize; do not wait for every backend feature.
- **Provenance track:** classify upcoming legacy features shortly before implementation so clean owner-authored work can accelerate delivery.
- **Validation track:** deterministic tests plus hardware validation for every audio-path change.

Avoid a large end-of-project integration phase; integrate continuously.

## Future suite architecture

Keep reusable DSP/acoustics logic independent of host transport where practical:

```text
Portable DSP / acoustics / preset-domain layer
                    ↓
        shared feature/control models
                    ↓
     platform-specific host integrations
       ┌──────────┬──────────┬──────────┐
       │          │          │          │
     macOS      Windows      iOS      Android
```

Core Audio process taps remain macOS-specific. Future Windows/mobile host layers should not distort the current Mac transport architecture.
