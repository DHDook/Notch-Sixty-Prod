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


## Slice 2 implementation checkpoint

The first transport-integration layer is implemented as a fail-closed planning
adapter around the existing `MultichannelCalibrationTransport`.

### Reused safely now

Whole acoustic sources already represented by
`MultichannelCalibrationSource` (ordinary speaker roles and physical
subwoofers) may reuse the existing one-source targeted calibration transport
when:

- the source resolves to one valid physical output lane;
- no enabled split-driver Low/Mid/High/Sub bus routing is present; and
- no enabled per-driver limiter would be bypassed by direct targeted output.

The plan records the resolved physical channel explicitly.

### Deliberately blocked now

`SpeakerOptimizerMeasurementExcitationTarget.protectedDriverBus` represents
the future per-driver measurement use case, but PR103 does **not** translate
that target into a direct physical sweep.

Protected driver measurement remains blocked because the existing targeted
calibration transport writes the precomputed sweep directly to a physical
output lane. Doing that to Low/Mid/High driver outputs could bypass mandatory
crossover filtering and per-driver protection.

Likewise, reuse of the existing targeted transport fails closed when active
split-driver routing or an enabled per-driver limiter is detected.

This is intentional scope discipline: PR103 now knows the difference between a
safe reusable whole-source measurement and a protected driver measurement, but
it does not manufacture an unsafe bypass merely to claim driver-level coverage.

### One movable microphone

The transport plan remains compatible with PR103's one-mic workflow. Position
identity belongs to the measurement set; the same selected microphone can be
moved between positions while each capture retains microphone, routing, source,
sample-rate and position identity.


## Slice 3 implementation checkpoint

Session orchestration and compact persistence are implemented.

### Deterministic one-mic plan

`SpeakerOptimizerMeasurementSessionOrchestrator` derives the complete session
from the measurement set itself:

- positions are visited in stored order;
- all planned sources/repeats at one position are completed before moving the
  microphone to the next position;
- each position/source requires at least the evaluator's three-repeat minimum;
- the next pending repeat is derived from persisted analyzed captures.

There is no separate hidden "current measurement index" that can become stale.

### Interruption and resume

If measurement is interrupted before a capture is successfully analyzed and
appended, no evidence is added. Reloading the measurement set therefore resumes
at that same pending repeat.

If the user explicitly elects to retry a completed repeat, the orchestrator
removes only the latest analyzed capture for that exact position/source group;
the derived plan then makes that repeat pending again.

### Identity continuity

Appending a capture fails closed unless it matches the measurement set's:

- playback-system UUID;
- routing signature;
- microphone identity/calibration fingerprint;
- sample rate;
- position; and
- source.

Captures cannot be silently transplanted between sessions.

### Compact versioned persistence

`SpeakerOptimizerMeasurementSetStore` persists the existing versioned
`SpeakerOptimizerMeasurementSet` under Application Support.

Persistence keeps analyzed response/quality evidence only. It does not add raw
sweep or raw impulse buffers. Structural validation runs on both save and load,
including schema, duplicate IDs, source/position coverage domain, and capture
identity continuity.


## Slice 4 implementation checkpoint

Speaker Optimizer measurement is now integrated into the existing
**SYSTEM → Speaker Calibration** workspace.

The UI owns a dedicated `SpeakerOptimizerMeasurementController` that reuses
the already-selected playback system, measurement microphone, calibration
transport and analyzer.

The measurement surface provides:

- explicit Start/Resume Baseline session control;
- position-major one-mic movement guidance;
- next source/repeat identity;
- overall repeat and position/source-group progress;
- current sweep progress;
- aggregate confidence and optimizer-ready state;
- per-position/source SNR, magnitude repeatability, arrival spread and phase
  consistency; and
- explicit blocking reasons.

PR103 still exposes **no filter generation or Apply action** for Speaker
Optimizer.

The workspace also states the driver-safety boundary directly: protected
Low/Mid/High driver-bus measurements remain blocked rather than sending a raw
full-band sweep around mandatory crossover/protection processing.


## Slice 5 closure checkpoint

The final remote-closure machinery is now present:

- full XCTest is part of the PR103 exact-head workflow;
- `docs/PR103_SOFTWARE_CLOSURE.md` defines the remote acceptance boundary;
- `docs/PR103_PHYSICAL_HANDOFF.md` defines the genuine microphone/speaker
  acceptance work that cannot be satisfied by CI;
- the controller no longer uses a forced initialization path; and
- the PR103 validator enforces the measurement-only / protected-driver
  fail-closed contracts.

PR103 remains **PENDING EXACT-HEAD CI** until the current head passes the full
workflow. Only then may the remote/software status be promoted to complete.
