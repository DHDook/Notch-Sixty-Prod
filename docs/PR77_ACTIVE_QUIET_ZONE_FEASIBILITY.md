# PR77 — Active Quiet Zone Causality and Feasibility Planner

## Purpose

PR77 begins the true environmental-noise-cancellation branch with a deliberately passive question:

> Is the proposed microphone / actuator geometry physically causal and coherent enough to justify building an adaptive anti-noise controller?

PR77 does **not** generate anti-noise, adaptive coefficients, filtered-x output, or any live speaker signal.

This ordering is intentional. A mathematically correct FxLMS controller cannot cancel a disturbance that reaches the listener before the system has enough time to observe, process, reproduce, and acoustically propagate the counter-signal.

## Why PR74's room-treatment latency cannot simply be reused for ANC

The PR74/76 MIMO room-treatment path intentionally tolerates roughly 48 ms of latency because it controls Notch Sixty's own playback and can keep bypass/treatment paths latency matched.

Feed-forward environmental ANC has a different causality requirement.

The reference microphone must observe the incoming disturbance early enough to cover:

1. reference capture / buffering / scheduling;
2. controller/block processing;
3. digital output staging;
4. actuator / loudspeaker secondary-path propagation to the error microphone;
5. a safety margin for uncertainty.

PR77 therefore models Active Quiet Zone as a separate future low-latency control path.

## Causality contract

For a given reference microphone, actuator, and error microphone:

```text
required lead frames =
    reference-to-actuator processing latency
    + actuator-to-error acoustic arrival
    + causality safety margin

causality margin =
    measured reference lead
    - required lead
```

A negative causality margin is physically infeasible for feed-forward cancellation with that path.

A positive margin is necessary but not sufficient.

### Reference lead

`referenceLeadFrames` means:

> how many frames earlier the reference microphone observes the disturbance than the same disturbance reaches the error microphone.

This definition avoids hiding ADC/DAC assumptions inside a vaguely named path measurement.

### Secondary path

`commandToErrorArrivalFrames` means:

> digital actuator command to acoustic arrival at the error microphone.

A future measurement workflow must define this timing consistently and include the actual output-device / loudspeaker path used by the controller.

## Coherence

Reference lead is not useful if the reference signal does not predict the disturbance at the error microphone.

PR77 therefore requires measured magnitude-squared coherence versus frequency.

The conservative default threshold is **0.80**.

Instead of treating one high-frequency coherence failure as an all-or-nothing failure, PR77 finds the highest contiguous cancellation band beginning at the configured low-frequency floor for which coherence remains above threshold.

This can produce a narrower recommended band.

## Timing uncertainty ceiling

Clock / scheduling / path jitter becomes increasingly destructive as frequency rises.

PR77 uses the explicit timing-uncertainty relation:

```text
phase uncertainty = 360° × frequency × jitter seconds

timing-limited maximum frequency =
    allowed phase uncertainty / (360° × jitter seconds)
```

Default assumptions:

- 4 frames timing uncertainty;
- 20° maximum timing-phase uncertainty.

This is a feasibility bound, not a claim that a controller will achieve that frequency.

PR69–71 adaptive clock work is relevant because long-run capture/output drift must be controlled before a cancellation phase relationship can remain trustworthy.

## Spatial quiet-zone ceiling

Global cancellation becomes increasingly spatially fragile as wavelength shortens.

PR77 exposes a conservative **quarter-wavelength zone heuristic**:

```text
spatial ceiling ≈ speed of sound / (4 × quiet-zone radius)
```

With the default:

- speed of sound: 343 m/s;
- quiet-zone radius: 0.45 m;

the geometric ceiling is about 190 Hz, so the requested conservative 20–150 Hz band is not geometry-limited.

At a 1.0 m radius the same heuristic falls to about 85.8 Hz.

This is explicitly a planning heuristic, not a guarantee of uniform cancellation throughout a real three-dimensional room.

## Actuator headroom

Each actuator→error path carries a reserved-headroom declaration.

Default minimum: **6 dB**.

The feasibility planner does not interpret this as proof of excursion or thermal safety. PR75-style physical source safety and final protection are still required before live output.

The headroom value simply prevents a controller design from proceeding when the proposed actuator has no reasonable control reserve.

## Multi-reference / multi-actuator / multi-error behavior

PR77 evaluates every compatible:

`reference microphone × actuator × error microphone`

combination.

For each error microphone it chooses the feasible pair with:

1. highest recommended coherent band;
2. then largest causality margin;
3. then strongest coherence floor.

Every error microphone in the requested quiet zone must have at least one qualified pair.

If any error microphone is uncovered, the overall design is infeasible.

This is only a feasibility screen. A later MIMO filtered-x controller may use multiple references and actuators simultaneously rather than only the individually best pair.

## Conservative defaults

- requested band: 20–150 Hz;
- reference→actuator processing latency: 64 frames;
- causality safety margin: 32 frames;
- marginal extra causality reserve: 32 frames;
- timing jitter: 4 frames;
- allowed timing phase uncertainty: 20°;
- quiet-zone radius: 0.45 m;
- minimum magnitude-squared coherence: 0.80;
- marginal coherence reserve: +0.05;
- minimum actuator reserve: 6 dB;
- marginal actuator reserve: +1.5 dB.

These values are planning defaults. Real hardware measurements will replace assumptions before a controller is eligible for activation.

## Result states

### Infeasible

At least one error microphone has no path satisfying:

- non-negative post-safety causality margin;
- coherent band reaching the requested low-frequency floor;
- minimum actuator headroom.

### Marginal

The geometry is usable at some band but one or more conditions are close to the conservative boundary, for example:

- timing uncertainty lowers the maximum frequency;
- quiet-zone radius lowers the maximum frequency;
- measured coherence rolls off before the requested 150 Hz;
- causality reserve is small;
- coherence/headroom reserve is small.

### Feasible

Every error microphone has at least one path satisfying the complete requested band with meaningful reserve.

## Relationship to PR72–76

- **PR72 Ambient Analysis** estimates environmental residual noise.
- **PR73–76 MIMO Active Room Treatment** controls the room response to Notch Sixty's own playback and is now stopped behind hardware gates.
- **PR77 Active Quiet Zone Feasibility** evaluates whether true environmental feed-forward cancellation is physically plausible.

PR77 does not reuse PR74's high-latency room-treatment FIR path as an ANC controller.

## Validation

XCTest covers:

- strong lead/coherence/headroom supporting the full 20–150 Hz band;
- insufficient reference lead causing hard causality failure;
- a 1 m quiet-zone radius narrowing the band via the quarter-wavelength heuristic;
- timing jitter narrowing the phase-stable band;
- coherence roll-off producing a measured cancellation ceiling;
- every error microphone requiring qualified coverage;
- best reference path selection;
- invalid/non-monotonic coherence data failing closed.

CI also retains PR76 isolation/safety guards, builds arm64, and runs the complete XCTest suite.

## Explicit non-goals

PR77 does not:

- implement FxLMS;
- adapt any filter;
- generate anti-noise;
- open a microphone;
- create a Core Audio IOProc;
- write to a speaker or subwoofer;
- claim a quiet-zone attenuation value;
- claim whole-room silence;
- use PR74's 48 ms treatment path for feed-forward ANC.

## Next software step

If PR77 proves a proposed geometry feasible, the next remote-safe engineering step is a **strictly offline filtered-x adaptive-control simulator**.

That simulator should add:

- measured primary/reference relationships;
- measured secondary-path FIR models;
- bounded coefficient adaptation;
- leak / regularization;
- output effort bounds;
- convergence/divergence telemetry;
- deterministic fail-to-zero behavior;
- multi-reference / multi-error test cases.

Only after real microphone/actuator timing and secondary-path measurements exist should an adaptive controller be considered for live activation.

## Provenance

PR77 is clean-room proprietary control-plane analysis based on standard causality, coherence, wavelength, and phase-uncertainty relationships. It adds no third-party DSP dependency, private API, driver, helper process, entitlement, network access, or new microphone permission.
