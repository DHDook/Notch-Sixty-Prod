# PR112A — Remote Hardware-Acceptance Infrastructure

**Status: Slices 1–4 implemented; exact-head CI pending.**

PR112A is the remote-preparation half of roadmap PR112. It is stacked on the
exact remote/software-complete PR111 head and intentionally stops before any
physical hardware or acoustic gate can be marked passed.

The purpose is to make the later hands-on campaign **guided, reproducible,
append-only, evidence-backed, and fail-closed** instead of relying on an
informal checklist when the owner returns to the Mac/audio system.

## Hard authority boundary

Remote CI may validate:

- the acceptance catalog and state machine;
- serialization/persistence and corruption handling;
- evidence-authority ordering;
- scope decisions and conditional feature disabling;
- report generation;
- UI/workflow logic added in later PR112A slices; and
- all inherited application builds/regression tests.

Remote CI **cannot** establish:

- real device unplug/replug or sleep/wake recovery;
- physical thermal/endurance behavior;
- real speaker/emergency-mute safety;
- calibrated microphone identity or placement;
- real acoustic improvement;
- same-clock electrical-reference wiring;
- exposed Low/Mid/High driver safety;
- live speaker-connected feed-forward ANC safety;
- production signing/release acceptance; or
- permission to merge the stacked PRs.

Every PR112A CI artifact must therefore preserve:

- \`physicalAcceptanceComplete = false\`;
- \`releaseAcceptanceComplete = false\`;
- \`liveFeedForwardANCAuthorized = false\`; and
- \`mayMergeIntoMain = false\`.

## Slice 1 — Acceptance domain, evidence authority, persistence

\`HardwareAcceptance.swift\` introduces the authoritative in-app acceptance
domain for physical gates H01–H08.

### Evidence authority

Evidence is monotonic:

1. \`remoteSoftware\`;
2. \`physicalHardware\`;
3. \`independentPhysicalReview\`.

A higher class can satisfy a lower requirement. A lower class can never satisfy
a stronger requirement. In particular, a synthetic/CI observation carrying a
\`passed\` label still evaluates as **insufficient authority** for a hardware
gate.

Speaker-safety/acoustic gates use \`independentPhysicalReview\` where the
historical PR101 acceptance model already required stronger evidence.

### H01–H08 catalog

| Gate | Scope | Minimum authority | Physical purpose |
| --- | --- | --- | --- |
| H01 | Required | Physical hardware | DAC/interface unplug/replug, same-UID recovery, permissions, sleep/wake, Stop/Start/Quit |
| H02 | Required | Independent physical review | endurance/resources/dropouts plus emergency-mute and speaker safety |
| H03 | Required | Physical hardware | real speaker/Sub baseline measurements and source isolation |
| H04 | Required | Independent physical review | Speaker Optimizer before/after correction and rollback |
| H05 | Required | Independent physical review | whole-speaker Measurement Lab; protected split-driver work is supplemental when that topology is in scope |
| H06 | Required | Independent physical review | FIR latency/coherence/headroom/acoustic/A-V/rollback |
| H07 | Conditional | Independent physical review | coherent Main/Sub same-ADC/same-output-clock timing/polarity |
| H08 | Conditional | Independent physical review | live feed-forward ANC causality/clock/speaker safety |

H05 is **not waived** simply because a conventional passive speaker lacks
independent woofer/tweeter outputs. Whole-speaker Lab acceptance remains
required. The protected split-driver portion is recorded as an explicit
supplemental capability.

H07 and H08 require explicit release-scope decisions. Exclusion requires a
non-empty reason. H08 exclusion means live feed-forward ANC stays disabled.

### Campaign identity

A campaign binds:

- exact source commit and branch;
- app version/build;
- Playback System ID; and
- immutable campaign ID/timestamp.

Each observation additionally records the physical environment:

- Mac model and macOS version;
- sample rate and I/O buffer;
- physical input/output device names and stable UIDs;
- microphone identity where applicable;
- speaker/sub topology; and
- electrical-reference path description where applicable.

Artifact references may point to capture/session/report/build identifiers and
optionally a SHA-256 digest.

### Append-only observations

Every evidence observation has a unique ID and one of:

- \`passed\`;
- \`failed\`; or
- \`blocked\`.

The newest observation for a gate is authoritative. This is deliberate: a later
failure must be able to regress an earlier pass rather than leaving a stale
green status.

Duplicate evidence IDs are rejected. Campaign files are created once and later
changed only through append operations. Corrupt persistence fails closed and is
never silently overwritten.

### Conditional capability scope

Every topology-conditional capability receives an explicit \`included\` or
\`excluded(reason:)\` decision:

- protected split-driver measurement;
- coherent independently routable Sub alignment; and
- live feed-forward ANC.

There is no implicit \`not applicable\` conversion. Conditional exclusions are
auditable release-scope decisions.

### Rollups

\`HardwareAcceptanceCampaign.evaluate()\` returns a status for every H01–H08
gate:

- missing;
- explicitly excluded;
- blocked;
- failed;
- insufficient evidence authority; or
- passed.

\`physicalAcceptanceComplete\` becomes true only when every required/included
gate is accepted by sufficient authority.

\`liveFeedForwardANCAuthorized\` requires all of the following:

1. H08 is explicitly included;
2. H08 passes with \`independentPhysicalReview\`;
3. every other required/included H01–H08 gate is accepted.

The current project remains outside that state. PR112A CI does not supply
physical observations.

## Physical topology constraints carried forward

### Passive stereo speakers

A conventional passive two-way speaker connected through one amplifier output
has no independent digital Low/High lane. Protected PR106/PR111 driver work
requires genuinely separate amplification/routing, mandatory crossover
protection and limiting.

If such hardware is unavailable, the **supplemental split-driver scope** is
explicitly excluded for that campaign. H05 whole-speaker Lab acceptance still
runs.

### Coherent Main/Sub alignment

H07 needs a calibrated microphone and safe electrical reference on two channels
of the **same ADC**, with Main/Sub playback in the required common output-clock
domain. Never connect a powered speaker/amplifier output directly to a
line-level ADC input.

If that topology cannot be established safely, H07 remains excluded/blocked;
software timing estimates are not substituted.

### Feed-forward ANC

H08 remains outside normal release scope unless deliberately enabled for a
physical campaign. CI, simulations, microphones alone, or causal models cannot
authorize speaker-connected live ANC.

## Planned remote PR112A follow-on slices

**Slice 2 — Guided acceptance campaign controller & UI
(implemented; exact-head CI pending).**

The product now owns a `HardwareAcceptanceController` and restores the most
recent persisted campaign at startup. A dedicated **Hardware Acceptance** entry
appears under **TOOLS** beside Room Advisor while retaining the normal Playback
System toolbar context.

Campaign creation freezes the exact commit/branch, app version/build, selected
Playback System and all three conditional scope decisions. Existing campaigns
are never edited or deleted; starting again creates a new campaign identity.

The H01–H08 matrix shows each gate's minimum evidence authority and current
status. Selecting a gate opens an evidence form with physical Mac/macOS,
sample-rate/buffer, stable I/O device UIDs, microphone/instrument, speaker
topology and safe-reference metadata plus reviewer notes and optional artifact
identifier.

The form deliberately defaults to **Remote software / BLOCKED**. Selecting
`physicalHardware` requires an explicit attestation that the test was actually
performed on the recorded hardware. Selecting
`independentPhysicalReview` additionally requires a separate reviewer
attestation. Excluded conditional gates cannot receive evidence, and campaign
scope cannot be rewritten in place.

When split-driver testing is included, H05 exposes a separate checkbox stating
that the observation actually covered protected independently routed
Low/Mid/High drivers. Merely passing whole-speaker H05 without that coverage
leaves H05 in **INSUFFICIENT SCOPE**.

The UI exposes no Apply, routing, DSP, audio-start, correction, merge or release
control. It only appends evidence through the acceptance store.

**Slice 3 — Gate-specific evidence adapters
(implemented; exact-head CI pending).**

Typed adapters now link existing product evidence into H03–H07 without copying
raw sweep data or inventing a second verification format:

- **H03** links a Speaker Optimizer baseline measurement set plus every compact
  capture ID and re-runs the existing repeat/quality evaluator.
- **H04** links an accepted PEQ post-Apply verification and its matching
  finalization receipt, baseline set ID, verification set ID and Apply receipt
  ID.
- **H05** links a structurally valid, complete whole-speaker Measurement Lab
  session and its capture IDs. Protected split-driver supplemental coverage is
  claimed only when protected protocols are present, complete, unclipped and
  retain valid crossover/limiter route provenance.
- **H06** links accepted FIR measured verification with its matching FIR
  finalization receipt and exact baseline/verification/Apply identities.
- **H07** supports finalized single-Sub or coordinated multi-Sub coherent
  verification, preserving Apply receipt and verification Lab session IDs.

Every linked packet carries a recommended PASS/FAIL/BLOCKED interpretation for
the human reviewer, but its automatic authority is permanently
`remoteSoftware`. `canEstablishPhysicalAuthority=false` and
`canAuthorizeLiveFeedForwardANC=false` are hard properties. The adapters
contain no AudioIO, ProductProfile mutation, Apply or output-control path.

Thus a fully accepted product verification can make later physical review much
easier to audit, but it still evaluates as insufficient hardware authority
until Slice 2 records the actual physical/reviewer attestations.

**Slice 4 — Preflight & protected commissioning handoff
(implemented; exact-head CI pending).**

The Hardware Acceptance workspace now has a **Run Read-Only Preflight** card
for the selected H01–H08 gate. It is deliberately separate from append-only
acceptance evidence: a green preflight means only that software/configuration
prerequisites are consistent enough to begin the recorded physical procedure.

Every preflight requires the selected Playback System to match the immutable
campaign identity, its saved system state to be clean, the audio engine to be
idle, and the recorded physical output UID to match the engine-selected output
(and the Playback System's associated UID where present). Measurement gates
also require a real ADC/input UID and microphone/calibration identity.

When protected split-driver H05 scope is included, preflight additionally
requires enabled protected multi-output/crossover state, per-driver processing,
explicit confirmation of the independently amplified/crossed-over/limited
wiring, and the latest matching **PR111 commissioning draft**. The draft is
revalidated and checked against the exact current Playback System rollback
snapshot. Every affected bus must still retain limiter protection. PR111's
PEQ/timing/polarity hypotheses remain unapplied; preflight merely allows the
later combined-driver physical verification procedure to begin.

For H07, preflight requires an independently addressable `subMono` route plus
explicit declarations that the calibrated microphone and electrical reference
occupy separate channels of the **same physical ADC**, Main/Sub playback share
the required output clock domain, and the reference is a documented safe
line-level path. Powered speaker/amplifier output is never an acceptable ADC
reference source.

H08 stays hard-blocked in PR112A even when explicitly included in campaign
scope. Live speaker-connected feed-forward ANC still requires its separate
physical safety protocol and independent review.

The result hard-codes:
`physicalAcceptanceEstablished=false`,
`canSatisfyHardwareGate=false`, `canApplyDSP=false`,
`canDeploy=false`, `canAuthorizeLiveFeedForwardANC=false`, and
`mayMergeIntoMain=false`. The UI has no Start-Test, Apply, route mutation,
DSP mutation, merge, or release action.

New deterministic tests cover exact-system/idle/output readiness, dirty and
wrong Playback Systems, missing measurement input/microphone, PR111 state
drift, missing limiter protection, coherent same-ADC/clock/reference gates,
independent Sub routing, permanent H08 blocking, and latest commissioning
draft selection by Playback System.

**Slice 5 — Reports, export & physical runbook closeout
(implemented; exact-head CI pending).**

The Hardware Acceptance workspace now exports an immutable JSON acceptance
packet and a human-readable Markdown physical runbook from the current
campaign. Both are built directly from the append-only campaign/evaluation;
they do not maintain a second acceptance database and cannot change evidence.

The packet contains:

- exact campaign ID, source commit/branch, app version/build and Playback
  System ID;
- every immutable capability-scope decision and exclusion reason;
- normalized H01–H08 status, required/actual authority, latest observation
  identity and unresolved-gate list;
- the complete evidence log with reviewer, physical environment, input/output
  UIDs, microphone identity and covered supplemental capabilities;
- a deterministic artifact manifest preserving capture/session/report
  identifiers and optional SHA-256 digests; and
- one safety-bounded physical runbook step per H01–H08 gate with objective,
  required authority, current state and next action.

The runbook deliberately avoids converting software preflight into test
completion. It repeats the critical physical boundaries: calibrated real input
for acoustic evidence, real rollback/before-after verification, protected
split-driver amplification/crossover/limiter requirements, speaker-safe FIR
and endurance testing, and same-ADC/common-output-clock/safe-line-level
reference requirements for coherent Main/Sub testing. It explicitly warns
never to feed speaker-level amplifier output directly into an ADC. H08 remains
disabled unless separately included and independently physically reviewed.

Even a future packet where every in-scope physical H01–H08 gate is accepted
still hard-codes releaseAcceptanceComplete=false and mayMergeIntoMain=false.
PR112A hardware evidence is not App Store, provenance/legal,
release-credential or owner merge authorization.

New deterministic report tests prove that:

- a remote-software PASS remains insufficientAuthority in both JSON and
  Markdown;
- exact artifact/observation IDs survive export;
- complete physical H01–H08 acceptance still cannot create release/merge
  authority;
- every runbook gate carries its safety boundary; and
- a newer failure replaces a stale earlier pass in the exported status.

The UI exposes Export JSON Packet and Export Markdown Runbook only.
Export does not start audio, mutate DSP/routing, authorize ANC, merge a branch,
or alter campaign evidence.

## Merge/release boundary

PR112A remains OPEN, DRAFT and UNMERGED. It does not merge ancestors or change
\`main\`. PR113 UX polish and PR114 commercial release preparation remain later
milestones. Production signing/TestFlight/App Review and external provenance/IP
review are not PR112A acceptance evidence.
