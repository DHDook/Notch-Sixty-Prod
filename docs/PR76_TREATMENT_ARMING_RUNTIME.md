# PR76 — Room-Treatment Arming, Fault, and Latency-Matched Transition Substrate

## Purpose

PR76 builds the **standalone activation-control substrate** for the PR74 MIMO FIR runtime without connecting it to the production speaker path.

It answers four questions that must be solved before live integration:

1. How can treatment arm/bypass without a timing discontinuity?
2. How does any confidence/protection fault return safely to untreated playback?
3. How is PR75 hardware/acoustic acceptance bound to the exact FIR program?
4. What latency must a future live transport publish while this subsystem is provisioned?

PR76 does not connect treatment to Core Audio, `AudioIOEngine`, `N60LiveNChannelRenderCore`, bass management, or physical outputs.

## Latency-matched identity path

A naive treatment bypass would switch between:

- untreated audio with essentially no treatment latency, and
- a 4096-tap treatment FIR with 2048 frames causal delay plus 256 frames partition latency.

That would create a large timing jump and make click-free crossfade impossible.

PR76 therefore creates a second immutable **identity FIR program** with:

- the same channel count;
- the same tap count;
- an exact diagonal impulse at the treatment program's declared delay;
- the same 256-frame partition engine.

Both identity and treatment runtimes process every frame continuously.

When treatment mix is 0%, output is the latency-matched identity path.
When treatment mix is 100%, output is the treatment path.

For the default PR74 program the published subsystem latency is always:

- 2048 declared FIR frames;
- 256 engine frames;
- **2304 total frames (~48 ms at 48 kHz)**.

A future live integration may choose not to provision this subsystem until playback restart/graph rebuild, but once provisioned it cannot remove that latency merely because treatment is bypassed.

## PR75 activation permit

`MIMORoomTreatmentActivationPermit` is the product-side control-plane proof object.

It can only be produced by a factory that re-evaluates:

- every PR75 physical-source safety declaration;
- accepted repeat-measurement verification;
- complete real-hardware acceptance;
- source count and identity;
- sample-rate agreement.

The permit factory additionally validates the exact PR74 FIR artifact:

- 1–4 treatment sources;
- power-of-two tap count from 512 through 4096;
- half-FIR declared causal delay;
- 256-frame engine latency;
- finite and correctly-sized tap matrix;
- PR74 edge-energy limit;
- PR74 realized coefficient overshoot limit;
- PR74 realized column-power limit;
- PR74 realized physical-source-power limit.

Therefore a forged or manually constructed unsafe FIR object cannot obtain a permit merely by presenting a successful PR75 gate result.

A permit contains no method that starts audio or publishes a realtime graph.

## Standalone transition runtime

`N60MIMOTreatmentTransitionRuntime` owns:

- one latency-matched identity FIR runtime;
- one treatment FIR runtime;
- immutable normal/fault fade lengths;
- lock-free authorization/request/fault atomics;
- internal transition state;
- lock-free published diagnostics.

All transition atomics are required to be lock-free at creation. Creation fails otherwise.

### States

- `Bypassed` — identity path, treatment mix 0.
- `Arming` — smoothstep fade identity → treatment.
- `Active` — treatment mix 1.
- `Disarming` — smoothstep fade treatment → identity.
- `FaultFading` — shorter smoothstep fault fade to identity.
- `Faulted` — identity path, treatment mix 0, latched fault.

### Fault classes

The bounded fault vocabulary includes:

- authorization revoked;
- acoustic measurement invalid;
- protection fault;
- physical source unavailable;
- treatment runtime failure;
- identity runtime failure;
- emergency stop.

External faults are atomically latched.

Only the first pending fault wins until it is consumed.

## Fail-closed behavior

Normal protection/measurement/source faults fade treatment to the latency-matched identity path.

A treatment-runtime failure immediately uses the identity result and latches a hard fault.

An identity-runtime failure is more severe because the latency-matched safe path is unavailable. PR76 outputs zero for that frame, latches the hard fault, and reports failure.

A fault cannot be cleared while an arm request remains asserted. The caller must request bypass and then explicitly request fault clear.

Reset is control-plane only and:

- resets both FIR histories;
- returns to Bypassed;
- clears faults;
- revokes authorization;
- requires explicit re-authorization before another arm request.

## Authorization revocation

Authorization is a live lock-free input to the standalone transition runtime.

If authorization is revoked while treatment is arming, active or disarming, the runtime latches `AuthorizationRevoked` and enters the shorter fault fade to identity.

Revocation while already bypassed does not add treatment and does not create an unnecessary fault.

## Realtime contract

`N60MIMOTreatmentTransitionProcessFrame`:

- runs both preallocated FIR runtimes;
- performs bounded arithmetic and lock-free atomics;
- uses fixed stack arrays for at most four channels;
- performs no allocation/free;
- performs no blocking lock;
- performs no logging;
- performs no file/network I/O;
- performs no device discovery;
- performs no trigonometry;
- performs no filter construction.

Program/runtime creation, identity FIR construction, allocation and reset remain control-plane operations.

## Warm-state rule

Identity and treatment FIR histories stay warm even while bypassed.

This ensures that an arm request does not begin with an empty treatment FIR history and does not inject a startup transient simply because treatment had previously been disabled.

The cost is intentionally conservative: both matrix FIR engines remain computationally active while the standalone subsystem is running. PR76 benchmarks this dual-runtime worst case.

## Transition defaults

The C reference defaults are:

- normal arm/bypass fade: 2048 frames;
- fault fade: 512 frames.

The Swift control-plane default expresses these as approximately:

- 40 ms normal fade;
- 10 ms fault fade,

converted to bounded frame counts at the active sample rate.

No fade may be zero frames or exceed the bounded maximum.

## Diagnostics

The lock-free transition snapshot publishes:

- state;
- latched fault;
- authorization;
- arm request;
- treatment mix;
- channel/tap counts;
- declared, engine and total latency;
- normal/fault fade lengths;
- processed frames;
- arm/bypass/fault requests;
- completed transitions;
- hard runtime failures.

A future Transport UI may expose these values only after actual live integration.

## Validation

Portable C simulation covers:

- unauthorized arm rejection;
- latency-matched identity warmup;
- exact normal arm fade;
- exact bypass fade;
- protection fault fade to identity;
- explicit fault clear behavior;
- authorization revocation while active;
- fault while already bypassed never adds treatment;
- reset revokes authorization;
- lock-free atomics;
- hard-failure telemetry remaining clear in normal operation;
- dual 4×4 / 4096-tap transition CPU regression.

Swift/XCTest covers:

- permit denied without complete PR75 evidence;
- permit issued only with complete PR75 safety, verification, and hardware evidence;
- forged unsafe FIR diagnostics rejected;
- forged latency metadata rejected;
- standalone permitted transition warmup/arm behavior;
- authorization-revocation fail-to-identity;
- permit/program mismatch rejection;
- fade-time → bounded-frame conversion.

CI retains PR75 and PR74 guards, builds the arm64 app, runs dedicated PR76 tests and the complete retained XCTest suite.

## Explicit non-goals

PR76 has no user-facing enable button and cannot activate physical treatment output.

PR76 does not:

- connect the transition runtime to `AudioIOEngine`;
- connect it to `N60LiveNChannelRenderCore`;
- write treatment output to any Core Audio device;
- persist an armed/enabled treatment state;
- provide a user-facing Enable button;
- claim real hardware acceptance has occurred;
- change bass-management/protection ordering;
- implement adaptive ANC/FxLMS;
- remove the need for real-Mac acoustic acceptance.

## Future live-integration boundary

A later live-integration PR may reuse this substrate only after real hardware acceptance.

That future PR must still define and validate:

- exact insertion point relative to bass management;
- physical-source mapping;
- final limiter/true-peak/protection ordering;
- published 2304-frame default treatment latency;
- graph rebuild/restart semantics when provisioning treatment;
- real CPU/thermal budget with the complete production graph;
- underrun/fault behavior on actual hardware;
- A/V synchronization impact;
- repeat-measurement workflow after guarded audition.

PR76 itself remains non-actuating.

## Provenance

PR76 is clean-room proprietary work using Notch Sixty's proprietary PR74 FIR runtime and standard latency-matched crossfade/state-machine techniques. It adds no third-party DSP dependency, private API, driver, helper process, entitlement or network dependency.
