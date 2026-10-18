# Notch Sixty — Four-Batch Completion Plan

**Owner-approved working plan, October 14, 2026.**
This supersedes the *execution cadence*, not the safety requirements, of
the individual proposed roadmap milestones PR117–PR126.

## Why consolidate

The earlier design used a separate PR and GitHub Actions run per small
test, document or DSP patch, sometimes running both push and pull_request
jobs on the identical commit. We now work in **four broad, reviewable draft
integration batches**, each made up of logical commits and cheap targeted
developer checks. Each batch receives one deliberate exact-head full macOS
integration run after its internal work stabilizes, not once per micro-step.

The remaining numeric PR117A/B/C/D stack is preserved for historical
review and does not get merged, closed or squashed by adopting this plan.
We finish Batch 1 on the existing PR117D branch/draft PR #125 rather than
creating another micro-PR or modifying main.

## The four batches

| Batch | Roadmap scope | Definition of done |
| --- | --- | --- |
| 1. Acoustic Reference Closeout | PR117 plus PR117A–D | Unify golden reference evidence, 44.1/48 rate families through 384 kHz, active-crossover double-precision regression, FIR/headroom/spatial references, native generated SOFA import including delay; exact-head arm64 full software gate; physical acceptance explicitly remains separate |
| 2. Acoustic Intelligence | PR118 + PR119 + PR121 | One read-only coordinator for placement, measurement quality, correction conflicts and multi-seat/sub choices; independent held-out-seat checks, source timing/headroom constraints; no automatic unsafe Apply |
| 3. Headphone Completion | PR124 + bounded user-facing subset of PR125 | Per-ear 16-band PEQ editing and visualization, accurate native SOFA import/picker, explicit sample-rate mismatch/conversion policy, headroom and profile provenance; possible model proposals only after data/license validation |
| 4. Product Integration & Handoff | PR122 + PR123 | Optional safe ABX content-only tests, cumulative software and device-specific acceptance checklists, exact-head integrity/licensing/UX review, production signing and physical/Apple credentials delegated to owner |

**PR120** adaptive mixed-phase and **PR126** personalized binaural
research remain *deferred optional tracks*. A broader PR125 database/model
feature is also optional: it must not delay the complete, editable headphone
correction UI. Any new discovery of an unsafe high-rate DSP path should be
handled as a tightly scoped hardening commit, not as a fifth research batch.

## CI execution policy

1. While coding, run fast, narrowly scoped deterministic C/Python source
   checks and targeted test suites as appropriate. Do not claim a pass
   without actually observing it.
2. For the current **Batch 1 PR #125**, the pull_request opened/reopened/
   synchronize events trigger one portable suite, not simultaneous push
   and pull_request copies.
3. Full xcodebuild arm64 Release + cumulative XCTest, with generated actual
   native SOFA files, runs only when the maintainer adds the
   **integration-ci** PR label or uses workflow_dispatch. On a code change
   after that acceptance attempt, the prior result is stale; remove and
   re-add the label for the next exact-head checkpoint. A persistent label
   does *not* launch full CI on every synchronize event.
4. The targeted executable suite aggregates three independent numeric
   engines: **80 PR117 + 19 FIR + 42 SOFA/HRTF = 141 cases**, plus inherited
   native SOFA/ABI/PR112 checks, in one machine-readable evidence artifact.
   Apple's actual-file import tests, including 384-kHz Data.Delay and
   persistence, and the full app build remain separate Apple Silicon gates.
5. If the batch changes shipping DSP, routing, speaker protection or sample
   rates, relevant affected code still receives early compiler/realtime
   checks; do not delay detection until end-of-batch integration.
6. No synthetic test, browser automation, or GitHub-hosted macOS runner may
   mark real-hardware PR112 H01–H08, acoustic speaker/driver verification,
   high-volume headphone safety, actual native DAC 384-kHz support, or live
   feed-forward ANC authorized.

## Lifecycle

- Preserve each PR as **OPEN/DRAFT/UNMERGED**; only owner review with
  appropriate physical acceptance may approve merge.
- Record exact commit and rate coverage in acceptance artifacts; any change
  invalidates the previous final integration certificate.
- Minimize runner load, not validation depth: full regression, safety,
  provenance and licensing still gate candidate releases.
- The product north star remains complete hi-fi/home-cinema audio correction
  for Mac, not a laboratory clone, a rack of creative effects or an
  unbounded research project.

## Current Batch 1 handoff

Base: PR117C #124; active Batch 1 draft: former PR117D #125.
Ancestors: PR117B #123, PR117A #122, PR117 #120, PR116B #119.
Their prior CI results are retained. Batch 1 will not certify automatic
SOFA 48-kHz-to-384-kHz conversion because no such product-quality resampling
path has yet been verified; the existing mismatched-rate boundary fails
closed. Later explicit SRC implementation, if needed, belongs in Batch 3.
