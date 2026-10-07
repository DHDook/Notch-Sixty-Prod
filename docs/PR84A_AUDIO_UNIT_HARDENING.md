# PR84A — Automated Audio Unit Hardening

PR84A is the deterministic, CI-testable half of Audio Unit qualification. It hardens the PR79–83 host before real-machine qualification in PR84B.

## Safety invariants

1. Untrusted Audio Unit state is size-bounded and must decode as a binary/property-list dictionary before it can reach a plug-in.
2. Offline preparation reports are treated as untrusted evidence. Render metrics, state evidence, latency, tail, channel counts, and resource teardown must all be internally coherent.
3. A failed mutation candidate never alters the committed rack, preparation evidence, quarantine registry, or currently playing generation.
4. Live render faults fail closed to the latency-matched dry path and are reported to the control plane.
5. Latency or tail drift after live activation is a control-plane fault. It must never silently invalidate rack timing assumptions.
6. A runtime reports a given post-activation drift once per slot/generation so quarantine accounting cannot runaway.
7. Clearing quarantine never restores stale preparation evidence; the component must pass fresh preparation before processing again.
8. Hardening logic remains off the realtime callback. No AU property queries, allocation, locks, logging, dispatch, or serialization are added to render.

## Deterministic abuse matrix

PR84A covers:

- malformed property-list state
- non-dictionary property-list state
- per-slot and whole-rack state size bounds
- instantiation failures
- format/resource-allocation failures
- render status failures
- non-finite render output
- unstable latency across reset
- unstable tail across reset
- leaked render resources
- inconsistent/off-spec preparation reports
- live-build latency mismatch
- live-build tail mismatch
- post-activation latency drift
- post-activation tail drift
- repeated fail → quarantine → clear → fresh-prepare cycles
- mutation failure atomicity
- sample-rate permutations at 44.1, 48, and 96 kHz
- symmetric mono, stereo, 5.1-class (6-channel), and 7.1-class (8-channel) test formats
- repeated preparation/mutation stress cycles

## PR84B boundary

PR84A does not claim third-party compatibility from CI alone. PR84B is the later physical-Mac qualification pass covering installed AUv2/AUv3 plug-ins, real vendor UI behavior, device changes, real hardware formats, and listening/soak verification.
