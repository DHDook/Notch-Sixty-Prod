# Batch 2 — Unified Acoustic Intelligence

**Active consolidated Batch 2:** scopes PR118 (unified intelligence), PR119
(calibration uncertainty), and PR121 (multi-objective bass) in a **single**
draft PR. The whole batch is based on Batch 1 rather than creating a new PR
for each implementation slice.

## First implementation increment

The new owner-authored
NotchSixty/Audio/UnifiedAcousticIntelligenceCoordinator.swift consumes
existing *real product* RoomTreatmentAdvisorReport,
SpeakerOptimizerComparisonPlan and
CoherentMultiSubwooferAlignmentCandidate types. It does **not** add a new
measurement engine, second optimizer, independent correction curve authoring
system, or hardware execution path.

Its first responsibility is safe evidence arbitration, **not** automatic
acoustic optimization:

- Reject a Room Advisor report for a different project.
- Speaker correction requires matching explicit selected Measurement Set,
  Playback System, routing signature and sample rate; no unbound
  source-specific candidate silently inherits another setup.
- Multi-Sub coherent timing requires matching device and route identity,
  independently addressable Subs, and the existing planner's acceptance.
- Poor quality/missing multi-seat evidence blocks DSP-domain confidence.
- Preserve and independently display candidate headroom and worst-seat
  regression flags; do not invent one cross-domain ranking score from
  incomparable objective functions.
- Rank additional measurements and physical placement/treatment remedies
  before DSP/multi-sub actions; source reports remain independently owned.
- The resulting report and every recommendation have **canApply=false**
  and **canDeploy=false**. It may not change active EQ, FIR, routing,
  crossover, volume, protections, driver calibration or live ANC.

The existing Room Advisor XCTest file includes focused cases for
physical-first priority, project mismatch and single-seat DSP blockers.

## Current increment — real Room Advisor integration + bounded uncertainty

- The shipping Room Advisor workspace now calls the coordinator on its
  **actually selected project report** and shows ordered physical-first
  read-only advice, data-quality warnings and per-proposal blockers.
  It does **not** synthesize a Playback System or insert unbound
  Speaker Optimizer / Sub measurements. Those will appear only when the
  existing measurement and routing identity can be verified.
- A new deterministic UnifiedAcousticRobustnessEvaluator accepts
  candidate residuals per listening seat, independently declared positive
  weights, rate up to **384 kHz**, measurement uncertainty bounds,
  headroom requirements, fixed processing delay, and—when comparing
  multiple Subs—independent physical outputs and a coherent clock.
- An improvement in weighted nominal error **cannot override** one seat's
  potential target-error regression, conservative latency/headroom budgets,
  or a confidence failure from measurement uncertainty. The model
  independently pessimizes baseline and after residuals within the
  supplied error bound. It does not derive statistical confidence or
  modify active EQ/crossovers/delay.
- The robustness evaluator supports **held-out listening seats**: reserved
  seats are excluded from the weighted fit but must satisfy independent
  target-error regression limits. Its conservative interval bound tests
  worst-case measurement error for both before and after. This is an
  offline mathematical review and not a measured confidence interval.
- The real Speaker Optimizer plan identity is now tested with matched
  and mismatched routes and sample-rate contexts. If that optimizer
  recommends **bypass**, the coordinator advises leaving that speaker
  uncorrected rather than marketing a DSP change as an improvement.
  Multi-Sub predictions keep a hardware/clock verification blocker.
- Swift XCTest covers deceptive average wins, uncertainty-sensitive
  improvements, a strong multi-seat hypothesis, missing coherent
  subwoofer hardware/timing at 384 kHz, malformed inputs and project
  mismatch. Fast source/UI ownership contracts run on Ubuntu; Apple
  Silicon integration is a deliberate checkpoint.

## Unified Batch 2 integrated closeout scope

**Live Room Advisor integration:** its new Acoustic Intelligence panel now
offers "Find baselines" and "Review selected baseline" with real, saved,
qualified Speaker Optimizer captures. The controller reads archives without
performing measurements, changing Playback System, or altering the DSP graph.
It excludes baselines from another Playback System, requires a valid 8–384
kHz sample rate and nonempty recorded route, and always asks the user to
select a source. Existing SpeakerOptimizerMeasurementEvidenceEvaluator and
SpeakerOptimizerCandidateComparisonDesigner are authoritative: rejected
baseline evidence produces an explanatory message, not a fabricated curve.

**Cross-domain evidence ownership:** the selected baseline supplies the
exact route, sample rate, microphone, measurement set and Playback System
for the coordinator to verify against the existing speaker proposal.
Changing the source clears the old proposal. The Room Advisor report is
its own selected project evidence; merely matching Playback System does
NOT make the room capture and speaker capture contemporaneous or a
common repeat-measurement series. If bypass ranks first, advice explicitly
recommends no correction.

**Physical bass outcomes:** the coordinator and UI consume
RoomAdvancedSubPlacementComparison only after the existing physical
placement analyzer has authenticated before/after measurement IDs,
unchanged signal-chain attestation, identical seat IDs, repeated quality,
route and playback system. The displayed number is *measured relative
35–160 Hz inter-seat variation*, not a target response, SPL, acoustic
decay, amplifier headroom, or coherent multi-sub timing claim. Other
objectives remain identified as unavailable.

**Full multi-objective review:** UnifiedAcousticBassTradeoffEvaluator is
an immutable read-only Pareto reviewer for comparable source-authenticated
bass scenarios. Its independent axes are seat spread, target RMSE, decay,
headroom cost, added latency and filter complexity; never a secretly
weighted "best bass" score. It refuses inconsistent playback systems,
routes, rate, evidence set IDs or nonfinite inputs; warns about missing
independently addressable Sub outputs, common-clock coherence,
headroom >3.5 dB, and additional latency >30 ms. Scenario values are
hypothetical until a producing measurement/optimizer workflow can supply
qualified quantities for all axes. No scenario is silently generated
from a spread-only placement comparison.

**Uncertainty and held-out seats:** the per-seat candidate reviewer
distinguishes modeling a correction on training seats from evaluating
unfitted held-out seats. Bounded errors apply separately before/after.
It fails closed for high-rate invalidity, noise-sensitive nominal wins,
regressed seats, excessive headroom or A/V latency, noncoherent
multi-sub source mapping, or absent independent outputs. Its supplied
uncertainty in dB MUST come from a separately qualified measurement
boundary; this method does not estimate actual microphone confidence.
No reviewed scenario is measured verification or a deployment permit.

**Coherent multi-Sub owner:** The existing
CoherentMultiSubwooferAlignmentPlanner retains phase-coherent timing,
independent physical output and protection authority. The coordinator
may display a signed candidate when explicitly supplied from that
workflow, but it **does not** generate new signed candidates from
mismatched room sweeps or set speaker delays. Hardware clock,
subwoofer output mapping, summed-response and acoustic verification
remain physical owner acceptance items.

**UI and tests:** the existing Room Advisor shows a single physical-first
sequence plus source-specific evidence and warnings, without adding a
sidebar or duplicate DSP engine. The Room Advisor and Speaker Optimizer
XCTest suites cover no-deploy, explicit identity, held-out-seat
regression, conservative uncertainty, rate-dependent latency and
multiobjective Pareto dominance/guard failures.

## Completion and authority

The final exact-head Apple Silicon Release build and cumulative XCTest
is required for Batch 2 software closure, following its fast source
contract. CI does not grant speaker-room acoustic performance, real
384-kHz DAC capability, coherent multi-Sub physical mapping, headphone
SPL, ANC authorization, or owner hardware PR112 H01–H08 acceptance.

Batch 2 stays in one OPEN/DRAFT/UNMERGED PR and must not touch main.

## Deferred physical workflow, not another software slice

No automatic DSP apply path, fabricated multi-Sub clock evidence or new
physical audio captures are needed to close the read-only software batch.
Owner-supervised PR112 hardware acceptance is separately outstanding.

## Efficiency and approval

A single Batch 2 PR uses logical commits and cheap per-commit source guards.
Only deliberate integration checkpoint(s) should run expensive Mac CI.
The Batch 1 exact-head full integration gate is not a substitute for
validating changes to Batch 2's shipping Swift source. Both branches remain
OPEN/DRAFT/UNMERGED and the owner retains physical PR112 approval.
