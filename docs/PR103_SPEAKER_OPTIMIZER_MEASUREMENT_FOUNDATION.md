# PR103 — Speaker Optimizer Measurement Foundation

Status: **IN PROGRESS — STACKED ON PR102 REMOTE SOFTWARE CLOSURE**

## Purpose

PR103 establishes the measurement and evidence foundation for the approved
Speaker Optimizer feature track.

It does **not** yet design or deploy corrective filters. PR104 owns optimization
and candidate design. PR103's job is to produce measurement evidence strong
enough that later optimization can make decisions without guessing.

## User workflow constraints

- Default to **one movable measurement microphone**.
- Do not require listener-head microphone arrays, headrest hardware, or
  permanent multi-mic installations.
- Reuse the existing speaker/subwoofer calibration and measurement transport
  where safe rather than creating a parallel audio stack.
- Preserve active-crossover and driver-protection routing during measurement.
- Do not silently apply optimizer candidates.
- Keep Speaker Optimizer under **SYSTEM → Speaker Calibration**, distinct from
  Room Correction.

## Measurement scope

PR103 measures isolated controllable acoustic sources such as:

- full-range speakers;
- subwoofers;
- active-crossover driver/output buses where individually addressable;
- source groups that later optimization explicitly needs to compare.

A session may cover one or more movable-mic positions. Each source/position
combination is measured repeatedly so the system can distinguish stable
acoustic behavior from transient noise, movement, clipping, timing ambiguity,
or inconsistent captures.

## Core evidence

For each repeated source/position capture PR103 records compact analyzed
evidence rather than retaining unnecessary raw sweep buffers:

- source/output identity;
- microphone/instrument identity;
- seat/position identity;
- sample rate and measurement configuration;
- analyzed frequency response;
- arrival/timing estimate;
- phase/coherence evidence where supported;
- signal-to-noise / quality metrics;
- clipping/invalid-sample flags;
- repeatability statistics across sweeps.

## Confidence model

Measurement confidence must be explicit and fail closed.

At minimum, confidence considers:

- repeatability between repeated sweeps;
- usable SNR;
- stable arrival/timing estimates;
- coherent frequency/phase evidence over the supported band;
- clipping/non-finite contamination;
- source/position coverage completeness; and
- identity continuity across the measurement set.

Weak or inconsistent evidence may be stored for diagnosis, but it must not be
promoted to optimizer-ready evidence.

## Measurement-set identities

PR103 introduces explicit evidence roles:

- **baseline** — pre-optimization measurement set;
- **candidate** — measurement associated with a proposed/previewed configuration
  when a later PR supplies one; and
- **verification** — post-apply measurement used to prove actual behavior.

The identities are intentionally distinct. Prediction in PR104/PR105 must never
be represented as measured verification.

## Crossover and speaker-safety boundary

Speaker Optimizer measurement must use the existing safe output-routing and
calibration infrastructure.

For active speaker systems:

- preserve mandatory crossover/protection filters;
- never expose a protected driver to an unsafe full-range measurement signal;
- retain configured polarity/delay/routing identity;
- isolate only the controllable source necessary for the current measurement.

PR103 must not add a raw bypass path around driver protection.

## Persistence

Persist compact, versioned analyzed measurement evidence sufficient for later
optimization and verification. Avoid retaining large raw sweep recordings
unless a later explicitly approved diagnostic feature requires them.

## Remote vs physical evidence

Remote CI may establish:

- measurement-state/data-model correctness;
- repeated-capture aggregation;
- confidence/fail-closed behavior;
- identity integrity;
- crossover-safe routing contracts;
- deterministic synthetic/reference tests; and
- persistence/migration behavior.

Remote CI cannot establish:

- real microphone calibration accuracy;
- real loudspeaker/driver acoustic response;
- real room/background-noise conditions;
- real speaker-safe electrical/acoustic behavior; or
- final measured optimizer effectiveness.

## Planned slices

### Slice 1 — Measurement evidence model and confidence aggregation

- source/position/run identities;
- baseline/candidate/verification roles;
- repeated sweep evidence;
- SNR/repeatability/timing/coherence aggregation;
- fail-closed optimizer-ready status;
- deterministic tests.

### Slice 2 — Existing calibration transport integration

- reuse current sweep/capture transport;
- isolate speaker/sub/driver sources safely;
- preserve crossover/protection routing;
- one-mic move-between-position workflow.

### Slice 3 — Session orchestration and persistence

- source × position measurement plan;
- repeat scheduling;
- interruption/retry semantics;
- compact versioned analyzed evidence;
- identity continuity checks.

### Slice 4 — Speaker Calibration UI integration

- guided measurement progress;
- per-source/position confidence;
- repeatability/SNR/timing/coherence diagnostics;
- clear optimizer-ready / blocked reasons.

### Slice 5 — PR103 closure

- cumulative deterministic tests;
- arm64 build/full regression;
- explicit hardware handoff;
- no corrective filter generation or silent deployment.

## Next roadmap items

- PR104 — Measurement-Driven Speaker Optimization Engine
- PR105 — Guided Speaker Optimizer & Acoustic Verification
- PR106 — Advanced Speaker Measurement Lab
