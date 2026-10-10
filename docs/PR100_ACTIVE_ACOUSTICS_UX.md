# PR100 — Active Acoustics UX

## Purpose

PR100 turns the advanced Active Acoustics stack into a coherent operator-facing
experience without weakening any PR98 or PR99 safety boundary.

This first slice is deliberately **read-only** for feed-forward ANC
commissioning. It does not connect a speaker output, authenticate an instrument,
claim physical attenuation, verify an emergency hardware mute, or create a live
ANC authorization path.

## Slice 1 — Commissioning & Verification summary

The existing Virtual-Position Feed-Forward ANC card now includes a compact
**Commissioning & Verification** section that separates four concepts that were
previously spread across detailed diagnostics:

1. one-microphone calibration planning;
2. timing and causality diagnostics;
3. genuine physical evidence; and
4. live ANC output authorization.

The UI derives the first two states from the existing PR96/PR97 calibration and
causality model. Even a `physicallyPlausible` timing result is labeled only as
a **diagnostic pass**. Physical evidence remains **HARDWARE REQUIRED** and live
ANC output remains **DISCONNECTED**.

The summary also presents one next action appropriate to the current state:
prepare the one-mic plan, repair/complete timing evidence, or proceed to the
PR99 A/B/A physical campaign and independent hardware review.

## Fail-closed policy

PR100 is a presentation layer over the already fail-closed runtime and evidence
architecture. The UX model contains explicit false facts for:

- independently authenticated instrument evidence;
- physically verified attenuation;
- verified emergency hardware mute; and
- live ANC output authorization.

No UI path can flip those facts. No new Core Audio output API, render callback,
permission, or authorization primitive is added.

Speaker-connected ANC remains disconnected. PR99 remains the hardware-gated
physical verification stage and later release work must consume genuine,
independently reviewed measurements rather than infer readiness from UI state.

## Tests and CI

The first slice adds XCTest coverage proving:

- missing calibration cannot look timing-ready;
- a physically plausible causality result still requires physical verification;
- a non-causal result remains blocked; and
- no modeled UX state authorizes live output.

The dedicated PR100 validator also checks the existing Active Acoustics
workspace integration and inherits PR99 plus PR98 disconnected-output guards.

## Planned PR100 follow-on slices

The remaining remotely implementable UX work can build on this foundation:

- a guided microphone setup/commissioning flow using the existing runbook;
- consolidated live diagnostics and fault indicators;
- frequency-response/evidence visualization for PR99 seat results;
- clearer calibration/evidence history and provenance status;
- operator explanations for blocked, degraded, and unavailable states.

Actual acoustic measurements, real emergency shutdown validation, physical
stability testing, and speaker-connected feed-forward ANC stay hardware-gated.


## Slice 2 — Guided one-microphone setup progress

The feed-forward card now converts the existing calibration record into a
six-stage read-only progress view:

1. plan prepared;
2. first listener-A arrival recorded;
3. upstream-reference arrival recorded;
4. listener-A return recorded;
5. physical timing-path record supplied; and
6. concurrent HAL clock trace supplied.

Each row distinguishes **RECORDED** from **PENDING** and reports total progress.
The language is deliberately precise: recorded data means only that a software
record exists. It does not authenticate the microphone, trigger clock,
instrument, microphone geometry, latency endpoint, or acoustic result.

This makes the single movable-microphone workflow understandable before the
physical commissioning session while retaining the PR98/PR99 hardware gates.
