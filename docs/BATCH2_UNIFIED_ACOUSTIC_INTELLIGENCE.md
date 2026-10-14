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
- Swift XCTest covers deceptive average wins, uncertainty-sensitive
  improvements, a strong multi-seat hypothesis, missing coherent
  subwoofer hardware/timing at 384 kHz, malformed inputs and project
  mismatch. Fast source/UI ownership contracts run on Ubuntu; Apple
  Silicon integration is a deliberate checkpoint.

## Remaining work IN THIS SAME BATCH

- Connect the coordinator to selected Room Advisor / Speaker Optimizer /
  subwoofer evidence in the real read-only production workspace.
- Add deterministic repeat-noise, timing perturbation, seat-weighting and
  held-out-seat robustness using the PR117 synthetic reference principles,
  without presenting simulated confidence as measured precision.
- Add multi-objective trade-off tables: seat response spread, modeled
  target error, sub headroom, phase/coherent-clock evidence, latency,
  complexity and route feasibility. Require independent physical outputs.
- Add guidance for actionable measurement, placement and treatment before
  proposing bounded DSP designs; any Apply path remains separately gated by
  the existing authoritative commissioning controllers.
- Finish with one deliberately triggered Apple Silicon Debug/Release/full
  XCTest integration gate and machine-readable evidence. No unverified
  runtime graph modifications, and no release or hardware authority.

## Efficiency and approval

A single Batch 2 PR uses logical commits and cheap per-commit source guards.
Only deliberate integration checkpoint(s) should run expensive Mac CI.
The Batch 1 exact-head full integration gate is not a substitute for
validating changes to Batch 2's shipping Swift source. Both branches remain
OPEN/DRAFT/UNMERGED and the owner retains physical PR112 approval.
