# Feature flags

Unfinished epics merge to `main` dark, behind a feature flag that is off by default. This keeps
`main` releasable while an epic lands over several PRs.

## Lifecycle (owner decision, 11 Nov 2026: flag graduation)

1. **Dark.** The flag defaults off. The epic's slices merge behind it.
2. **Graduated.** The epic's software is done, wired through the production UI and passing its tests, every
   gap in the epic closed. The flag gets `graduated: true` in `FeatureFlag.all`: it defaults **on**, in release
   builds too (and in debug builds, where a stored override can still turn it off). The feature is available and
   functional. Bench-dependent "is it good" acceptance is not part of the epic; it belongs to E22.
3. **Removed.** The flag-cleanup phase (FC, after E22 and before E18) deletes the flag and its dead branch in small
   per-epic PRs.

Hard rules:

- **Graduated means available, never armed.** Live ANC and live MIMO room treatment keep their arm switch
  (`LiveTreatmentArm`, never persisted) and the written authorisation path. A flag graduating never arms anything.
- **Definition of done is unchanged in strictness** (AGENTS.md section 12): a graduation slice needs an end-to-end
  test through production wiring and every gap in its epic closed. A slice with an open ledger entry is not ticked.
- **No new code may depend on a graduated flag.** It is an escape hatch until cleanup, nothing more.
- **The flags-off path stays tested while flags exist:** nightly `macos-full` runs the suite with graduated flags
  off as well as on (plan item FC1, `docs/epics/FC.md` G1).
- **A release user can turn a graduated feature off** with the launch argument (below). Release builds still ignore
  stored overrides.

## Launch argument

`-NotchSixtyFeatures <list>`: comma-separated entries, spaces around entries ignored.

| Entry | Meaning |
| --- | --- |
| `id` or `id=on` | Switch the flag on |
| `-id` or `id=off` | Switch the flag off (use this to disable a graduated feature) |

Off wins if the same id appears both ways. The launch argument beats a stored override (debug builds) and the
compiled default. Unknown ids and malformed entries are ignored. Example: `-NotchSixtyFeatures e4.zones,-e28.dynamics-extras`.

Debug builds also read `NOTCHSIXTY_GRADUATED_FLAGS_OFF=1`, which switches every graduated flag off. Nightly `macos-full` sets it
(as `TEST_RUNNER_NOTCHSIXTY_GRADUATED_FLAGS_OFF`) for a second XCTest run. Release builds ignore it.

## Adding a flag

1. Add an entry to `FeatureFlag.all` in `NotchSixty/State/FeatureFlags.swift`, with a stable `id`,
   a title, and the owning epic (for example `epic: "E6"`).
2. Gate the new behaviour in the app shell with `featureFlags.isEnabled(.yourFlag)`. Views get
   the store from the environment (`@EnvironmentObject var featureFlags: FeatureFlags`).
   Controllers take it as an initialiser argument so tests can inject one.
3. Keep the shipping behaviour unchanged while the flag is off, and test both states.

When the epic's software is done, graduate the flag (`graduated: true`, keep it in `FeatureFlag.all`). Do not
delete it; the flag-cleanup phase removes it, with every check that reads it, after E22. Do not add new code that
depends on a graduated flag.

## Rules

- **The engine never reads flags.** Swift decides, then publishes the resulting configuration
  through the normal graph/snapshot path. The realtime core stays flag-free and portable (E21).
- **Debug builds** show a Developer section in Settings to switch flags on. The choice is stored
  as `feature.<id>` in `UserDefaults`.
- **Release builds** ignore stored overrides, so a shipped build never shows unfinished work by
  accident. Dark flags are off; graduated flags are on. For TestFlight testing, launch with
  `-NotchSixtyFeatures id1,-id2` (see Launch argument).
- Flags that aren't in `FeatureFlag.all` are always off. A stale override left by a removed
  flag, or a mistyped launch argument, can't switch anything on.
- All persisted keys live in `NotchSixty/State/PreferenceKeys.swift`. Never rename a stored key.

## Flag registry (11 Nov 2026)

Status: dark (default off), graduated (default on, stays until cleanup), removed (gone from `FeatureFlag.all`),
planned (in an epic plan, not yet in code). The seven E4 flags with a production reader graduated on 11 Nov 2026; `e26.sub-aware-anc` is already on by default
through `defaultEnabled` (owner decision, E26 S7) and converts to `graduated: true` in E26 S7. Cleanup owner is the
FC phase's per-epic PR (`docs/epics/FC.md`) unless stated.

| flag | epic | status | graduated-since | cleanup owner |
| --- | --- | --- | --- | --- |
| `e6.legacy-kernel` | E6 | dark (inverse escape hatch; never graduates) | n/a | E23 |
| `e4.engine-lease` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e4.adaptive-tonal-live` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e4.earned-cap` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e4.feedforward-live` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e4.noise-survey` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e4.conversation-unmasking` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e4.virtual-microphone` | E4 | graduated | 11 Nov 2026 (G16) | FC (E4) |
| `e4.head-position-camera` | E4 | graduated | 11 Nov 2026 (G16) | FC (E4) |
| `e4.zones` | E4 | graduated | 11 Nov 2026 (G16) | FC (E4) |
| `e4.overnight` | E4 | graduated | 11 Nov 2026 (S32) | FC (E4) |
| `e26.sub-aware-anc` | E26 | on by default (pre-policy `defaultEnabled`) | 6 Nov 2026 (as default) | FC (E26) |
| `e9.long-fir` | E9 | dark | none | FC (E9) |
| `e9.output-protection` | E9 | dark | none | FC (E9) |
| `e13.headphones` | E13 | dark | none | FC (E13) |
| `e19.mimo-treatment` | E19 | dark | none | FC (E19) |
| `e28.dynamics-extras` | E28 | graduated | 11 Nov 2026 (S8) | FC (E28) |
| `e29.room-model` | E29 | dark, no production reader | none | FC (E29) |
| `e7.rate-adapt` | E7 | planned | none | FC (E7) |
| `e15.follow-output` | E15 | planned | none | FC (E15) |
| `e17.export`, `e17.dither` | E17 | planned | none | FC (E17) |
| `e20.parallel-render` | E20 | dark (S6: worker pool in the output workgroup) | none | FC (E20) |
| `e20.multirate` | E20 | planned (E20 S7, S8) | none | FC (E20) |
| `e21.core-designers` | E21 | planned | none | FC (E21) |
| `e8.routing-matrix`, `e8.lab-routed-ways`, `e10.mixed-phase-correction`, `e11.measurement-suite`, `e12.guided-setup`, `e13.byo-import`, `e25.outputs-and-speakers`, `e27.eq-safety` | E8, E10, E11, E12, E13, E25, E27 | removed (before this policy, at epic ship) | n/a | done |

Owner decisions, 11 Nov 2026: (1) the four live-output E4 flags may graduate (Turn On available in release builds,
still behind `LiveTreatmentArm` and the written authorisation path; the user must enable it). (2) A bench-only gap may
be closed as "moved to E22" only against a matching unchecked E22 item; software gaps never move.

## Audit of completed and partly completed epics (11 Nov 2026)

Read against AGENTS.md section 12. "Reachable" means a production reader of the flag and a UI path. No open-question
gap blocks any epic except where stated. Bench or owner acceptance moves to E22 (`docs/PROGRAM_PLAN.md`); a bench-only
gap may then be closed as "moved to E22" once E22 holds a matching unchecked item.

| Epic | Flag | State | Blockers to graduation |
| --- | --- | --- | --- |
| E4 | `e4.engine-lease`, `e4.adaptive-tonal-live`, `e4.earned-cap`, `e4.feedforward-live` | Graduated 11 Nov 2026 (S32): Turn On available, never armed | none |
| E4 | `e4.noise-survey`, `e4.conversation-unmasking`, `e4.overnight` | Graduated 11 Nov 2026 (S32) | none |
| E4 | `e4.virtual-microphone`, `e4.head-position-camera`, `e4.zones` | Graduated 11 Nov 2026 (G16): ear survey, camera follow and zone chooser wired, adaptive worker uses the ear error (G18); available, never armed | none |
| E6 | `e6.legacy-kernel` | Software complete bar S12h part 3; the inverse escape hatch | Never graduates; E23 deletes it; scoped gaps owned by E22 and E23 |
| E7 | `e7.rate-adapt` (planned) | Only S1 built; flag not yet in code | S2 to S5; S5 reworded to graduate |
| E9 | `e9.long-fir`, `e9.output-protection` | Reachable (Outputs UI, headroom assistant); 11 items `[~]` (S2d G9, S5 hard-limit and flag-off tests, S7b) | Close `[~]` items; G18, G25, G26 are bench (move to E22); no ship slice existed, new S8 |
| E13 | `e13.headphones` | S3, S4, S7 reachable behind the flag; S5 not built | S5; software gaps G7, G9, G10, G12; bench gaps G2 to G6, G8, G11 move to E22; S8 reworded |
| E15, E17, E21 | planned flags | Nothing built | Whole epics; ship slices reworded |
| E19 | `e19.mimo-treatment` | Designer only; S5 PR open; stage not published (S6 to S11 unbuilt) | Not reachable; 16 scoped gaps; live treatment keeps its arm; S11 reworded |
| E20 | `e20.parallel-render`, `e20.multirate` (planned) | S6: flag in code, worker pool and policy wired in all three transports (dark); core parallel API from S5 | S6 to S10; S10 and G1 reworded (graduate before the bench, remove in FC) |
| E26 | `e26.sub-aware-anc` | On by default, 36 `[~]` items | G13, G14, G33, G35, G39, G40 software gaps; bench gaps G10, G11, G19, G23, G24, G28, G30 move to E22; G18 is post-v1 |
| E28 | `e28.dynamics-extras` | Graduated in S8 (11 Nov 2026); every extra reachable on the Dynamics page and published for stereo, N-channel, routed and binaural graphs | Owner listen and bench gaps move to E22; flag removal is FC (E28) |
| E29 | `e29.room-model` | S1 only; no production reader | S2 to S8 |
| E8, E10, E11, E12, E25, E27 | removed | Flags gone before this policy; audited by the 6 Nov programme audit | none |

Flag-removal-at-ship slices found and reworded to "graduate" in this PR: E7 S5, E13 S8, E15 S4, E17 S5, E19 S11,
E20 S10, E21 S14, E26 S7, E28 S8, E29 S9, and E4's S30 ship note. Epics whose completion depended on owner
acceptance or the bench before the flag could go: E4 (S30 bench), E19 (E22 bench before ship), E20 (E22 bench before
removal), E26 (E22 sub checks), E28 (owner listen), E9 ("owner enables"), E13 (G8 bench). The acceptance part moves to
E22; the software part graduates.

## Flag details

| id | epic | gates |
| --- | --- | --- |
| `e6.legacy-kernel` | E6 | Selects the frozen legacy render kernel (E23 deletes it) |
| `e4.adaptive-tonal-live` | E4 | Live adaptive tonal canceller and the supervised microphone-move re-solve; still needs the per-feature arm switch (S18b) |
| `e4.earned-cap` | E4 | Anti-noise cap earned in 3 dB steps from -40 to -18 dBFS per binding (S20); needs `e4.adaptive-tonal-live` |
| `e4.feedforward-live` | E4 | Live feed-forward cancellation (S22); S22b1 gates only the speaker-drive recording for the echo model; off means nothing sets the demand |
| `e4.conversation-unmasking` | E4 | Conversation Focus unmasking by SII per-band music cuts and syllable-rate speech detection (S30); ambient compensation only, no ANC output |
| `e4.virtual-microphone` | E4 | Tonal virtual microphone at the ears: monitor-to-ear ratio survey and effective secondary path (S26a); offline maths, no output |
| `e4.zones` | E4 | Choose the quiet zone: fixed seat, follow, or two zones with the 2 x 2 per-tone core and zone mode in the earned-cap binding (S27); offline maths, no output |
| `e4.overnight` | E4 | Overnight Quiet Zone runs: keep the Mac awake while armed (power assertion, S29) and the 10-minute thermal mean; type only, nothing arms it |
| `e26.sub-aware-anc` | E26 | On by default, including release builds (owner decision, E26 S7). Sub-aware Quiet Zone: bass-path records and readiness replace the blanket subwoofer refusal (S1 so far: mono bass on the pair no longer counts as a sub). The undeclared-receiver refusal and its declaration picker are always on |
| `e9.long-fir` | E9 | Off by default. Graph FIRs (program, room, speaker IR, driver) of up to 262,144 taps on the non-uniform engine (`firScheme` 1) at the same 256-frame latency; Swift lifts the 32,768 eligibility and lane-plan limits. Read once at launch (takes effect on relaunch). Off: 32,768 and the kernel fallback above it, unchanged |
| `e9.output-protection` | E9 | Off by default. Every graph output is protected: sub lanes get their own PROTECTION stage with the program settings, an Advanced "Independent per output" switch gives every program lane its own stage, and an always-on hard limit (-1 dBFS, no look-ahead, zero latency) closes every output, routed outputs included. Read once at launch (takes effect on relaunch). Off: the graph is bit-identical to before |
| `e13.headphones` | E13 | Off by default. Guided personal BRIR capture in Headphones (S7): in-ear microphones, speaker passes at 1, 3 or 5 head yaws, optional headphone compensation, quality-gated passes and a review before saving. S3 to S5 (live tuning, long BRIRs, interpolation) join this flag. Off: no capture button |
| `e19.mimo-treatment` | E19 | Off by default. MIMO room treatment (S3 so far: the Swift designer calling the portable design core and checking the realised filters; nothing in the app calls it yet). Off: today's code paths, UI and routing refusal. On: the new designer and, in later slices, the stage, safety layer, verifier and controls; live output still needs a permit and the arm |
| `e28.dynamics-extras` | E28 | On by default (graduated, E28 S8). Compressor mix, link, peak/RMS detector, listen and lookahead; expander hold, knee, RMS, sidechain high-pass, link and listen; multiband auto-release, bypass, solo, listen, detector, lookahead and the band-pass split, all on the Dynamics page. On: the stage blocks widen to 16, 13 and 44 values and lookahead frames add to the graph latency (A/V-sync, routing total, hand-over check). Off (`-NotchSixtyFeatures -e28.dynamics-extras`): the 10, 6 and 29 value blocks, bit-identical to before |
| `e29.room-model` | E29 | Off by default. The shared room position model: S1 is a read-only index over room-correction positions, the measurement library, combined ANC path records and the head survey (no UI yet); the seat map, music-at-seat and consumer adoption follow. Off: every feature reads its own records exactly as today |
| `e20.parallel-render` | E20 | Off by default. Up to three extra realtime worker threads in the output device's Audio Workgroup render the non-uniform FIR lanes in parallel (needs `e9.long-fir`); Swift picks the worker count from the graph's estimated load. Read once at launch. Off: no worker thread exists, the audio thread renders alone |
