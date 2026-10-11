# PR103 — Speaker Optimizer Measurement Foundation Remote Closure

Status: **PENDING EXACT-HEAD CI**

PR103 is eligible for remote/software closure only after its exact branch head
passes the complete PR103 workflow, including the full XCTest regression.

## Remote scope completed

PR103 establishes the measurement foundation only. It does not design or deploy
optimizer corrections.

The remote implementation now includes:

- explicit baseline / candidate / verification evidence roles;
- compact analyzed repeated-sweep evidence with no raw sweep persistence;
- fail-closed confidence from SNR, magnitude repeatability, arrival stability,
  phase consistency, usable-band continuity and capture identity;
- safe reuse of the existing targeted speaker/subwoofer calibration transport;
- explicit refusal to use that direct physical-output transport for protected
  Low/Mid/High driver buses;
- blocking when active split-driver routing or enabled per-driver limiter
  protection would be bypassed;
- deterministic one-microphone position-major session orchestration;
- interruption/resume and explicit repeat-retry behavior;
- versioned compact persistence;
- a real Speaker Optimizer baseline measurement controller reusing the existing
  sweep transport and acoustic analyzer; and
- SYSTEM → Speaker Calibration UI for progress, next measurement, confidence,
  diagnostics and blocker visibility.

## Required exact-head automated gate

The closing branch head must pass:

- PR103 structural contract validator;
- inherited PR102 release-readiness contract;
- inherited disconnected feed-forward safety audit;
- arm64 Debug application build;
- targeted Speaker Optimizer measurement tests;
- retained calibration prediction/analyzer regressions; and
- the full XCTest suite.

## Remote closure does not establish

Even after exact-head software closure, remote CI cannot establish:

- real measurement-microphone calibration accuracy;
- real loudspeaker/subwoofer/driver acoustic response;
- real ambient-noise or room conditions;
- real electrical/speaker safety;
- real crossover-preserving protected-driver excitation;
- real measurement repeatability on the production system; or
- measured effectiveness of later PR104 optimization.

Protected driver-bus measurement therefore remains unavailable rather than
using a raw physical-output bypass.

## Boundary to PR104

PR104 may consume only PR103 evidence that reports `optimizerReady == true`.
Prediction or synthetic tests must never be labeled measured verification.

PR104 owns optimization/candidate design. PR103 owns measurement evidence.
