# PR109 — Remote Integration & Stack Consolidation

Status: **SLICE 1 IMPLEMENTED — EXACT-HEAD CI PENDING; HARDWARE ACCEPTANCE DEFERRED**

GitHub PR numbering is one ahead of the roadmap from PR99 onward: roadmap PR108
is GitHub #109; roadmap PR109 will be GitHub #110. PR109 is stacked directly
on the verified roadmap PR108 head `4bd34ea7414363f15b69405188ea41c2777717f6`.

## Intent and non-negotiable ownership boundary

PR109 follows the same remote-development pattern as PR101–108:
**leave existing pull requests open/draft/unmerged** while the owner is away
from the physical Mac/audio hardware. PR109 is not a request to merge, rebase,
squash, close, mark ready-for-review, deploy live speaker-connected ANC,
authorize App Store release, or waive real hardware/acoustic acceptance.

The core deliverable is reproducible integration evidence and a later,
hardware-gated integration handoff. PR109 can achieve *remote software closure*
without closing the pull request or claiming release readiness.

## Snapshot / initial risk inventory

Verified using GitHub's October 12, 2026 branch and PR metadata:

- `main` snapshot `0d0d0cbdf85ec799900ca782c80b1daf8d850ff6`;
- roadmap PR108 head `4bd34ea7414363f15b69405188ea41c2777717f6`;
- PR108 branch is **1,308 commits ahead of `main`, zero behind** at that snapshot;
- PR100–108 (GitHub #101–109) are **open, draft, unmerged**;
- the recent milestone checkpoints form an ordered ancestral chain;
- the two newest major unresolved evidence classes are real physical acoustic/
  hardware acceptance and production release credentials/review.

The GitHub compare API returned only its first 300 changed-file entries for
main→PR108. This is *not* a claim that the diff contains exactly 300 files;
no complete cumulative line-by-line integration audit is established by that
API response.

The main branch has no reviewed combined hardware proof for all post-v1
capabilities. Passing an xcodebuild on this cumulative head cannot substitute
for physical speaker/driver safety, independent-clock coherent measurements,
active ANC authorization, acoustics, thermal endurance or App Store approval.

## Slice 1 — Reproducible, read-only integration ancestry audit

Files:

- `ci/pr109_stack_manifest.json`: immutable checkpoint SHAs for the complete
  PR99–PR108 handoff and a documented `main` snapshot;
- `ci/validate_pr109_integration_stack.py`: verifies exact checkpoint IDs,
  contiguous roadmap ↔ GitHub PR mapping, commit existence, ancestry from
  `main` through PR108 into the PR109 checkout, and Slice 1's allowed-file
  boundary. It never mutates Git refs;
- `ci/tests/test_pr109_integration_stack.py`: negative tests for missing,
  duplicate, reordered, malformed and unauthorized milestone evidence;
- `.github/workflows/pr109-integration-stack.yml`: read-only CI checkout
  with full history; inherited safety/release/measurement structural guards;
  arm64 Debug and unsigned Release build; full XCTest regression; upload only
  a machine-readable **remote stack audit** artifact.

The manifest deliberately hard-codes:

- `hardwareAcceptanceComplete: false`
- `releaseAcceptanceComplete: false`
- `mayMergeIntoMain: false`
- `liveFeedForwardANCAuthorized: false`

Those values are hard-gated, not derived from successful CI. All application,
DSP, audio transport, calibration state, and existing PR branch heads remain
untouched by PR109 Slice 1. A valid read-only report carries only Git ancestry
and source/test evidence, never hardware authority.

### Acceptance

Slice 1 remains **pending** until its own exact-head push/PR CI completes:
the manifest and negative tests, all applicable inherited guard scripts,
arm64 Debug/Release builds, and full XCTest must pass. Record exact commit,
runs, failing/passing jobs, and any required fixes in this document.
Do not call the PR remotely complete based on source changes alone.

## Follow-on PR109 work — still remote/software-only

1. Review integration contracts across transport, N-channel lane routing, FIR
   and PEQ ownership, room correction, active crossover/driver protection,
   microphone/reference evidence and Active Acoustics authorization.
2. Audit product persistence and migrations, bundled notices, sandbox/App Store
   constraints and all required test registrations as one cumulative product.
3. Identify overlapping stages or feature flags and create deterministic
   integration regression tests. Keep invasive changes to separate safe slices.
4. Prepare a precise future sequential merge and physical test order as a
   *handoff only*. Preserve feature branch ancestry and all existing drafts.
5. After exact-head cumulative CI, record PR109 remote/software closure with
   genuine hardware/release acceptance explicitly unresolved.

## Later approved sequencing / provisional numbering

- PR110 — advanced speaker and subwoofer placement optimization;
- PR111 — automatic per-driver correction / acoustic integration;
- PR112 — hands-on physical hardware and acoustic acceptance;
- PR113 — final production UX and workflow polish;
- PR114 — commercial release-candidate preparation.

PR110/111 can be developed and tested remotely on top of the PR109 branch
while the Mac is unavailable. PR112 genuinely requires connected representative
hardware; PR114 ultimately requires production credentials/review.

## Realtime, provenance, licensing and release

This slice changes **no runtime audio code** and introduces **no dependency**.
The snapshot and validator are original, read-only repository audit utilities.
No GPL-derived historical implementation material was consulted or imported.
No new entitlements, sandbox capabilities, signing keys, App Store Connect
credentials, automation that updates `main`, or external services are added.

## Deferred physical acceptance and eventual merge

When the owner returns to the Mac, perform PR101–108 physical checklists
(including driver protection, DAC/ADC clocks, mic calibration, acoustics, ANC
hardware gates, release checks). Review the entire branch stack and release
credentials before choosing an explicit, sequential merge plan. **Neither this
document nor successful PR109 CI authorizes merging a draft PR.**
