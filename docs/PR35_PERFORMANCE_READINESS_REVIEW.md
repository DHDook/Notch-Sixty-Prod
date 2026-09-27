# PR35 DSP Architecture & Performance Readiness Review

Status: **COMPLETE FOR PR35 — implementation/review scope closed; merge only after the exact-head macOS workflow is green. Formal production-UI stress profiling remains intentionally deferred.**

PR35 follows the completed PR34 current-stereo functional-parity milestone. Its purpose is to make the DSP engine structurally ready for world-class realtime performance without delaying the production UI build for an exhaustive performance campaign.

## Ground rules

1. The accepted PR34 audio behavior is the functional/sonic reference.
2. PR35 does not change DSP behavior merely because another implementation may be faster.
3. Fix obvious architectural/realtime inefficiencies when they can be established without speculative benchmarking.
4. Prepare interfaces/data flow now when doing so clearly reduces future optimization cost.
5. Defer algorithmic/micro-optimization claims that require measurement to the later production-app stress/profiling phase.
6. No audio-thread allocation, locking, blocking I/O, coefficient design, FFT-plan creation, resource loading, logging, UI dispatch or other unbounded work may be introduced.
7. All Fix-Now changes require focused regression coverage plus the retained PR34 validators/build/XCTest gate.

## Classification

Every material finding is classified as one of:

- **FIX NOW** — objectively avoidable work, realtime-safety risk, unnecessary copying/recomputation, inactive-path cost, or other low-risk architectural defect that can be corrected without needing benchmark evidence.
- **PREPARE NOW** — interface/state/layout/instrumentation change that improves future profiling/optimization readiness while preserving behavior.
- **BENCHMARK LATER** — plausible performance opportunity whose value/tradeoff must be measured in the production application before implementation.
- **NO ACTION** — reviewed and found structurally appropriate for the current product.

## Review surfaces

- realtime callback/render graph and stage ordering
- snapshot/state publication and lifetime
- Swift-to-C control-plane boundary
- static/minimum/linear/mixed EQ
- domain-aware Dynamic EQ
- convolution/FIR paths (main EQ, room correction, Speaker IR)
- dynamics and denoiser
- true-peak/limiter/protection and oversampling
- bass management/crossover/sub phase alignment
- delay/alignment/spatial stages
- bypass/disabled-stage fast paths
- memory ownership, data locality, alignment and buffer movement
- per-sample expensive math and precomputation opportunities
- SIMD/vDSP/Accelerate/block-processing opportunities
- future high-frequency UI/meter/RTA state-update pressure
- lightweight profiling/signpost hooks for the later measured phase

## Optimization register

| ID | Component | Finding | Classification | Action / acceptance | Status |
|---|---|---|---|---|---|
| PR35-000 | Review framework | Establish explicit review taxonomy and preserve PR34 behavior as reference. | PREPARE NOW | This document governs PR35; no speculative performance claims. | COMPLETE |
| PR35-001 | Dynamics / Dynamic EQ realtime API | `N60DynamicsSnapshot` embeds the two-lane 64-band Dynamic EQ snapshot and was passed by value through several realtime processing calls; Dynamic EQ was then copied again. | FIX NOW | Render-only processing APIs and internal core helpers consume stable snapshot pointers instead of copying nested configuration per frame. | COMPLETE |
| PR35-002 | Realtime output bridge | Startup and graph-transition ramps performed multiple atomic loads/stores per rendered sample even though ramp advancement is callback-local work. | FIX NOW | Control-plane commands are sequence-protected and latched once per output callback; ramp advancement is callback-local arithmetic and only bounded state/telemetry is atomically published outside the per-sample helpers. Retained source guard prevents regression. | COMPLETE |
| PR35-003 | Interactive graph transitions | `AudioIOEngine` is `@MainActor`, while structural graph transitions synchronously stepped fade-down with repeated `usleep` calls before publication. | FIX NOW | Interactive transitions now register a sample-domain fade and schedule midpoint publication on the serial DSP publication worker. No interactive transition sleeps the caller/MainActor. | COMPLETE |
| PR35-004 | Snapshot publication / rapid controls | The two-slot graph publisher may wait for the inactive reader slot. Safe for the audio thread, but synchronous MainActor publication would make rapid production controls inherit callback-duration stalls. | PREPARE NOW | Running-transport graph publication is serialized off-main and ordinary rapid updates coalesce to the newest complete graph. Structural transitions are registered synchronously without sleeping, then complete off-main. Publication/coalescing/failure/transition counters expose future UI pressure. Triple-buffer/nonblocking publication remains measurement-driven. | COMPLETE |
| PR35-005 | Meter / telemetry publication | Peak/RMS and processor telemetry are accumulated in the render context and atomically published at buffer end rather than atomically updated per sample. | NO ACTION | Preserve the buffer-aggregated architecture; production UI should poll bounded telemetry rather than request per-sample publication. | REVIEWED |
| PR35-006 | Partitioned convolution | Realtime memory is preallocated and FIR preparation is off-thread; hot block work uses a scalar custom FFT and scalar complex partition MACs across up to three independent convolution engines. | BENCHMARK LATER | Profile production workload before choosing vDSP/Accelerate, SIMD MACs, shared-input-transform opportunities or partition-size changes. Preserve three independent workflows. | DEFERRED |
| PR35-007 | Domain-aware Dynamic EQ math | Active bands perform detector biquads plus `log10f`, optional `sqrtf`, gain conversion `powf`, smoothing and basis filtering at audio rate; dual-lane modes can double band work. | BENCHMARK LATER | Keep the numerically accepted behavior; evaluate vector/block processing or equivalent fast math only against measured production profiles and strict regressions. | DEFERRED |
| PR35-008 | Spectral denoiser vectorization | The denoiser is preallocated but uses a custom scalar spectral engine up to 4096-point FFTs; it remains a plausible Accelerate/SIMD candidate. | BENCHMARK LATER | Preserve the accepted implementation in PR35; measure real production graphs before choosing transform/vectorization changes. | DEFERRED |
| PR35-009 | Render-kernel documentation | A stale comment described Dynamic EQ as linked physical stereo and said Mid/Side lacked independent dynamic detectors, contradicting the accepted PR34 domain-aware design. | FIX NOW | Corrected so maintenance decisions reflect the current contract. | COMPLETE |
| PR35-010 | Protection runtime reset | `N60ProtectionRuntimeReset()` cleared the full protection runtime, including very large limiter/deque backing arrays, during callback-side graph activation. | FIX NOW | Reset is now logical/sparse with respect to look-ahead backing storage. Dirty-then-reset behavior is retained against a fresh runtime with a dedicated equivalence validator. | COMPLETE |
| PR35-011 | Render-generation snapshot work | A graph generation was latched at callback scope, but nested Dynamics / Dynamic EQ values still incurred avoidable copies in downstream realtime calls. | FIX NOW | The render graph is pinned once per callback and downstream Dynamics / Dynamic EQ processing consumes stable pointers rather than re-copying nested snapshots. Retained render-context coverage protects the pinned-generation lifetime contract. | COMPLETE |
| PR35-012 | Spectral denoiser reset | Denoiser graph activation/reset could clear large inactive backing regions even though logical indices/generation state define validity. | FIX NOW | Reset was made realtime-bounded with touched/logical state reset; dirty/reset and quality-change behavior is compared against fresh runtimes across 44.1/48/96/192/384 kHz. | COMPLETE |
| PR35-013 | Spectral denoiser validation path | The callback repeated snapshot validation that is already guaranteed by the immutable prepared graph. | FIX NOW | Added a prevalidated realtime fast path while retaining the safe public path; dedicated equivalence validation compares audio and telemetry across enabled/bypassed states and 44.1/48/96/192/384 kHz. | COMPLETE |
| PR35-014 | Prepared FIR slot ownership | Main EQ, room correction and Speaker IR use three prepared-program slots: two may be referenced by immutable render generations while the third is prepared. Fully asynchronous structural publication could let a new FIR generation wrap into a still-referenced slot. | FIX NOW | Structural transitions are registered synchronously on the serial coordinator (no sleep), and all prepared FIR paths refuse another program preparation while that structural generation is in flight. This preserves the two-live-generations-plus-one-spare invariant. Retained source guard enforces it. | COMPLETE |
| PR35-015 | Transport shutdown fade | `stop(fadeOut:)` retains one short synchronous fade wait before Core Audio callbacks are stopped and the realtime bridge can be freed. This is teardown/lifetime work, not an interactive graph-update path. | NO ACTION | Keep the bounded shutdown barrier for now. Revisit only if measured app shutdown/restart UX makes it material; do not weaken callback lifetime safety to remove it. | REVIEWED |

## Closure findings

### Realtime callback ownership

The render kernel acquires one immutable graph generation for the output callback. Large nested Dynamics / Dynamic EQ configuration no longer moves by value through the per-frame call chain. Startup and graph-transition gain ramps also no longer use atomics as their per-sample state machine: the control plane publishes sequence-protected commands, the callback latches them at a bounded point, advances local ramp state for the buffer, then publishes bounded transition state afterward.

### Control/UI boundary

The production UI can now issue ordinary graph changes without making the MainActor wait for an inactive render slot. Running-transport publications are serialized on a dedicated control-plane queue and redundant pending ordinary updates collapse to the newest complete graph. Structural changes preserve fade-down/publish/fade-up semantics, but the wait to the fade midpoint occurs on the publication worker rather than through caller-thread `usleep` choreography.

The coordinator exposes counts for graph publications, failed publications, coalesced updates and structural transitions. Combined with the existing underrun/overrun, buffering and render diagnostics, these are intentionally lightweight readiness hooks—not a substitute for the later measured performance campaign.

### Prepared FIR generation safety

The convolution engine intentionally provides three program slots. Two immutable render-graph generations may keep two slots live while the control plane prepares the third. PR35 keeps that contract explicit: a structural transition is registered before its caller returns, and another main-EQ/room-correction/Speaker-IR program cannot be prepared until the in-flight structural generation is published. This avoids trading MainActor responsiveness for a prepared-resource lifetime race.

### Reset work on graph activation

Large protection and denoiser backing arrays are no longer indiscriminately cleared during callback-side activation when logical indices/generation state already make the old contents inactive. The retained equivalence validators exercise dirty-reset/fresh-runtime behavior, denoiser quality changes, and the denoiser prevalidated fast path.

### Telemetry

The existing meter design remains appropriate for UI build-out: samples accumulate into callback-local peak/RMS state, and atomic publication occurs at render-buffer end. Production UI should consume this bounded telemetry model rather than introduce per-frame Swift/UI traffic.

## Retained closure validation

The normal macOS workflow now retains the PR34 Band Pass DSP validator and adds PR35 checks for:

- realtime/control-plane architecture invariants (callback-local ramp state, no interactive `usleep`, publication worker/coalescing, and prepared-FIR transition serialization);
- protection sparse-reset equivalence;
- denoiser bounded-reset equivalence across 44.1/48/96/192/384 kHz;
- denoiser prevalidated-fast-path equivalence across 44.1/48/96/192/384 kHz;
- normal arm64 macOS build and XCTest.

The render-context pinned-snapshot validator remains retained alongside the source and protects the two-slot immutable-generation lifetime contract used by the render kernel.

## Deferred measured phase

The exhaustive performance campaign remains intentionally deferred until the production UI and near-term product layers exist. That later campaign will establish repeatable baselines at 48/96/192/384 kHz and representative/worst-case graphs, including heavy EQ/Dynamic EQ, high-order slopes, Linear/Mixed Phase, simultaneous FIR workflows, denoiser modes, 4x protection, bass management, full stereo processing, meters/RTA/UI update load and actual transport/device behavior.

The primary measurement-driven candidates carried forward are convolution/vectorization/FFT strategy, Dynamic EQ hot math, denoiser transform/vectorization, and—only if graph-publication counters show meaningful pressure—deeper publisher buffering/nonblocking changes. Those items are deliberately not presented as performance wins until measured in the production application.
