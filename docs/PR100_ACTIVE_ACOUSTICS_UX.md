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


## Slice 3 — Consolidated diagnostics and blockers

The feed-forward commissioning card now presents one ordered **Diagnostics &
Blockers** view spanning the entire readiness chain. It distinguishes six
operator-visible dispositions: **RECORDED**, **DIAGNOSTIC PASS**, **ATTENTION**,
**BLOCKED**, **HARDWARE REQUIRED**, and **DISCONNECTED**.

The summary covers the one-microphone plan, the listener → upstream → listener
survey, concurrent HAL clock evidence, physical latency-path fields, causality
reserve, PR99 A/B/A acoustic verification, emergency shutdown verification,
and the live feed-forward speaker-output boundary.

A positive causality result is deliberately shown only as **DIAGNOSTIC PASS**.
It cannot collapse or satisfy the later physical gates. PR99 acoustic evidence
and real shutdown behavior remain **HARDWARE REQUIRED**, while live feed-forward
speaker output remains **DISCONNECTED**.

The model also reports an unresolved-item count and a state-sensitive headline.
This makes the next commissioning obstacle visible without introducing an arm
control, changing Core Audio, or converting caller-supplied records into
instrument authentication.


## Slice 4 — Guided PR99 A → B → A physical campaign

PR100 now exposes the physical verification sequence that PR99 requires as a
read-only commissioning guide rather than leaving it only in developer
documentation.

The card shows the three complete visits with the same movable microphone:

1. **A — primary listener:** independent OFF → TEST → OFF measurement;
2. **B — neighboring observer:** move the same microphone and repeat; and
3. **A — primary listener return:** return to the original location and repeat
   to expose position, source, or timebase drift.

The UX makes the evidence volume explicit: **9 independent source captures**
and **15 externally witnessed fault-shutdown measurements** across the three
visits. It also surfaces the coherent **20–150 Hz** verification range and the
**1.5 dB** primary repeatability ceiling used by the existing PR99 analysis.

Every row is marked as a future physical commissioning step. The model keeps
physical verification, instrument provenance authentication, and live-output
authorization false. The view cannot create captures, fabricate evidence, arm
ANC, or connect a speaker output.


## Slice 5 — Physical evidence visualization

PR100 now has a read-only **Physical Evidence** view capable of rendering a
real PR99 evidence package when one is explicitly supplied. Until that happens,
the production UI shows **AWAITING PHYSICAL CAMPAIGN** and does not invent demo,
predicted, or synthetic acoustic results.

For a digest-valid PR99 package, the view summarizes:

- integrated reduction at the first primary A position;
- integrated reduction at neighboring position B;
- integrated reduction after returning to primary A;
- the weakest integrated seat result;
- the weakest individual 20–150 Hz frequency result;
- primary OFF-baseline span;
- integrated A-return repeat difference; and
- worst single-band A-return difference.

A frequency-resolved curve plots the three A / B / A-return reduction traces.
Positive values represent lower coherent-band level during the experimental
condition. The graph is explicitly numerical evidence, not an instrument
authentication or a promise of broadband silence.

The provenance panel separately reports canonical-record SHA-256 integrity,
two-role review acknowledgement, instrument provenance, physical attenuation,
emergency hardware mute, and live-output state. A matching two-role review is
shown only as an acknowledgement; reviewer identity and the instrument remain
unauthenticated.

If the canonical SHA-256 package check fails, PR100 suppresses all acoustic
metrics and the curve rather than displaying potentially altered evidence.
Live ANC output remains **DISCONNECTED** in every state.
