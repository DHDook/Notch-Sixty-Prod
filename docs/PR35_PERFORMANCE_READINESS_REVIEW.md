# PR35 DSP Architecture & Performance Readiness Review

Status: **ACTIVE — ARCHITECTURE/CODE REVIEW IN PROGRESS; FORMAL STRESS PROFILING DEFERRED.**

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
| PR35-001 | Dynamics / Dynamic EQ realtime API | `N60DynamicsSnapshot` (which embeds the two-lane 64-band Dynamic EQ snapshot) was passed by value through several realtime processing calls on every frame; Dynamic EQ was then copied by value again. | FIX NOW | Render-only processing APIs and internal core helpers now consume `const` snapshot pointers. Full retained DSP validators, build and XCTest passed before source commit. | COMPLETE |
| PR35-002 | Realtime output bridge | Startup and graph-transition ramps perform multiple atomic loads/stores per rendered sample even though ramp advancement is audio-callback-local work. | FIX NOW | Retain atomic command/publication state but latch/advance ramp runtime locally per callback; publish only bounded telemetry/state as needed. | OPEN |
| PR35-003 | MainActor graph transitions | `AudioIOEngine` is `@MainActor`, while structural graph transitions synchronously step a fade-down with repeated `usleep` calls before publication. This can visibly stall future UI interaction. | FIX NOW | Remove caller-thread sleep choreography; schedule transitions through bounded realtime/control-plane state without changing audible transition semantics. | OPEN |
| PR35-004 | Snapshot publication | The two-slot graph publisher waits with `sched_yield()` for the inactive slot's reader count. Safe for the audio thread, but synchronous UI/control-plane publication can block for a callback duration under rapid updates. | PREPARE NOW | Move/coalesce high-frequency publication off the MainActor; evaluate triple-buffer/nonblocking publication only if later measurements justify it. | OPEN |
| PR35-005 | Meter / telemetry publication | Peak/RMS and processor telemetry are accumulated in the render context and atomically published at buffer end rather than atomically updated per sample. | NO ACTION | Preserve the buffer-aggregated architecture; later UI should poll bounded telemetry rather than request per-sample publication. | REVIEWED |
| PR35-006 | Partitioned convolution | Realtime memory is preallocated and FIR preparation is off-thread; hot block work uses a scalar custom FFT and scalar complex partition MACs across up to three independent convolution engines. | BENCHMARK LATER | Profile production workload before choosing vDSP/Accelerate, SIMD MACs, shared-input-transform opportunities or partition-size changes. Preserve three independent workflows. | OPEN |
| PR35-007 | Domain-aware Dynamic EQ math | Active bands perform detector biquads plus `log10f`, optional `sqrtf`, gain conversion `powf`, smoothing and basis filtering at audio rate; dual-lane modes can double band work. | BENCHMARK LATER | Keep current numerically accepted behavior in PR35; evaluate vector/block processing or equivalent fast math only against later measured profiles and strict regressions. | OPEN |
| PR35-008 | Spectral denoiser | Runtime is preallocated but uses a custom scalar spectral engine up to 4096-point FFTs; likely high-value vector/Accelerate candidate. | BENCHMARK LATER | Complete architecture/realtime review now; defer transform/vectorization choices until the final production workload is profiled. | OPEN |
| PR35-009 | Render-kernel documentation | A stale comment described Dynamic EQ as linked physical stereo and said Mid/Side lacked independent dynamic detectors, contradicting the accepted PR34 domain-aware design. | FIX NOW | Corrected with PR35-001 so maintenance decisions reflect the current contract. | COMPLETE |
| PR35-010 | Protection runtime reset | `N60ProtectionRuntimeReset()` clears the entire protection runtime with `memset`. The runtime owns four 32,769-entry limiter/deque arrays, so structural protection changes can clear hundreds of kilobytes when the new graph is first prepared on the audio callback. | FIX NOW | Convert reset to a logical reset: clear active FIR/filter/runtime indices, gain state, deque head/count and telemetry, but do not clear inactive delay/deque backing arrays. Prove dirty-then-reset behavior is equivalent to a fresh runtime over a sequence longer than look-ahead. | IN PROGRESS |
| PR35-011 | Render-generation preparation | `prepare_runtime_for_snapshot()` executes when a new graph generation is first observed on the callback. After large-state resets are removed, the remaining work is bounded state comparison/transition scheduling, but the ownership boundary should remain under review as UI update frequency increases. | PREPARE NOW | Keep callback activation bounded; move expensive preparation into prepared control-plane resources and revisit only if UI/update-load measurements show pressure. | OPEN |

## Initial architectural observations

### Realtime snapshot ownership

The render kernel acquires one graph snapshot per output callback and keeps that snapshot stable for the callback. PR35-001 removed the redundant downstream by-value copies of the large Dynamics/Dynamic-EQ configuration without changing graph ownership or DSP behavior. Verified source commit: `79c36c04cf0060e5e80d8146576fa8ed9e769cc1`.

### Protection reset ownership

Protection program configuration is designed off-thread, but structural protection changes can request a runtime reset during callback-side graph activation. The current full-runtime `memset` is disproportionate because the large delay/deque backing arrays are inactive after reset: the sequence counter, deque count and indices define validity, and delay slots are written before they become readable. PR35-010 replaces this with an O(1)-with-respect-to-lookahead logical reset while preserving fresh-runtime behavior.

### Telemetry

The existing meter design is appropriate for UI build-out: samples accumulate into callback-local peak/RMS state, and atomic publication occurs at render-buffer end. Production UI should consume this bounded telemetry model rather than introduce per-frame Swift/UI traffic.

### Control/UI boundary

The current double-buffer graph publication contract keeps the realtime reader lock-free, but `AudioIOEngine` is MainActor-isolated and structural transitions currently include caller-thread sleep choreography. This must be corrected before high-frequency production controls are layered on top; otherwise the DSP itself can remain glitch-free while the UI feels unresponsive.

## Deferred measured phase

The exhaustive performance campaign remains intentionally deferred until the production UI and near-term product layers exist. That later campaign will establish repeatable baselines at 48/96/192/384 kHz and representative/worst-case graphs, including heavy EQ/Dynamic EQ, high-order slopes, Linear/Mixed Phase, simultaneous FIR workflows, denoiser modes, 4x protection, bass management, full stereo processing, meters/RTA/UI update load and actual transport/device behavior.

PR35 may add lightweight instrumentation required to make that later campaign straightforward, but will not block UI work on completing it now.
