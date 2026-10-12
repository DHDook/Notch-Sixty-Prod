# PR109 — Hardware Acceptance and Future Merge Handoff

Status: **REMOTE PLANNING ONLY — NO PHYSICAL OR RELEASE ACCEPTANCE**.
This is a later-use handoff, not permission to merge or release.

## Why the draft stack remains open

The owner is away from the physical Mac and audio system. Remote GitHub Actions
can prove source ancestry, deterministic DSP/math, macOS builds, XCTest and
software fail-closed behavior. It **cannot** authenticate a calibration mic,
DAC/ADC loopback wiring, speaker safety, acoustics, device handling, thermals,
vendor Audio Units or Apple credentials.

Do not merge, squash, rebase, close or mark draft PRs ready simply because
PR109's portable and macOS jobs pass. Keep
`feature/pr109-integration-stack-consolidation` stacked on
`feature/pr108-coherent-subwoofer-alignment` until a separate owner decision.

## Minimum evidence captured before any real hardware work

- exact tested commit SHA, branch, app build and CI workflow IDs;
- Mac model, OS version, sample rate and I/O buffer settings;
- playback-system ID, selected physical outputs/UIDs and speaker/sub routing;
- microphone, ADC and calibration profile identity;
- safe line-level electrical reference diagram if coherent timing is tested;
- baseline/verification capture IDs, timestamps, analysis and confidence;
- human-recorded PASS, FAIL, BLOCKED or NOT APPLICABLE for each relevant test.

Never convert a BLOCKED/NOT APPLICABLE item into PASS on the basis of synthetic
CI evidence.

## Ordered physical and release test program

| Gate | Detailed source | Physical test group | Evidence state |
| --- | --- | --- | --- |
| H01 | PR101 software closure; PR102 release handoff | selected-device unplug/replug, sleep/wake, permission and route recovery, stop/start and quit | HARDWARE REQUIRED |
| H02 | PR101 / PR102 | prolonged representative CPU/thermal/resource/XRun soak; emergency mute and speaker safety | HARDWARE REQUIRED |
| H03 | PR103 physical handoff | stable single-mic listening-position speaker/sub sweep baselines and measured-source isolation | HARDWARE REQUIRED |
| H04 | PR105 characterization / verification | ~1 m installed-speaker characterization, correction-proposal approval, new verified PEQ measurements and rollback | HARDWARE REQUIRED |
| H05 | PR106 physical Lab runbook | whole-speaker on/off-axis, near-field, early-window suitability, protected driver only with actual safe Bi/Tri-Amp topology | HARDWARE REQUIRED / TOPOLOGY CONDITIONAL |
| H06 | PR107 FIR physical acceptance | sparse FIR latency, channel coherence, headroom, no clipping/XRuns, real acoustic improvement, A/V compensation, restart/rollback | HARDWARE REQUIRED |
| H07 | PR108 physical acceptance | mic and reference on SAME ADC, Main/Sub on SAME output clock domain, safe line-level reference, pairwise timing/polarity improvement, rollback | HARDWARE REQUIRED / ROUTE CONDITIONAL |
| H08 | PR99 / PR101 / PR102 ANC protocols | independent physical feed-forward ANC causality, clock and speaker-connected safety checks | BLOCKED — LIVE ANC NOT AUTHORIZED |
| R01 | PR102 release handoff | production Apple signing, entitlement review, App Store Connect upload, TestFlight, App Review | RELEASE CREDENTIALS REQUIRED |
| R02 | PR102 release handoff / provenance | final third-party notices, clean-room/IP records, optional specialist legal review, distribution decision | EXTERNAL REVIEW/POLICY REQUIRED |

PR103's older runbook intentionally says **its** raw per-driver targeted
transport is blocked. PR106 subsequently introduced a distinct
crossover/limiter-preserving Low/Mid/High Lab transport. Never interpret PR106
as permission to bypass protection on the PR103 path.

PR106's original Lab diagnostics do not themselves apply DSP. PR108 added a
separate explicit review/Apply/verify/rollback controller to the same UI.
Keep those authority paths distinct when interpreting older checklists.

## Physical configuration constraints

### Conventional passive loudspeakers and line-level Sub

The normal Klipsch RP-600M / Denon receiver / line-level Klipsch subwoofer
arrangement can be useful for whole-speaker and room measurement.
It does **not**, merely by having a receiver pre-out, provide independently
addressable active Low/Mid/High drivers or a separate physical Sub output that
Notch Sixty can alter independently. Mark those specific tests BLOCKED if the
required routing and protection hardware is unavailable.

### Coherent Main/Sub measurement and electrical reference

PR108 needs two different capture channels on the **same physical ADC**:
one calibrated mic, one safe electrical reference. Main and Sub source sweeps
must use the same output-device clock/reference contract. A mic and DAC with
unrelated sample-clock domains do not automatically meet that contract.
Never wire powered amplifier/speaker outputs into an ADC/line-level input.
When the reference topology cannot be made safe and qualified, block PR108
deployment rather than guessing absolute timing or polarity.

### Split-driver active crossovers

Only attempt individually routed Low/Mid/High capture after establishing
the actual amplifier-to-driver wiring, mandatory crossover filtering,
per-driver limiting and conservative stimulus. A passive speaker connected
over one amplifier output has no independent digital woofer/tweeter lane.
Unnecessary active-driver experiments are not a release requirement for
hardware configurations that cannot support them.

## Future merge review (not an executable instruction)

1. Confirm all PR branches and exact parent/checkpoint SHA relationships
   remain as documented in the PR109 pinned stack manifest. Review any later
   changes or divergence before merging.
2. Separately inspect the **earliest still-open ancestor PRs**, not merely
   PR108/PR109; the historical stacked branch lineage predates PR99.
3. Determine which physical acceptance gates are mandatory for the actual
   intended shipped feature set, and which unsupported hardware capabilities
   must stay disabled or out of the release boundary. Do not silently waive
   a shipping safety requirement by calling it NOT APPLICABLE.
4. Obtain and attach relevant real-Mac test evidence and acceptance decisions.
5. Only following explicit owner authorization, prepare a sequential
   bottom-up merge plan. Do not collapse the 1,308-commit branch difference
   into an unreviewed mega-merge and do not overwrite `main`.
6. Preserve a reproducible tested commit/build before Apple signing and any
   TestFlight, App Review or other distribution decision.

## PR109 artifact interpretation

CI may write JSON proving:
`remoteGitAncestryAndCI` and `remoteStaticCrossFeatureAudit`.

CI must always retain:
`hardwareAcceptanceComplete=false`,
`releaseAcceptanceComplete=false`,
`mayMergeIntoMain=false`, and
`liveFeedForwardANCAuthorized=false`.

That is a deliberate safety invariant, not an incomplete script.
