# PR35 DSP Architecture & Performance Readiness Review

Status: **COMPLETE FOR PR35 — implementation/review scope closed; merge only after the exact-head macOS workflow is green and the final local baseline-CPU smoke test is normal. Formal production-UI stress profiling remains intentionally deferred.**

PR35 follows the completed PR34 current-stereo functional-parity milestone. Its purpose is to make the DSP engine structurally ready for world-class realtime performance without delaying the production UI build for an exhaustive performance campaign.

## Ground rules

1. The accepted PR34 audio behavior is the functional/sonic reference.
2. PR35 does not change DSP behavior merely because another implementation may be faster.
3. Fix obvious architectural/realtime inefficiencies when they can be established without speculative benchmarking.
4. Prepare interfaces/data flow now when doing so clearly reduces future optimization cost.
5. Defer algorithmic/micro-optimization claims that require measurement to the later production-app stress/profiling phase.
6. No audio-thread allocation, locking, blocking I/O, coefficient design, FFT-plan creation, resource loading, logging, UI dispatch or other unbounded work may be introduced.
7. All Fix-Now changes require focused regression coverage plus the retained PR34 validators/build/XCTest gate.
8. **A user-visible OFF state is a computational OFF state after any short click-free disable tail.** Persistent configuration remains intact; inactive realtime algorithms do not continue running merely to produce dry/unity output. Narrow transport/safety/alignment exceptions must be explicit and bounded.

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
- meter/analyzer gating and telemetry publication
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
| PR35-005 | Meter / telemetry processing | Atomic publication was already buffer-bounded, but input/post-EQ/output peak/RMS accumulation still ran every audio sample even though the current app has no graphical meter UI. | FIX NOW | Added an explicit snapshot-level metering gate, default OFF. Sample-rate meter accumulation and meter publication run only when metering is explicitly enabled; the existing bounded callback-end publication model is retained when active. | COMPLETE |
| PR35-006 | Partitioned convolution | Realtime memory is preallocated and FIR preparation is off-thread; hot block work uses a scalar custom FFT and scalar complex partition MACs across up to three independent convolution engines. | BENCHMARK LATER | Profile production workload before choosing vDSP/Accelerate, SIMD MACs, shared-input-transform opportunities or partition-size changes. Preserve three independent workflows. | DEFERRED |
| PR35-007 | Domain-aware Dynamic EQ math | Active bands perform detector biquads plus `log10f`, optional `sqrtf`, gain conversion `powf`, smoothing and basis filtering at audio rate; dual-lane modes can double band work. | BENCHMARK LATER | Keep the numerically accepted behavior; evaluate vector/block processing or equivalent fast math only against measured production profiles and strict regressions. | DEFERRED |
| PR35-008 | Spectral denoiser vectorization | The denoiser is preallocated but uses a custom scalar spectral engine up to 4096-point FFTs; it remains a plausible Accelerate/SIMD candidate. | BENCHMARK LATER | Preserve the accepted active implementation in PR35; measure real production graphs before choosing transform/vectorization changes. | DEFERRED |
| PR35-009 | Render-kernel documentation | A stale comment described Dynamic EQ as linked physical stereo and said Mid/Side lacked independent dynamic detectors, contradicting the accepted PR34 domain-aware design. | FIX NOW | Corrected so maintenance decisions reflect the current contract. | COMPLETE |
| PR35-010 | Protection runtime reset | `N60ProtectionRuntimeReset()` cleared the full protection runtime, including very large limiter/deque backing arrays, during callback-side graph activation. | FIX NOW | Reset is now logical/sparse with respect to look-ahead backing storage. Dirty-then-reset behavior is retained against a fresh runtime with a dedicated equivalence validator. | COMPLETE |
| PR35-011 | Render-generation snapshot work | A graph generation was latched at callback scope, but nested Dynamics / Dynamic EQ values still incurred avoidable copies in downstream realtime calls. | FIX NOW | The render graph is pinned once per callback and downstream Dynamics / Dynamic EQ processing consumes stable pointers rather than re-copying nested snapshots. Retained render-context coverage protects the pinned-generation lifetime contract. | COMPLETE |
| PR35-012 | Spectral denoiser reset | Denoiser graph activation/reset could clear large inactive backing regions even though logical indices/generation state define validity. | FIX NOW | Reset was made realtime-bounded with touched/logical state reset; dirty/reset and quality-change behavior is compared against fresh runtimes across 44.1/48/96/192/384 kHz. | COMPLETE |
| PR35-013 | Spectral denoiser validation path | The callback repeated snapshot validation that is already guaranteed by the immutable prepared graph. | FIX NOW | Added a prevalidated realtime fast path while retaining the safe public path; dedicated equivalence validation compares audio and telemetry across enabled/bypassed states and 44.1/48/96/192/384 kHz. | COMPLETE |
| PR35-014 | Prepared FIR slot ownership | Main EQ, room correction and Speaker IR use three prepared-program slots: two may be referenced by immutable render generations while the third is prepared. Fully asynchronous structural publication could let a new FIR generation wrap into a still-referenced slot. | FIX NOW | Structural transitions are registered synchronously on the serial coordinator (no sleep), and all prepared FIR paths refuse another program preparation while that structural generation is in flight. This preserves the two-live-generations-plus-one-spare invariant. Retained source guard enforces it. | COMPLETE |
| PR35-015 | Transport shutdown fade | `stop(fadeOut:)` retains one short synchronous fade wait before Core Audio callbacks are stopped and the realtime bridge can be freed. This is teardown/lifetime work, not an interactive graph-update path. | NO ACTION | Keep the bounded shutdown barrier for now. Revisit only if measured app shutdown/restart UX makes it material; do not weaken callback lifetime safety to remove it. | REVIEWED |
| PR35-016 | Disabled DSP baseline cost | Manual PR35 smoke testing exposed roughly one-core CPU use with audio processing enabled but EQ/dynamics audibly disabled; PR34 showed the same behavior. Source review found disabled stages remained computationally active, most notably the spectral denoiser running its complete FFT/profile/overlap-add engine while returning dry audio, plus disabled Dynamics analyzers/filter cascades continuing to execute. | FIX NOW | Disabled denoiser playback now parks before buffering/FFT work except during explicit profile capture. Pre-EQ, core Dynamics and pause-gate paths retain click-free disable tails, then park at neutral state. Persistent user configuration and learned denoiser profile state remain intact; only transient processing history is reset where required for a clean re-enable. | COMPLETE |
| PR35-017 | User-visible OFF contract | The broader audit found additional optional work that could stay hot at neutral settings: configured-but-master-disabled Dynamic EQ, unconditional mains-hum analysis, neutral 1x protection telemetry/math, spatial matrices/head-shadow filtering at zero amount, disabled alignment delay reads, and always-on graphical meter accumulation. | FIX NOW | OFF now means computationally parked after transition tails. Dynamic EQ gains an explicit parked state; mains analysis follows `continuousTracking`; neutral 1x protection exits before analyzer/math work; crossfeed/crosstalk/symmetry skip neutral work; disabled inter-channel alignment skips delay/all-pass reads while retaining only bounded warm-history writes for future click-free enable; meters are explicit opt-in and default OFF. FIR EQ, room correction, Speaker IR and crossover were audited and already gated correctly. | COMPLETE |

## Closure findings

### Realtime callback ownership

The render kernel acquires one immutable graph generation for the output callback. Large nested Dynamics / Dynamic EQ configuration no longer moves by value through the per-frame call chain. Startup and graph-transition gain ramps also no longer use atomics as their per-sample state machine: the control plane publishes sequence-protected commands, the callback latches them at a bounded point, advances local ramp state for the buffer, then publishes bounded transition state afterward.

### Disabled-stage contract and baseline cost

Manual smoke testing before merge showed that the app could consume roughly one CPU core even with no audible EQ or Dynamics processing enabled. The same result reproduced in the PR34 test build, establishing that this was an inherited baseline-cost issue rather than a regression from PR35.

The source audit found a concrete cause: several feature toggles were audio bypasses rather than computational bypasses. A disabled spectral denoiser still buffered audio, performed forward FFTs, noise-profile analysis, spectral gain work, inverse FFTs and overlap-add before discarding the processed path. Disabled Dynamics stages likewise continued filter/detector/transcendental work while their audible contribution sat at or converged toward neutral.

PR35 formalizes the product contract as **Active → Transitioning → Parked**. A feature that is OFF may finish its short click-free disable tail, then stops its algorithmic realtime work. Persistent settings remain in the immutable configuration snapshots, so toggling a compressor, EQ processor, denoiser, spatial control, or similar feature does not erase the user's settings. Where stale signal-history state could cause a re-enable artifact, only that transient realtime history is reinitialized; configuration is not reset.

The contract was then applied beyond the first two expensive findings. Master-disabled Dynamic EQ now parks even when bands remain configured. Mains-hum analysis follows the explicit continuous-tracking control instead of being silently enabled. Neutral 1x protection no longer acts as an implicit true-peak analyzer when clipper and limiter are off. Speaker crossfeed, symmetry and crosstalk-cancellation math park at their neutral states. Inter-channel alignment skips delay reads/all-pass math when disabled; it retains only inexpensive history writes so a future enable can remain click-free. Main FIR EQ, room correction, Speaker IR and crossover were audited and were already correctly gated around their enabled states.

This is an architectural inactive-path correction, not a claim about final CPU targets. The GitHub workflow is a Debug build, which magnifies scalar FFT/transcendental cost, and production Release profiling remains part of the later measured campaign. The important PR35 contract is that optional DSP no longer burns its enabled-path cost merely to return dry/unity output.

### Meter and analyzer gating

The current product does not yet expose graphical meters, so there is no reason to pay their sample-rate accumulation cost by default. PR35 adds a graph-level metering gate that defaults OFF. Input/post-EQ/output peak and RMS accumulation, plus meter publication, now occur only when metering is explicitly requested. This preserves the efficient callback-end atomic publication model for the future UI without making meter processing a permanent baseline cost.

The same principle applies to future RTA/spectrum/analyzer UI: configuration may persist, but analysis work should be explicitly requested and independently gateable rather than silently hot in every render graph.

### Control/UI boundary

The production UI can now issue ordinary graph changes without making the MainActor wait for an inactive render slot. Running-transport publications are serialized on a dedicated control-plane queue and redundant pending ordinary updates collapse to the newest complete graph. Structural changes preserve fade-down/publish/fade-up semantics, but the wait to the fade midpoint occurs on the publication worker rather than through caller-thread `usleep` choreography.

The coordinator exposes counts for graph publications, failed publications, coalesced updates and structural transitions. Combined with underrun/overrun, buffering and render diagnostics, these are intentionally lightweight readiness hooks—not a substitute for the later measured performance campaign.

### Prepared FIR generation safety

The convolution engine intentionally provides three program slots. Two immutable render-graph generations may keep two slots live while the control plane prepares the third. PR35 keeps that contract explicit: a structural transition is registered before its caller returns, and another main-EQ/room-correction/Speaker-IR program cannot be prepared until the in-flight structural generation is published. This avoids trading MainActor responsiveness for a prepared-resource lifetime race.

### Reset work on graph activation

Large protection and denoiser backing arrays are no longer indiscriminately cleared during callback-side activation when logical indices/generation state already make the old contents inactive. The retained equivalence validators exercise dirty-reset/fresh-runtime behavior, denoiser quality changes, and the denoiser prevalidated fast path.

## Retained closure validation

The normal macOS workflow retains the PR34 Band Pass DSP validator and PR35 checks for:

- realtime/control-plane architecture invariants (callback-local ramp state, no interactive `usleep`, publication worker/coalescing, and prepared-FIR transition serialization);
- source-level optional-stage parking invariants, including explicit mains tracking, meter gating, Dynamic EQ parking, neutral protection, spatial parking, alignment parking and FIR/crossover gating;
- protection sparse-reset equivalence;
- denoiser bounded-reset equivalence across 44.1/48/96/192/384 kHz;
- denoiser prevalidated-fast-path equivalence across 44.1/48/96/192/384 kHz;
- disabled-DSP parking/sample-transparency across 44.1/48/96/192/384 kHz, including zero denoiser spectral frames, no hidden mains-detector advancement, configured-but-disabled Dynamic EQ parking, and neutral-protection no-analysis behavior;
- runtime meter gating: default-off graphs keep meter readings dormant and explicit enablement produces readings;
- render-context pinned-snapshot lifetime;
- normal arm64 macOS build and XCTest.

## Deferred measured phase

The exhaustive performance campaign remains intentionally deferred until the production UI and near-term product layers exist. That later campaign will establish repeatable baselines at 48/96/192/384 kHz and representative/worst-case graphs, including heavy EQ/Dynamic EQ, high-order slopes, Linear/Mixed Phase, simultaneous FIR workflows, denoiser modes, 4x protection, bass management, full stereo processing, explicitly enabled meters/RTA/UI update load and actual transport/device behavior.

The primary measurement-driven candidates carried forward are convolution/vectorization/FFT strategy, Dynamic EQ hot math, denoiser transform/vectorization, and—only if graph-publication counters show meaningful pressure—deeper publisher buffering/nonblocking changes. Those items are deliberately not presented as performance wins until measured in the production application.
