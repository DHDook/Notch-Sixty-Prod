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

## Current execution status — PR113B

**PR113B — World-Class Product Finish** is the active remote milestone,
stacked directly on the exact remotely-complete PR113 head
`f0a260336a0df7284a0c414f39a6e43b7d86ca1b`.

The agreed pre-RC scope is intentionally product-focused rather than another
core-DSP expansion:

- Slice 1 — safe A/B comparison foundation and snapshot boundary;
- Slice 2 — click-free / loudness-matched A/B audition UI;
- Slice 3 — full Notch Sixty backup & restore bundle;
- Slice 4 — full-fidelity Measurement Lab export;
- Slice 5 — Safe Launch / Recovery Mode;
- Slice 6 — Headroom Assistant; and
- Slice 7 — non-intrusive Getting Started guide refresh plus cumulative closeout.

The modal first-run assistant and Playback-System lock are deliberately
deferred.

**Slice 1 is implemented remotely.** A/B capture is temporary, in-memory and
non-live. The allowed audition payload is limited to stereo EQ, input preamp,
headroom attenuation and content dynamics. Audio Unit rack topology and every
Playback-System/hardware-domain setting remain outside the A/B payload. Each
snapshot pins the selected Playback System identity plus exact
`PlaybackSystemState`; later audition must fail closed on identity or state
drift.

Slice 1 deliberately introduces **no live A/B Apply/switch method**. The
click-free executor moves to Slice 2 after the safety boundary is regression
locked.

PR113B software work cannot satisfy PR112 physical acceptance and cannot set
`releaseAcceptanceComplete`, `liveFeedForwardANCAuthorized`, or
`mayMergeIntoMain` true. PR113B, PR113 and all ancestors remain **OPEN,
DRAFT and UNMERGED**; `main` is unchanged.

See `docs/PR113B_WORLD_CLASS_PRODUCT_FINISH.md`.

---

## Current execution status — PR113

**PR113 — Production UX, Preferences & Reference** is the active remote
milestone, stacked on the exact remote/software-complete PR112A head
`0df13292ba02ea5d21c094fabeb48894d94c2b1d`.

Slices 1–4 are implemented:

- **Preferences & Reference** replaces the former single Settings scroll with
  General, User Guide and DSP Reference destinations.
- The data-driven User Guide has explicit coverage for every production
  workspace plus Getting Started, app preferences, workflow vocabulary and a
  DSP glossary.
- DSP Reference exposes implementation-audited equations and distinguishes core
  math, implementation relationships and diagnostic/model definitions.
- Every main workspace has a contextual reference entry point; selected EQ and
  dynamics controls deep-link directly to the matching math.
- Preview / Apply / Verify / Revert / Rollback / Deploy now have explicit
  product-wide semantics.
- The documentation surface is responsive and contextual help has explicit
  accessibility labels.
- The math audit corrected Room Correction documentation to its actual
  **causal minimum-phase cepstral FIR** implementation rather than a
  linear-phase approximation.

Slice 5 is the remote closeout gate: PR113/inherited safety audits, Apple
Silicon Debug/Release builds, targeted production-IA/reference tests, full
cumulative XCTest, and a machine-readable remote UX readiness artifact.

That artifact can mark PR113 remote UX/software complete but must always retain
`physicalAcceptanceComplete=false`,
`releaseAcceptanceComplete=false`,
`liveFeedForwardANCAuthorized=false`,
`mayMergeIntoMain=false`, and
`physicalEvidenceSuppliedByCI=false`.

Physical PR112 H01–H08 execution remains separate hands-on work. PR113, PR112A
and every ancestor remain **OPEN, DRAFT and UNMERGED**; `main` is unchanged.

See `docs/PR113_PRODUCTION_UX.md`.

---

## Current execution status — PR112A

**PR112A — Remote Hardware-Acceptance Infrastructure** is now the active
remote milestone, stacked on exact-head remote/software-complete PR111.

Slices 1–5 now implement the complete remote PR112A acceptance
infrastructure: authoritative H01–H08 evidence authority, guided campaign/UI,
typed H03–H07 evidence links, state/topology preflight including the PR111
commissioning handoff, and exportable JSON/Markdown acceptance packets with
artifact manifests and a safety-bounded physical runbook. H05 whole-speaker
Measurement Lab acceptance remains mandatory even when protected split-driver
work is excluded for a passive speaker topology.

The dedicated PR112A CI artifact must always retain
`physicalAcceptanceComplete=false`,
`releaseAcceptanceComplete=false`,
`liveFeedForwardANCAuthorized=false`, and
`mayMergeIntoMain=false`.

PR112A remote/software implementation is complete. Implementation head `d00ae1d35a82d5e594ce431b7d08823592211f0d` passed portable, Apple Silicon Debug/Release, targeted acceptance/IA tests, and full cumulative XCTest in Actions run `38364855616`.
Real unplug/replug, sleep/wake, thermal/endurance, speaker safety, calibrated
acoustic measurements, combined-driver verification, physical driver
commissioning and any transactional Apply remain hands-on PR112 work.

See `docs/PR112A_REMOTE_HARDWARE_ACCEPTANCE.md`.

---

## Current execution status — PR111

**PR111 — Automatic Per-Driver Speaker Optimization** remains an OPEN,
DRAFT, UNMERGED stack above PR110. Slices 1–5 passed remote/software
portable, Apple Silicon Debug/Release, targeted and full regression at
`f8ef81a80d1aac262ec21da23abef5ed29825506` / Actions run `38347561995`.
PR111 remote/software implementation is complete; physical commissioning
and Apply remain deferred to PR112.

The implemented remote PR111 stack now provides:

- repeat-qualified protected Low/Mid/High cut-only PEQ recommendations;
- Measurement Lab driver evidence, blockers and compact exports;
- simultaneous electrical-reference adjacent-driver timing and residual
  polarity hypotheses, topology-aware for Bi-Amp versus Tri-Amp;
- model-only complex crossover-summation comparison of only those bounded
  timing/polarity hypotheses; and
- a persisted, exact-state commissioning **preview** with a full rollback
  snapshot, state-drift validation and hard `canApply=false` /
  `canDeploy=false` gates.

PR111 deliberately stops before any live driver mutation. A real
combined-driver crossover capture does not yet exist, so timing/polarity
or PEQ deployment cannot be physically verified. The Measurement Lab UI
therefore reports **HARDWARE BLOCKED / Apply BLOCKED** and exposes no PR111
Apply control.

The transactional Apply/rollback executor moves to **PR112 physical hardware
acceptance**, where it must require engine idle, explicit user approval, exact
state/evidence identity, preserved crossover/limiter protection, fresh
combined-driver measurement and rollback on rejection. PR113 production UX
polish and PR114 commercial release preparation remain later.

PR110, PR109 and every predecessor remain OPEN/DRAFT/UNMERGED; `main` is
unchanged. See `docs/PR111_PER_DRIVER_SPEAKER_OPTIMIZATION.md`.

---

## Current execution status — PR110

**PR110 — Advanced Speaker & Subwoofer Placement Optimizer** is now in
remote implementation, stacked on draft PR109. Its first software slice
generates read-only, bounded experiments for independently positioned
left/right speakers, toe-in, height, and modeled physical Sub positions,
including up to eight listener seats. These are *geometry hypotheses*,
never quantified acoustic improvements or DSP deployments.

Subsequent slices add project-scoped advanced geometry persistence,
PR106 source-specific measurement corroboration, multi-seat/Sub ranking,
and measured physical before/after acceptance. This work does not merge,
close or promote any PR; it does not satisfy PR109's independent
exact-head macOS regression, physical acceptance or release credentials.

See \`docs/PR110_ADVANCED_PLACEMENT.md\`. PR111 per-driver optimization
remains planned; PR112 physical hardware acceptance, PR113 final UX and
PR114 commercial release candidate remain later milestones.

---

## Current execution status — PR109

**Roadmap PR109 — Integration & Stack Consolidation** has begun on a draft,
stacked feature branch above remote-software-complete PR108. The first PR109
slice records pinned PR99–108 milestone ancestry and runs read-only cumulative
source/CI verification. It does **not** merge or close any existing PR or modify
`main`, audio processing or physical hardware.

The owner is away from the Mac. All PR101–108 physical/acoustic acceptance,
real-device safety, production Apple signing, TestFlight/App Review, and public
release authorization remain pending. Remote CI must not elevate simulated
acceptance to hardware or release acceptance. The stack stays open and draft
until the owner elects to review/merge it after the appropriate physical tests.

Next provisional feature/release milestones agreed after PR108:

- **PR109 — Integration & Stack Consolidation** (now in progress remotely);
- **PR110 — Advanced Speaker & Subwoofer Placement Optimizer** (planned);
- **PR111 — Automatic Per-Driver Speaker Optimization** (planned);
- **PR112 — Physical Hardware & Acoustic Acceptance** (requires the Mac);
- **PR113 — Production UX & Workflow Polish** (planned);
- **PR114 — Commercial Release Candidate** (requires release credentials).

The latest implementation and exact acceptance scope are in
`docs/PR109_INTEGRATION_STACK_CONSOLIDATION.md`.
Historical milestone status sections below are preserved as immutable audit
context, not a statement that PR108 is still current. The historical PR102
checkpoint label was `Current execution status — PR102`; PR102 was remotely
completed, not hardware- or release-approved.

---

## Current execution status — PR108

The historical parity/rewrite stages below are retained as project history.
They are **not** the current execution state.

The cumulative product has progressed through:

- clean-room proprietary rewrite and parity closure;
- production UI/persistence/interchange;
- room correction and speaker/multichannel calibration;
- semantic N-channel transport/DSP;
- headphone/binaural/SOFA/head-tracking foundations;
- advanced room treatment and ambient adaptation;
- Audio Unit hosting;
- Active Acoustics / Quiet Zone software foundations;
- hardware-timing/feed-forward runtime scaffolding;
- Active Acoustics commissioning UX; and
- PR101 full-system reliability and remote/software acceptance;
- PR102 integration/commercial release preparation;
- PR103 Speaker Optimizer measurement foundation;
- PR104 measurement-driven optimization design;
- PR105 guided characterization, PEQ deployment and fresh verification;
- PR106 Advanced Speaker Measurement Lab;
- PR107 Speaker Optimizer FIR deployment and latency coordination; and
- PR108 coherent physical Sub timing/polarity optimization through guided
  production commissioning.

### PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization

Current work:

- consume PR106 reference-authenticated coherent Main/Sub evidence;
- generate bounded single-Sub or coordinated multi-Sub timing/polarity proposals;
- bind proposal/evidence to immutable commissioning identity and explicit approval;
- apply only speaker/Sub timing and Sub polarity transactionally;
- require fresh post-Apply coherent Measurement Lab verification;
- persist provisional/verified PR108 provenance independently of ordinary
  multichannel calibration;
- provide guided Measurement Lab review/Apply/verify/rollback UI; and
- hand off real DAC/ADC/reference-path acoustic acceptance.

PR108 may close remotely while explicitly leaving real coherent hardware,
acoustic benefit and subjective listening acceptance unresolved.

### Approved post-PR102 feature track

- **PR103 — Speaker Optimizer Measurement Foundation**
- **PR104 — Measurement-Driven Speaker Optimization Engine**
- **PR105 — Guided Speaker Optimizer & Acoustic Verification**
- **PR106 — Advanced Speaker Measurement Lab**
- **PR107 — Speaker Optimizer FIR Deployment & Latency Coordination**
- **PR108 — Coherent Physical Subwoofer Timing & Polarity Optimization**

The Speaker Optimizer / Measurement Lab track is intentionally sequenced after
PR102. PR107 adds a separately owned FIR deployment path with explicit latency
coordination; PR108 then uses PR106's authenticated coherent timing evidence to
commission physical Main/Sub integration without conflating it with spectral
speaker correction.

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

## Historical stage — PR #22

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

### Historical Stage K — commercial launch
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
