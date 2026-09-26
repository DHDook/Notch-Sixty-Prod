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

## Deferred measured phase

The exhaustive performance campaign remains intentionally deferred until the production UI and near-term product layers exist. That later campaign will establish repeatable baselines at 48/96/192/384 kHz and representative/worst-case graphs, including heavy EQ/Dynamic EQ, high-order slopes, Linear/Mixed Phase, simultaneous FIR workflows, denoiser modes, 4x protection, bass management, full stereo processing, meters/RTA/UI update load and actual transport/device behavior.

PR35 may add lightweight instrumentation required to make that later campaign straightforward, but will not block UI work on completing it now.
