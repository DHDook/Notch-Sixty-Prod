# Commercial Roadmap

## Phase 1 — repository/Xcode bootstrap
- create virgin macOS SwiftUI application in Xcode
- new bundle identifier and signing configuration
- App Sandbox enabled immediately
- add unit-test target
- establish CI build/test

## Phase 2 — production AudioIO foundation
- device enumeration/selection
- permission UX
- device-scoped process tap
- private aggregate/tap input
- selected physical output
- realtime bridge
- diagnostics
- explicit lifecycle state machine
- sample-rate monitor/rebuild
- selected-device disconnect/reconnect
- sleep/wake
- graceful Stop/Quit

Exit gate: production code reproduces the POC transport acceptance behaviors through available rates up to 384 kHz.

## Phase 3 — render kernel + graph infrastructure
- RenderKernel
- DSPGraphSnapshot
- atomic graph/state publication
- latency model
- stage bypass model
- meters

## Phase 4 — clean foundational DSP
- input/output gain
- biquad EQ from public equations
- HPF/LPF
- crossover
- master bypass
- deterministic reference-vector tests

## Phase 5 — advanced DSP provenance/audit
For each advanced historical capability, decide reuse/rewrite/redesign based on provenance and quality:
- FIR/convolution
- linear phase
- mixed phase
- room correction
- multi-seat averaging
- bass management
- dynamics
- oversampling
- SRC if retained as an explicit feature

## Phase 6 — application state/persistence
- compact product-specific state model
- presets
- migrations
- device preferences
- configuration persistence

Do not recreate historical `EqualiserStore` or inherited routing hierarchy.

## Phase 7 — UI
Build UI on stable engine APIs. Prioritize responsiveness and explicit control-state feedback.

## Phase 8 — production hardening
- Instruments profiling
- leak/allocation analysis
- worst-case DSP CPU tests
- sample-rate matrix
- device lifecycle matrix
- long soak tests
- crash/termination behavior
- accessibility

## Phase 9 — distribution
- App Store signing/entitlements
- TestFlight
- SBOM/third-party notices
- provenance audit
- targeted open-source/IP counsel review
- App Review submission
