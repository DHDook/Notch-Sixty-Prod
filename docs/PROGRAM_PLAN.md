# Notch Sixty — v1 Program Plan

Last updated: 18 Oct 2026. It supersedes the old roadmap, now archived at `docs/archive/ROADMAP.md`.
The live, commentable version of this plan is the claude.ai doc "Notch Sixty — v1 Program Plan";
the companion "Notch Sixty — Competitive Gap Analysis (Oct 2026)" explains why each epic exists.

v1 launches only when every scoped epic below is done and the full hardware regression passes at
all rates from 44.1 to 384 kHz.

## Decisions taken

Owner decisions from 17 Oct 2026 (and later, where dated) fix the plan's shape. Where `AGENTS.md` conflicts
with them, these decisions win until E1/E21 update `AGENTS.md`.

| Decision | Choice |
| --- | --- |
| Branch model | `main` is the trunk; all 77 stacked drafts are resolved and `main` was at `17dad33` when this plan was written |
| macOS floor | Lower to macOS 26 |
| Speaker ANC (Quiet Zone) | Keep as the flagship differentiator; qualify it on hardware for v1 |
| Headphone database | No licensed database for now; make bring-your-own measurement files first-class |
| Sample rates | Every feature works at every device rate up to 384 kHz; HRIRs are resampled on activation (PR #131 behaviour kept) |
| v1 timing | Ship only when every scoped epic is complete, for a single high-impact launch |
| Engine language | C++20/23 for the whole engine core (realtime kernel and design maths) behind one versioned C interface; Swift stays for the macOS app |
| Engine performance architecture | Whole-buffer processing, multirate processing for low-frequency paths, multiple realtime threads, and best-in-class algorithms |
| Flag graduation (11 Nov 2026) | An epic ends when its software is done, wired through the production UI and passing its tests, and its flag is graduated (stays in `FeatureFlag.all`, defaults on in release builds). Graduated means available, never armed: live ANC and MIMO keep `LiveTreatmentArm`. Flags are removed in the flag-cleanup phase (FC) after E22 and before E18. Bench "is it good" acceptance moves to E22. A release user can turn a graduated feature off with `-NotchSixtyFeatures -<id>` |
| New engine quality (20 Oct 2026) | The unified graph is at least equal to `N60RenderKernel` in every area and better where it can be; the kernel stays as a frozen fallback until E23 deletes it before v1 |

## Epics at a glance

Twenty-eight epics in four phases close every gap in the analysis and set the engine up for other
platforms; E6 (the unified graph) is the critical path, because eleven later epics build on it.

| ID | Epic | Phase | Depends on | Where the work happens | Done when |
| --- | --- | --- | --- | --- | --- |
| E1 | Trunk, CI and docs hygiene | 1 | — | Claude Code (Mac) | Text validators retired, 3 workflows, living docs current |
| E2 | macOS 26 support | 1 | E1 | Claude Code (Mac) | Full XCTest green on macOS 26 and 27 |
| E3 | Hardware acceptance H01–H08 | deferred to E22 | E2 | Bench | All eight cases pass on `main` |
| E4 | Speaker ANC to class-leading | 1→4 | E1 (bench parts: E22) | Bench + Claude Code | Published attenuation targets met at the seat; live ANC authorised |
| E5 | UI scope clean-up | 1 | — | Claude Code (Mac) | Engineering tools behind a developer menu |
| E19 | MIMO room treatment qualification (ART class) | 1→3 | E4 S3 (bench parts: E22) | Bench + Claude Code | Measured decay reduction at several seats; live treatment authorised |
| E6 | Unified live N-channel graph | 2 | E1, E2 | Claude Code (Mac) | Stereo is a 2-channel layout; every edit is live in every mode |
| E7 | 384 kHz everywhere | 2 | E6 | Claude Code + bench | Every feature passes at 44.1–384 kHz |
| E8 | Routing matrix and crossovers | 2 | E6 | Claude Code + bench | Any-way, any-slope, IIR or FIR crossover on any channel |
| E9 | Multichannel protection and FIR parity | 2 | E6 | Claude Code (Mac) | N-channel lanes match stereo protection and 262k-tap FIR |
| E20 | Engine performance | 2 | E6 | Claude Code (Mac) | Published CPU budgets met at 384 kHz on the slowest supported Mac |
| E21 | Portable C++ core | 2→4 | E6 | Claude Code (Mac + Linux CI) | Core engine and design maths build and pass tests on Linux and Windows CI |
| E10 | Mixed-phase room correction and bass control | 3 | E6, E11 | Claude Code + bench | Beats min-phase in blind ABX at several seats |
| E11 | Measurement suite | 3 | E1 (live overlays on the graph after E6) | Claude Code + bench | Results match REW on the same captures |
| E12 | Guided setup and IA | 3 | E10, E11 | Claude Code (Mac) | New user reaches a verified calibration in one flow |
| E24 | Room correction completion | 3 | E10, E11, E12 | Claude Code (Mac) | Every measure, correction and verify step is reachable from the shipped UI through production wiring; the wizard passes end to end at all eight rates |
| E25 | Outputs and speaker arrangement, one-DAC support | 3 | E24, E12, E8 | Claude Code (Mac) | A 5.1 system on a two-channel DAC through a receiver sets up end to end from the UI; every feature states how it works, or why not, on each configuration |
| E26 | Sub-aware Quiet Zone | 3 | E4 S21, S22b, S25; E25 S8b (bench parts: E22) | Claude Code (Mac) + bench | Quiet Zone designs, limits and arms against the measured path through a sub or receiver; no blanket subwoofer refusal |
| E27 | Equalizer page world-class polish | 3 | E11 S11 (#395) (bench parts: E22) | Claude Code (Mac) | Undo, precise entry, phase and impulse views at every rate to 384 kHz, headroom read-out, EQ A/B, band listen and click-free bypass, all reachable from the Equalizer page |
| E28 | Dynamics and Meters polish | 3 | E27 S4, E6 S12a–S12h (bench parts: E22) | Claude Code (Mac) | Display-rate meters with hold, clip latch and VoiceOver values on every output configuration, BS.1770-4 loudness with channel weighting, spectrum options, transfer curves and gain-reduction history, Equalizer-grade parameter feel, and a world-class dynamics suite (compressor mix, link, detector and optional lookahead; expander hold, knee, detector and sidechain filter; sidechain listen; multiband solo and bypass), all reachable from the Dynamics and Meters pages |
| E13 | Headphones complete | 4 | E6, E7 | Claude Code (Mac) | BYO files to PEQ in one click; live tuning |
| E14 | Upmixer | 4 | E6 | Claude Code + bench | Stereo plays on 5.1–7.1.4 layouts |
| E15 | Device-aware profiles | 4 | E6 | Claude Code (Mac) | Profile follows the output when the user opts in |
| E16 | Automation and remote | 4 | E6 | Claude Code (Mac) | App Intents and the local API ship; the API is ready for a future iPhone client |
| E17 | Export and dither | 4 | E8, E10 | Claude Code (Mac) | MiniDSP, APO and WAV exports; automatic dither |
| E23 | Legacy engine removal | 4 | E6 (incl. S12a–S12h), E4 S11, E7–E17 | Claude Code (Mac) | `N60RenderKernel`, the old N-channel path and the `e6.*` flags are gone; full suite green |
| E22 | Hardware validation | 4 | all software epics | Bench | Every deferred bench check and owner acceptance check (including those that no longer gate a flag graduation) passes on `main` at every rate |
| FC | Flag cleanup (owner, 11 Nov 2026) | 4 | E22 | Claude Code (Mac) | Every graduated flag and its dead branch removed in small per-epic PRs; nightly flags-off CI ran while flags existed |
| E18 | Launch readiness | 4 | all | Owner + Claude Code | Signed, reviewed, accessible, competitive ABX done, App Store live |

## Execution order (owner, 31 Oct 2026; E24 and E25 added 1 Nov 2026; E26 added 4 Nov 2026; E27 added 7 Nov 2026; E28 added 7 Nov 2026)

`/next` works down this list: the first epic with open slices whose dependencies are met. Within
an epic, slices go in their written order. Competitive features come first (what buyers and
reviewers compare with Dirac and REW), then engine depth, then breadth.

0. E24 Room correction completion, all of S0–S8 in written order (owner, 1 Nov 2026; S4–S8 no longer wait for E4; numbered 0 so later item numbers stay valid)
   - then E25 Outputs and speaker arrangement, S1–S8 in written order, before item 1 (owner, 1 Nov 2026)
   - then E4 S22b echo stage in the live path (S22b3 echo stage built dark, PR open; S25 arming built), before item 1 (owner, 2 Nov 2026; arming approved with the four conditions in `docs/epics/E4.md` Open owner decisions: user-initiated only, slow 3 s fade-in, existing gates first, never persisted)
1. E4 class-leading roadmap, S24–S31 in written order (owner, 31 Oct 2026; E4 S11 moved to E22 on 1 Nov 2026; S26 and S29 are skipped until the owner decides camera head position and the overnight power assertion; slices waiting on E8 or the bench are skipped until ready)
   - then E26 Sub-aware Quiet Zone, S1–S7 in written order, before item 2 (owner, 4 Nov 2026; owner 5 Nov 2026: all remaining slices S2–S7 complete before E9 FIR limits (item 4), so E9 S2 waits; S1 waits for E25 S8b; no live ANC path is enabled outside the per-feature arm)
   - then the programme audit of all completed epics, before item 2 and again after every epic completes (owner, 6 Nov 2026; see `docs/epics/README.md`)
   - then E27 Equalizer page polish, S1, S2, S3a, S3b, S2b, S2c, S4 in written order, once #395 (merged 7 Nov 2026) and the plan are merged (owner, 7 Nov 2026; placement before item 4 confirmed, owner decision 7 in `docs/epics/E27.md`)
   - then E6 S12a–S12h legacy-kernel migration, in written order, after E27 S4 (owner, 7 Nov 2026; E6 decisions 13–19): every stage still on `N60RenderKernel`, the old N-channel path or the legacy binaural pipeline moves to the unified graph. E28 S1 starts only after all of them have merged
   - then E28 Dynamics and Meters polish, S1–S6b, S7a–S7d, S8 in written order, after E6 S12a–S12h and before E9 FIR limits (item 4) (owner, 7 Nov 2026; owner decisions 1, 6–8 and 12 in `docs/epics/E28.md`)
2. E12 Guided setup and information architecture, S7 `e12/ship` (merged #243, 26 Oct 2026)
3. E11 Measurement suite, S10 `e11/overlays-and-ship` (merged #222, 25 Oct 2026)
4. E9 Multichannel protection and FIR parity, FIR limits: 262,144-tap program FIR and the 32,768-tap cap (S1 built dark in #361; S2 onward only after E26 S2–S7, owner 5 Nov 2026)
5. E19 MIMO room treatment, software parts
6. E8 Routing matrix and crossovers
7. E13 Headphones complete, remainder (bring-your-own target and AutoEq import merged in #295 and #299)
8. E7 384 kHz everywhere
9. E20 Engine performance
10. E21 Portable C++ core, remaining items
11. E14 Upmixer, E15 Device-aware profiles, E17 Export and dither, E16 Automation and remote
12. E23 Legacy engine removal
13. E29 Shared room position model (owner, 9 Nov 2026: unparked, in v1; plan `docs/epics/E29.md`; flag `e29.room-model`, graduated in S9, removed in FC)
14. E3 Hardware acceptance, then E22 Hardware validation, then FC flag cleanup, then E18 Launch readiness (owner-led, last) (owner, 11 Nov 2026; FC added 11 Nov 2026, flag graduation: epics graduate their flag instead of removing it; FC1, the flags-off nightly, lands before the first graduation)

## Phase 1 — Consolidate and qualify

Phase 1 makes `main` trustworthy on real hardware before any new feature lands.
**Gate G1 (software):** the app builds at the macOS 26.0 deployment target and full XCTest is
green on macOS 27. The hardware half of G1 (H01–H08) moved to E22 with the owner's 18 Oct 2026
decision, so Phase 2 starts without it; every later bench check is collected there too. (Owner, 17 Oct 2026: no macOS 26 machine; 26 support is checked by build.)

### E1 Trunk, CI and docs hygiene

- [x] Add a lightweight feature-flag mechanism so unfinished epics merge to `main` dark (#141)
- [x] Replace the 106 `ci/validate_*.py` source-text checks with behavioural XCTests where intent is still needed; delete the rest (#137, #143–#145)
- [x] Collapse 86 workflows into three: fast PR check, labelled full macOS build and test, release (#142)
- [x] Rewrite `ARCHITECTURE.md` and `DSP_KERNEL.md` for the current design; archive per-PR closure notes into `docs/archive/`
- [x] Archive `docs/ROADMAP.md` (several `ci/validate_*.py` scripts still read it) once those validators are retired; this plan lives in `docs/PROGRAM_PLAN.md`
- [x] Investigate the `SpeakerOptimizerCandidateComparisonTests` runner termination reported in #131

### E2 macOS 26 support

- [x] Set `MACOSX_DEPLOYMENT_TARGET` to 26.0 and fix every compile error with `#available` gates (#132)
- [x] Check every macOS 27-only API and UI treatment for a macOS 26 fallback (#134)
- [x] ~~Add a macOS 26 job to the full CI workflow~~ and ~~re-run H01–H08 on a macOS 26 machine~~:
      dropped (owner, 17 Oct 2026). There is no macOS 26 machine; compatibility is checked by building
      at the 26.0 target, which E1's full macOS build must keep doing. Low priority.

### E3 Hardware acceptance H01–H08

- [ ] Run the PR112A acceptance harness on the merged `main` with the bench DAC, amplifiers and calibrated microphone
- [ ] Cover unplug/replug, sleep/wake with a slow-enumerating USB DAC, live rate changes, Stop/Start, normal Quit and force-quit recovery
- [ ] Cover the #131 manual items: tri-amp acoustic sum, LFE level and limiter on 5.1/7.1 content, worst-case callback time at 384 kHz with all three FIR stages full
- [ ] File each failure as a bug against `main`; G1 waits until all pass

### E4 Speaker ANC to class-leading (runs Phases 1–4)

- [x] ~~Label the Active Acoustics workspace clearly as a preview until qualification~~ (dropped by owner, 18 Oct 2026: still in development)
- [x] Set written, measurable targets: attenuation at the primary seat per band, quiet-zone size, and no audible increase at other seats (proposed in `docs/ANC_QUALIFICATION.md`; owner sets final values)
- [ ] State the physical envelope in the product: broadband feed-forward only works when the reference leads the noise by more than system latency; tonal and periodic noise uses the predictive canceller
- [ ] Add adaptive control (FxLMS-style) with online secondary-path tracking, so cancellation survives people moving and temperature drift; today's filters are designed offline and fixed (core built in S5; tonal shadow wired in S6; feed-forward shadow core in S9a; live output after S10)
- [ ] Lowest-latency output path for ANC: minimum buffer size, a measured latency budget per supported interface, and a supported-hardware list for reference microphones (S7: low-latency profile and table; bench numbers in S8)
- [x] Instability and howl detection with fail-to-mute, alongside the emergency analog mute (guard built, E4 S4; wired with adaptive output in E4 S6; analog mute is a bench check)
- [ ] Run the PR97 hardware timing calibration and the PR99 physical verification campaign on the bench
- [ ] Define the live-ANC authorisation criteria in writing, then switch `liveANCQualified` only through that path
- [ ] Re-qualify on the unified graph after E6 lands, and publish the measurement method for reviewers
- [~] S32 `e4/graduate-flags` (S32 PR: seven flags graduated, G8, G15 closed, end-to-end test; owner decision 11 Nov 2026: build G16; `e4.virtual-microphone` S26a wiring #483 and `e4.head-position-camera` S26b head follow `e4/s26b-head-follow` are wired; `e4.zones` S27 still unwired): graduate the E4 flags (non-live flags first; live-output flags approved by the owner 11 Nov 2026, G17 closed; arm unchanged); wiring of `e4.virtual-microphone`, `e4.head-position-camera`, `e4.zones` first (G16)
- [ ] Class-leading roadmap (owner, 27 Oct 2026; `docs/epics/E4.md` S12–S31): safety foundation (arm hardening, acoustic twin, engine lease, live howl guard, "do no harm" verifier, flight recorder); adaptive tonal live with tone glide, earned cap and excursion cap; upstream reference microphone with cross-device clocking; virtual microphone and head-tracked zones; noise survey, overnight mode, Conversation Focus unmasking, reviewer kit
  - [~] S30a `e4/unmask-ambient-stage`: `AMBIENT` stage carries up to 17 live cut-only peaking sections (ABI v32); built, but nothing sets the cuts until S30c, so the stage is dark; wired by S30c
  - [~] S30a overlay: `AmbientUnmaskOverlay` section fit and trailer builder built dark behind `AmbientCompensationTarget.unmaskingCutsDB`; wired by S30c
  - [x] S30c `e4/unmask-wiring`: controller cuts, governor, engine validation and Conversation Focus card built behind `e4.conversation-unmasking`; #468 merged; carry gaps G12–G14 in S30d; bench: E22 S30 checks
  - [x] S30d `e4/unmask-rebuild-carry` (#476): AMBIENT state carried across rebuild (G12), controller end-to-end tests (G13), locked graph-fallback read and transport-teardown reset (G14); merged; `e4.conversation-unmasking` graduated in S32; G15 closed there; bench: E22 S30 checks

### E5 UI scope clean-up

- [x] Move Hardware Acceptance and Acoustic Research to a hidden developer menu (#153)
- [x] Order the dynamics navigator by signal chain and fold niche processors (denoiser/de-hiss, de-esser, expander, DC offset, oversampling) under "More" within each group (revised with owner, 18 Oct 2026) (#154)
- [x] Fold Speaker Measurement Lab directivity tools into an Advanced tab; quasi-anechoic has no UI yet and moves to E11 (owner, 18 Oct 2026)

### E19 MIMO room treatment qualification, ART class (runs Phases 1–3)

The MIMO designer, FIR compiler and live runtime already exist but are hardware-gated (PR73–PR77);
Dirac now sells ART on the Mac, so this needs the same path to authorisation as ANC.

- [ ] Bench campaign with two or more subwoofers plus mains: modal decay (T20/T30 below 150 Hz) before and after at several seats
- [ ] Speaker support-range and exclusion controls, and an explicit LFE time target
- [~] S4 `e19/mimo-stage`: realtime `N60_STAGE_MIMO` (ABI 32) built dark, not published until S6 (see `docs/epics/E19.md`)
- [~] Headroom and excursion safety per contributing speaker: S5 `e19/mimo-safety` built dark, PR open; not published until S6 (see `docs/epics/E19.md`)
- [ ] Authorise live treatment only through the PR75 verification path, then re-qualify on the unified graph
- [ ] S11 graduate `e19.mimo-treatment` (available, never armed; arm and permit unchanged; the bench no longer gates it; removal is the FC phase)

## Phase 2 — Unified engine

Phase 2 replaces the three render paths with one graph that every later feature builds on.
**Gate G2:** stereo output matches today's kernel on the parity suite within -120 dBFS peak
(deliberate improvements excepted where the reference lab shows them equal or better), and live edits are click-free on hardware in stereo, 5.1 and binaural modes.
Gate G2 passed on 2026-10-25 (commit 07e82c6)

### E6 Unified live N-channel graph

- [x] Write a design note (`docs/epics/E6.md`, awaiting owner approval): lane stage list, snapshot layout, latency alignment, coefficient ramping, rebuild-with-fade rules, threading and multirate boundaries
- [x] Build the unified graph in C++ from the start, per the engine-language decision (E21) (`core/`, libn60core)
- [x] Give every lane the full stereo stage set: PEQ, M/S where paired, dynamic EQ, dynamics, FIR, delay, protection (S9a, #203)
- [x] Represent stereo as a 2-channel layout and the binaural renderer as a stage, not a separate transport
- [x] Make parameter edits live with ramped coefficients; rebuild with a short fade only on topology changes (S6, S9b #205)
- [x] S8c `e6/dynamics-readbacks`: gain-reduction, true-peak and over-range readbacks through a core ABI addition (#187; diagnostics UI row and two tests follow up)
- [x] S8e `e6/rack-and-routes`: AU rack as an external-processor node; same-device and aggregate routes render through the graph
- [x] S8d `e6/translate-remaining-stereo` (#195, #203): move the kernel-fallback stereo stages (dynamic EQ, FIR/IR/convolution, mixed phase, crossover and bass management, denoiser, fractional delay, soft clipper, gain rider) to the graph
- [x] Remove the `unsupportedActiveDSP` and `immutableSemanticTransportActive` restrictions in `AudioIOEngine.swift`, and the idle-only headphone profile rule (lifted on the graph path, the default since S11, by S9a–S9d; the copies kept for the `e6.legacy-kernel` fallback go with the kernel in E23)
- [x] Build a parity suite that renders the old stereo kernel and the new graph side by side (S8b2a stage parity, S10 #209; the graph-vs-kernel full-config corpus is left open in `docs/epics/E6.md`)
- [x] Make the graph the default once parity holds; keep `N60RenderKernel` as a frozen fallback behind a flag until E23
- [x] S8b2a `e6/engine-integration-3` built on branch (needs-owner, behind `e6.unified-graph`): graph reproduces M/S EQ, compressor, expander, ambient compensation, symmetry, crossfeed, crosstalk cancellation, integer inter-channel delay and pause gate; everything else keeps the kernel fallback
- [x] S8b2b: translate dynamic EQ, FIR/room/speaker IR, stereo crossover and bass management, denoiser, soft clipper and gain rider (or document keep-on-kernel); wire multichannel, layouts, 1 to 8 subs and binaural into the live N-channel session; metering and latency readbacks; compensate kernel/graph latency difference across the hand-over fade
- [x] S8b2c (next): wire live binaural into the N-channel session (it has no binaural mode today) and compensate kernel/graph fade latency (the N-channel path attaches the graph statically, with no mid-stream hand-over). S8b2c is split: S8b2c1 built on branch `e6/engine-integration-5` (needs-owner); S8b2d awaits owner approval of the binaural proposal
- [x] S9b `e6/live-session-edits` (needs-owner): setters live while an N-channel or binaural graph renders, with a fresh-build equality test at eight rates; bench in E22
- [x] S9c `e6/live-headphone-profile` (needs-owner): headphone profile edits live on graph-rendered binaural sessions, asset swap off the main actor, ear delay stages; bench in E22
- [x] S12 legacy-kernel migration (owner, 7 Nov 2026; after E27 S4, before E28 S1; all needs-owner, engine; no new flag, `e6.legacy-kernel` stays the escape hatch until E23; eight-rate kernel parity within E6 decision 1). Remaining open items are owned by E8 S11 (G32), E22 (bench), E23 (G1, G18, G25, G30, G31, G37, G48) and E28 S7c (G23).
  - [x] S12a DC offset, infrasonic, mains notch and hum detector in the core (migration audit table row 1 done, `docs/epics/E6.md`; PR #464)
  - [x] S12b stereo mode, widener, de-harsh and de-esser in the core (`e6/port-image-and-deess`, #409, ABI v23; built in the core, wiring: S12g for N-channel (G12) and S12f for state carry and refusals (G11, G13, G14); bench: E22). Remaining owner: E22 only (G15).
  - [x] S12c loudness match, loudness contour, per-band loudness and dialogue leveler in the core
  - [x] S12d multiband compressor in the core, with per-band auto release (closes E28 G11; `e6/port-multiband`, #412, ABI v25; per-band auto release is core-only, wiring: E28 S7c; bench: E22). Remaining owners: E28 S7c (G23), E23 (G25), E22 (G26 bench).
  - [x] S12e stereo global bypass and reference audition on the graph (D5, parity exception P1) and wide PEQ (over 16 sections, types 8–10) built (`e6/port-bypass-audition-eq`, #413, ABI v26); delta audition and the bypass lab case remain (G27, G28); bench: E22 (G29). Remaining owners: E22 (G29), E23 (G30, G31).
  - [x] S12f stereo crossover and room/IR with subs, oversampling-only protection, the three ordering guards and named refusals built (`e6/port-stereo-subs-and-guards`, PR #414, ABI v27); stereo crossover with subs refused as `crossoverWithSubwoofer` (G32 open question; no wiring slice); state carry and the UI-range tests moved to S12f2 (G33–G35). Remaining owner: E8 S11 (G32): translator built (PR #464), production wiring open (E8 G3).
  - [x] S12f2 `e6/stage-state-carry` (PR #464): cleanup, image and de-ess state carry, double-precision cleanup, UI-range property test and oversampling latency asserts built; G36 and G38 closed in S12h. Remaining owner: E23 first slice (G37).
  - [x] S12g old N-channel and legacy binaural path reasons onto the graph; `binauralBudget` raised within measured cost, refused beyond (E6 decision 18); part 1 (#416) polarity and 48 dB crossover; S12g2 lane delay under bass management (ABI v28); S12g3 (G39) and S12g4 (#419, ABI v29): optimizer FIR with program FIR, N-channel cleanup, image, loudness, de-ess, multiband, no-legacy and eight-rate tests; per-rate binaural cost is an E22 bench item (G43)
  - [x] S12h stereo Active Quiet Zone on the graph, authorisation unchanged (needs-owner, ANC; E6 decision 15): part 1 (#420) and part 2a (G20, G22, G26, G45 closed) built; part 2b (#422, G46 closed); part 3 (ABI v31, G50 to G52 closed, PR #464). Remaining work is bench only, in E22.

### E7 384 kHz everywhere

- [~] Express every buffer capacity in time, not frames, and size it at the 384 kHz worst case (E7 S1 done; E7 G2-G4 close in S5, G1 in E23)
- [~] Lift the known frame caps: program FIR 32,768 taps, headphone delay 4,096 frames (headphone delay to 20 ms done in E7 S1; kernel 4,095 limit stays until E23, E7 G1) (binaural 8,192 taps moved to E13, owner 31 Oct 2026)
- [ ] Extend the PR117A double-precision fix beyond the crossover: user EQ, lane EQ, subwoofer EQ and headphone PEQ still use float32 coefficients and state, which loses low-frequency accuracy at high rates
- [ ] Keep HRIR resampling on activation; add the same policy for any imported IR or SOFA asset
- [ ] Run the XCTest acoustic reference lab at 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz
- [ ] Check Audio Unit hosting: report clearly when a plug-in refuses a rate
- [ ] Bench: confirm CPU headroom at 384 kHz on the slowest supported Mac
- [ ] S5 `e7/rate-matrix-ship` graduates `e7.rate-adapt` (default on; removal is the FC phase)

### E8 Routing matrix and crossovers

- [x] Replace Mains+Sub / Bi-Amp / Tri-Amp modes with a source-to-output matrix and a per-output filter chain
- [x] Filter library: Butterworth, Bessel, Linkwitz-Riley at 6–48 dB/oct, asymmetric slopes, Linkwitz transform
- [x] Any number of ways per speaker, on any layout, not stereo only
- [x] Linear-phase FIR crossovers reusing the Speaker Optimizer's linear-phase synthesis
- [x] Driver linearisation from Measurement Lab near-field captures
- [x] Raise the subwoofer limit from 4 to 8 (core bass management already supports 8 sub lanes since E6 S7b, ABI v7)
- [x] Advanced pipeline view for power users, plus CamillaDSP YAML import alongside the existing export
- [x] Migrate existing bi/tri-amp profiles automatically
- [~] Stereo crossover with subwoofer lanes (E8 S11 merged #431; S11b `e8/crossover-subs-nchannel` wires it into the N-channel session, PR #464; G2, G3, E6 G32 closed there; G4 bench wiring checks open in E22)

### E9 Multichannel protection and FIR parity

- [~] Per-output limiter, true-peak guard and soft clip, matching the stereo chain (E9 S5 built dark behind `e9.output-protection`; wiring: E9 S5b for the Outputs UI and S5c for routed outputs, binaural and debounce done; G17 dropped by the owner)
- [~] Move the program FIR onto the 262,144-tap non-uniform convolver (E9 S1 built dark; S3 sets firScheme 1 and lifts the Swift guards behind e9.long-fir, PR #464; flag stays dark until S2c and E22 bench)
- [~] Long FIR rebuild: lockstep lazy carry with 256 KiB per-callback budget, changed-tap seeding, chunked or O(1) scheme 1 reset (E9 S2 built dark, PR #464; S3 wires Swift behind e9.long-fir; S2b follow-ups and E22 bench items open)
- [ ] S8 `e9/graduate-flags`: graduate `e9.long-fir` and `e9.output-protection` (default on) once the `[~]` software items close; bench items move to E22; removal is the FC phase
- [~] Per-output headroom assistant (E9 S6 core maths `n60/headroom.h` merged; E9 S7 Swift model, readout and Apply/Undo built behind e9.output-protection, PR #464; S7b coverage and bit-exact Undo test next)

### E20 Engine performance

Performance comes from architecture rather than language: whole-buffer processing, multirate
paths, SIMD, multiple threads and the right algorithms. Today the stereo bridge calls the whole
chain once per frame, with no SIMD, on one thread.

- [ ] **Whole-buffer processing:** each stage processes the full buffer instead of the per-frame `N60RenderKernelProcessStereoFrameInContext` call; fuse adjacent stages with templates so audio stays in cache
- [ ] **Multirate:** run ANC, MIMO room treatment, subwoofer and bass-management processing and low-frequency analysis at decimated rates (32–64× below 384 kHz), with polyphase decimation and interpolation and exact latency accounting
- [~] **SIMD:** Google Highway with runtime dispatch (NEON, SSE, AVX2, AVX-512); vectorise biquad cascades across channels (E20 S3 `e20/simd-biquads-and-loops` built, partial: in-house portable layer `core/src/simd/simd.hpp` (design note 5, replaces Highway) with PEQ, XOVER, PROTECTION half-band, meters, M/S; remaining cascades and loops G14 (owner S10); E20 S4 `e20/fft-and-convolution` (PR #464, needs-owner) added the SIMD complex MAC and the half-band dot product; radix-4 FFT G16 and the x86 FMA default G17 owner S10)
- [~] **Multiple threads (E20 S5 `e20/parallel-render-core` built, partial: core worker protocol, FIR lane jobs and deterministic join done and bit-identical at 0 to 3 workers; Apple host threads and workgroups built in E20 S6 `e20/audio-workgroups` behind `e20.parallel-render`, dark; the long-tail job is E20 S6b):** Audio Workgroups on Apple (and the equivalent realtime thread groups elsewhere) for lanes, MIMO and long convolution, with a lock-free job graph and a deterministic join before output
- [ ] **Right algorithms:** non-uniform partitioned convolution in every FIR path (program FIR, binaural, MIMO), long partitions spread across callbacks, double-precision or state-variable filters at high rates, polyphase sample-rate conversion
- [~] Set flush-to-zero at callback entry instead of scanning every sample for denormals; keep the NaN guard at the output (E20 S2 `e20/fp-env-and-rt-checks` built, partial: FTZ guard at graph and bridge entry done; per-sample flushes removed in E20 S3 `e20/simd-biquads-and-loops` (G10 closed); zero-tail tests for the removed flushes done in E20 S4 with no-subnormal checks only; tails not settled to zero is G18, owner S10)
- [~] RealtimeSanitizer plus `nonblocking` / `nonallocating` attributes on every realtime entry point, run in CI (E20 S2 `e20/fp-env-and-rt-checks` built, partial: `core-rtsan` job and core function-effects annotations done; bridge callbacks cannot take the attribute and parity suite is not under RTSan: G9, G11, E20 S10)
- [~] CI benchmarks: per-stage ns/sample and worst-case callback time at 48, 192 and 384 kHz, with fail thresholds (E20 S1 `e20/bench-baselines` built, PR #448: harness, profile hooks, `macos-full` step, `budgets.json` warn only; baseline JSON is an owner step after the first nightly (G2); fail enforcement wiring is E20 S10 (G3))
- [ ] S10 graduates `e20.parallel-render` and `e20.multirate` (default on, before the E22 bench); removal is the FC phase after the bench shows no overloads with workers
- [ ] UI: move `ObservableObject` controllers (23 `@Published` in `AudioIOEngine`, 33 in `RoomTreatmentAdvisorController`) to `@Observable` (drawing meters with Canvas at display rate moved to E28 S1 and S5, owner, 7 Nov 2026)
- Moved to E28 (owner, 7 Nov 2026): user-facing dynamics meters from the E6 S8c readbacks (gain reduction on the compressor, expander and limiter controls in E28 S5; true-peak beside the output meter and a latching over-range indicator in E28 S1)

### E21 Portable C++ core (starts with E6, runs to Phase 4)

A Linux build test (17 Oct 2026, clang) shows the C engine is close: 9 of 17 C files compile
unchanged. The rest fail on a missing `<stddef.h>`, the Accelerate-based convolver, and Core
Audio types in four bridges. The bigger gap is the DSP maths inside the Swift designers
(room-correction FIR and targets, measurement analysis, optimisers), six of which use Accelerate.

- [ ] Adopt C++20/23 for the whole core, behind one versioned C interface; migrate existing C file by file as E6 rewrites each stage
- [ ] Write the realtime subset rules: no allocation, locks, exceptions or RTTI on the audio path, enforced by RealtimeSanitizer and review
- [ ] Split into `libn60core` (realtime graph plus design maths), per-platform audio backends, and per-platform app shells
- [ ] FFT abstraction: vDSP on Apple, PFFFT or KissFFT (BSD) elsewhere; no FFTW, which is GPL
- [ ] Choose a linear-algebra library after licence review (Eigen is MPL-2.0)
- [ ] Replace `AudioBufferList` in the bridges with plain non-interleaved float buffers; keep Core Audio in the macOS backend
- [ ] Move the DSP maths out of Swift into the core in order of value: measurement analysis, room-correction FIR and target design, multi-sub and MIMO design, speaker optimiser, ANC design
- [ ] S14 graduates `e21.core-designers` (default on); deletion of the Swift implementations and the flag is the FC phase
- [ ] Shared JSON schemas for profiles and projects
- [ ] CMake build, with Linux and Windows CI running the core tests and the acoustic reference lab
- [ ] Update `AGENTS.md`: the core may not depend on Apple frameworks, plus the C++ realtime rules
- [ ] Keep Swift for the macOS shell, Core Audio control and UI

## Phase 3 — Correction and measurement

Phase 3 closes the Dirac and REW gaps. **Gate G3:** mixed-phase correction is preferred over
minimum-phase in blind ABX at three or more seats, and measurement results match REW within
0.5 dB on the same captures.

### E11 Measurement suite (start first; E10 uses it)

- [x] Repeat-sweep averaging and an acoustic timing reference for separate-clock USB microphones
- [x] RTA with selectable fractional-octave resolution, plus an SPL meter and logger with A/C/Z weighting
- [x] Signal generator: pink and white noise, band-limited noise, tones, for level matching and listening checks
- [x] Waterfall / CSD and spectrogram from the existing impulse response
- [x] Harmonic distortion (H2–H5) from the log sweep's negative-time impulses
- [x] RT60 and EDT per octave and third-octave band
- [x] Simultaneous multi-microphone capture to speed up multi-seat measurement
  - [x] S9a processing: one record per seat from K simultaneous captures (shared-clock and separate-USB modes); K-input transport and seat picker in S9b
- [x] Measurement management: overlays, groups, notes, A/B against a reference
- [x] Quasi-anechoic (gated) speaker response view in the Measurement Lab's Advanced tab, using the existing analyser (`SpeakerMeasurementLabQuasiAnechoic.swift`; from E5)
- [ ] Import and export REW text, FRD and ZMA; a cross-check suite against REW on shared captures

### E10 Mixed-phase room correction and bass control

- [x] Excess-phase correction with frequency-dependent windowing, built on the PR129 research designer
- [x] Pre-ringing limits and a latency budget; keep minimum-phase as a low-latency / video mode
- [x] Multi-seat robustness: correct only phase that is coherent across seats, with per-seat weighting
- [x] Joint mains-and-subwoofer bass optimisation across all channels (Dirac Bass Control class), not subwoofers alone
- [x] Target editor with curtain, limited-range, per-channel offsets and saved target library
- [x] Flip `canDeploy` only through the verification path, with prediction and post-apply measurement
- [ ] Bench: blind ABX against minimum-phase on the reference room

### E12 Guided setup and information architecture

- [x] One "Set up my system" flow: topology, levels and polarity, distances, multi-seat sweep, bass, correction, verification, saved profile
- [x] Merge Speakers, Speaker Calibration, Measurement Lab and Room Correction into a clear System area
- [x] Surface the room geometry and treatment advisor inside the flow
- [ ] Usability test with someone who has never seen the app

### E24 Room correction completion (owner, 1 Nov 2026)

Plan: `docs/epics/E24.md`. E10–E12 are ticked done, but the Level step, the Measure tab generator,
post-apply verification, mixed phase in the wizard and several E11 views are not reachable from
the shipped UI.

- [x] End-to-end wizard harness through production wiring at all eight rates; no `Unconnected*` production defaults
- [x] Measurement-owned level session: Level step and Measure tab generator play noise without normal playback
- [x] One measurement-readiness result with reason text under every disabled measure button; every measure path stops playback with a notice
- [x] E24 S2b closed by owner decision (3 Nov 2026): optimizer, characterization, FIR-verify, evidence, guided-workflow and Quiet Zone survey controllers keep refusing `playbackMustBeIdle`; `deployLatestDesign` keeps requiring idle
- [x] Real post-apply verification; wizard offers mixed phase; joint-bass grid filters deployed
- [x] E11 leftovers wired: repeat averaging and timing in Room Correction and multichannel; Analysis tab (distortion, RT60/EDT)
- [x] E12 leftovers: shared microphone and seat cards; wizard multi-mic pass; target shaping persists (E24 S5, #323 to #328)
- [x] E24 S11 audit leftovers: tab Deploy guard, verifier joint-bass paths, Verify from idle (G1 closed)
- [~] Acceptance: harness green with no expected-fails (done, S6); owner smoke checklist pending, after E24 and E25 (open audit items in `docs/epics/E24.md`)
- [x] Process safeguards done (AGENTS.md section 12); ledger audit of E4, E6, E8, E9, E13 done (S8)
- [x] S9 `e24/abx-wiring` (#335): UI caller for `RoomCorrectionABX` (E10 S9)
- [x] S10 `e24/ledger-fixes`: E4 S21 excursion lower limit, E6 S5 and E8 S6 wiring checks

### E25 Outputs and speaker arrangement, one-DAC support (owner, 1 Nov 2026)

Plan: `docs/epics/E25.md`. Output channels and the speaker arrangement become separate concepts,
so a 5.1 system on one two-channel DAC (for example into an AV receiver) gets every feature two
channels allow, and the UI gives a reason for each one that it cannot.

- [x] Arrangement model, compiler (two channels stay on the stereo session), capability matrix and profile migration (built dark; wired by S3 and S5)
- [x] Mono bass on the pair with selectable family, slope and frequency; per-feed trim, delay and polarity (built dark; wired by S3)
- [x] Wizard Outputs and Speakers steps; the flow creates the arrangement from the UI; session schema 2 (wired by S3; readiness reason replaced in S5; profile-load alignment and shortcut removal done in S8c)
- [x] Alignment, bass and correction adapt to how bass is handled; receiver advice
- [x] Capability text on every surface that offers a choice
- [x] Quiet Zone and MIMO on two channels: MIMO sources limited to the L and R feeds (done); Quiet Zone eligibility built dark (wired by S8)
- [x] Quiet Zone and MIMO eligibility on two channels (never live outside authorisation)
- [x] Fold-down of 5.1/7.1 from a wider program source to the two feeds (owner: in v1) (built dark in S7; S8a built dark; wired by S8b)
- [x] Owner configuration end to end at eight rates; flag removed

### E26 Sub-aware Quiet Zone (owner, 4 Nov 2026)

Plan: `docs/epics/E26.md`. Quiet Zone today refuses feed-forward live with a subwoofer or bass
management (E4 question 18), so a system with a sub behind a receiver has no live Quiet Zone. E26
measures the path the anti-noise really takes, sub included, and designs, limits and arms against
it, behind `e26.sub-aware-anc`. Live output stays behind the per-feature arm.

- [~] Bass-path model, fingerprint and plain measurement record; receiver bass declaration (open preout or calibrated LFE out) with a setup note, refusing only when undeclared; mono bass on the pair no longer counts as a sub; acoustic twin with a sub
- [~] Secondary path and leakage measured through the whole feed; anti-noise latency per band; echo set with a sub (absorbs E4 S22c). Built dark: per-band delay, per-band eligibility, open-preout check and sub-aware echo rule; S2b (#365) built dark the leakage sweep, its fingerprint stamp and the echo inputs under the flag. Remainder: S2c (secondary-path sweep, splitter rendering, position-model stamp, 20 dB echo twin test) and S5 (arming)
  - [~] S2c `e26/through-feed-splitter-render` (#366): built dark the splitter-rendered through-feed sweep, position-model stamp and 20 dB echo twin test; not wired to hardware outputs (S6a built the transport dark; S6b wires it); bench: E22
- [ ] Conditioned L/R design where both channels share the sub (common-mode constraint), tonal and feed-forward
  - [~] S3b `e26/rank-one-bass-wiring` (PR #377): built behind `e26.sub-aware-anc`; bench: E22
  - [~] S4 `e26/sub-safety` (#368): receiver excursion caps, measured summing law, bass-path watch and combined-leakage bound behind `e26.sub-aware-anc`; bench: E22
- [ ] Sub safety: receiver crossover in the excursion caps, path-gain watch that disarms, combined leakage stability bound
- [~] Sub-aware readiness replaces the blanket refusal; setup UI; end-to-end twin harness at eight rates
  - [~] S5 `e26/sub-aware-arming` (PR #377): `SubAwareAncReadiness` feeds tonal `setEnabled` and feed-forward stepWaiting/stepPlaying (`subAwareRefusal`); setup card `ProductionSubAwareQuietZoneCard`; missing plant and multi-seat sub refused; twin harness at eight rates through UI-model calls, survey-to-arm twin wired by S6; bench: E22
  - [~] S6a `e26/sub-multibus-transport` (#370)
  - [~] S6b `e26/sub-readiness-from-sweeps` (#372): open-preout check, per-band eligibility and sub-band render verification feed readiness behind `e26.sub-aware-anc`; multi-bus profile-session passes and the `measureSubPath` harness move to S7
  - [~] S6c `e26/sub-multiseat-plant` (#373): measured per-seat 2x2 plant in the spatial planner, conditioning and the stricter-of rule in the controller, behind `e26.sub-aware-anc`; driving the multi-seat branch through production wiring moves to S7 (G12)
  - [~] S7b `e26/profile-anc-host-feed`: S7b1 (#376) built the N60AncLaneFeed host feed dark; S7b2 part 1 (#378) registers the feed and the engine routing; S7b2b part 1 (#379) built the engine profile branch; S7b2c part 1 (#380) built the reference taps, host time and tonal gate; S7b2c part 2 (#381) added the class A end-to-end, guard, revoke and latency tests; the S7 software leftovers (Room Correction output-gain stamp G17, G31, G32, multibus measure test) are in PR #464; remaining: E22 bench gaps and flag removal
- [ ] Quiet Zone with a sub on its own output (profile session, sub lane as an actuator)
  - [~] S6: run `OpenPreoutCheck` on measured sweeps and set `openPreoutRefusal` (S6b, behind the flag)
  - [~] S6: feed `PerBandAncEligibility` (`feedForwardBandCount`) from `CombinedPathBandAnalyzer` into readiness (S6b, behind the flag)
  - [~] S6: multi-seat sub support with a measured per-seat 2x2 plant (S6c, behind the flag; built dark)
  - [ ] S6: full end-to-end twin harness from sweeps
  - [~] S7 `e26/ship` (#374), part 1: `e26.sub-aware-anc` defaults on, G5 and G12 closed; G1 host feed open (G9 closed in S7c), so S7 is not ticked and the flag stays
  - [x] S7c `e26/profile-sub-measurement` (PR #377): class A sub measurement (two seat passes, nine leakage passes, per-output leakage, record schema 2) reachable from the sub button under `e26.sub-aware-anc`; class A arming waits for S7b; bench: E22
- [ ] Flag graduated (E26 S7: `defaultEnabled` becomes `graduated: true`; software gaps closed, bench-only gaps moved to E22; owner decision 11 Nov 2026 replaces "removed after the E22 sub bench checks"); removal is the FC phase

### E27 Equalizer page world-class polish (owner, 7 Nov 2026)

Plan: `docs/epics/E27.md`. Baseline PR #395 (E11 S11 band panel). Feel, filter views and safety
on the Equalizer page; S1 and S2 flagless, the engine-facing S3 items were behind `e27.eq-safety` (removed in S4).

- [x] S1 feel and precision: hover read-out, Q by scroll or pinch, double-click add and reset, axis-locked and fine drag, keyboard nudging, unit-aware number fields, undo and redo
- [x] S2 filter views: band curves, other-lane ghost, y-range and auto, x-range to 0.49 fs at every rate, phase, group delay, impulse and step from the engine's filter math (lab case moved to gap G6, owned by S4)
- [~] S3a headroom badge with post-EQ clip light, auto preamp, preamp and output gain on the page (PR #464): badge and page gains reachable; auto preamp built behind `e27.eq-safety` until S4 removes the flag; bench: E22
- [~] S3b EQ-level A/B with loudness match, band listen, click-free bypass proved at eight rates (PR #464)
  - [~] EQ A/B built dark behind `e27.eq-safety`; prepared linear-phase FIR designs are cached in S3c (G10 closed); flag removal in S4
- [x] S3c `e27/eq-ab-fir-prewarm` prepared FIR programs for linear-phase A/B and engine-level tests (G10, G11; owner slice for both)
- [~] S2b program analyser overlay (Input and "Output (full chain)" spectrum on the existing render capture, no engine tap; built dark behind e27.eq-safety, PR #405; the EQ-only view is S2c)
- [~] S2c `e27/analyser-eq-taps`: EQ-only and EQ + Dynamics spectrum taps with a toggle (needs-owner, realtime; owner, 7 Nov 2026; built dark behind e27.eq-safety, PR #464; G16 and G17 and flag removal to S4)
- [x] S4 `e27/ship` flag `e27.eq-safety` removed, offline lab cases, end-to-end tests and dynamic metric fields (PR #407, needs-owner); live-window and DAC remainders are E22 items (owner decision 7 Nov 2026)

### E28 Dynamics and Meters polish (owner, 7 Nov 2026)

Plan: `docs/epics/E28.md`. Absorbs E20's dynamics-meter and Canvas items; E28 owns the Meters page.
S1–S6b flagless; every dynamics extra (S7a–S7d) behind the one flag `e28.dynamics-extras`. Scope widened 7 Nov 2026 (owner): anything useful in playback toward a world-class dynamics suite, latency only when optional; external sidechain input stays out.

- [x] S1 meter levels: display-rate bars, true-peak bars, peak hold, latching clip with reset, ballistics, VoiceOver values, pause when hidden
- [x] S2 loudness: momentary, short-term, integrated with reset, loudness range and true-peak max per ITU-R BS.1770-4 and EBU R128; per-channel weighting with LFE excluded (inert until the capture carries more than stereo)
- [x] S3 spectrum options: smoothing, averaging, tilt, freeze and reference trace, hover read-out, input and output overlay
- [ ] S4 dynamics feel: log sliders, unit-aware fields, stepping, reset, fine drag, undo, sidechain range fix, auto makeup, accessibility
- [x] S5 dynamics visualisation: transfer curves, gain-reduction bars and history, navigator bars; built, PR #464 (G21 to S7d, G22 to S6, G23 to S7d, G24 to S7b; Loudness readouts moved to S7d)
- [x] S6 per-output and sub meters on every output configuration, per-route bridge meter, E9 protection on the hub (needs-owner, PR #464)
- [x] S6b loudness fed the semantic program channels on N-channel and binaural sessions, loudness and dynamics lab cases, L/R over-range pairing (needs-owner)
- [~] S7a compressor mix, link amount, peak/RMS detector and optional lookahead, reported in the path latency (needs-owner, engine; built dark behind `e28.dynamics-extras`, PR open; wiring in S7d, G10 open)
- [~] S7b expander hold, soft knee, detector, sidechain high-pass and link; sidechain and delta listen (needs-owner, engine; built dark behind `e28.dynamics-extras`, PR pending; wiring in S7d)
- [~] S7c multiband extras on the core stage ported by E6 S12d: per-band bypass, solo, listen and detector, one lookahead, auto-release toggle (needs-owner, engine; built dark behind `e28.dynamics-extras`, ABI v37, PR pending; wiring in S7d; G39, G40)
- [~] S7d Dynamics page controls for every extra, disabled with a reason where the kernel renders (part 1 built behind `e28.dynamics-extras`: rows, listen, solo, banner, G8, G19, G36; part 2 built: zero-allocation cases, latency totals, double RMS and ring sanitising, G10 and G33 except the AV-sync caller (G41); part 3 open: lab cases, translator tests, readouts, G21, G23, G26, G34, G35, G37, G39, G40)
- [ ] S7d part 3 (re-owned from part 2; holds the open remainder of G21, G23, G26, G34, G35, G37, G39, G40): `ReferenceRoomTransport` lab cases (compressor extras, expander extras, three-band solo), translator XCTests (10 to 16, 6 to 13, 29 to 43), link-0 and fade-law tests, surfacing the failed listen clear, RMS block-pass of the delay ring and mix, ring carry across a rebuild, Loudness Match and Contour readouts, the 0.1 dB core-versus-curve sweep, and the 0.245 dB gap.
- [ ] S8 flag graduated (after S7a–S7d; the owner's listen moves to E22; removal is the FC phase)

## Phase 4 — Complete scope and launch

Phase 4 finishes the remaining scope and prepares the launch. **Gate G4 (v1):** every epic
complete, speaker ANC qualified, and a full hardware regression passing at every rate from
44.1 to 384 kHz.

### E13 Headphones complete

- [x] Bring-your-own import: AutoEq CSV, REW and squig.link frequency-response text, plus user target curves
- [x] One-click PEQ from an imported response and a chosen target, using the existing model fitter
- [~] Live PEQ and crossfeed tuning while playing (from E6): S3 built behind `e13.headphones` (`e13/live-headphone-tuning`, PR #456; needs-owner); bench in E22
- [~] Raise the HRIR cap for room-included BRIRs (S4 `e13/brir-long-tail` built behind `e13.headphones`, PR pending, needs-owner; SOFA long import is limit-level only, G10; wiring: E13 S8); live HRTF interpolation with head tracking (S5)
- [ ] S8 `e13/ship` graduates `e13.headphones` (default on) once S5 and the software gaps close; bench gaps move to E22; removal is the FC phase
- [~] In-ear-microphone BRIR capture for personal virtual speakers (S6 core merged; S7 guided flow built behind `e13.headphones`; bench in E22)

### E14 Upmixer

- [ ] Stereo to 5.1, 7.1 and 7.1.4 with centre extraction and ambience to surrounds
- [ ] Per-layout presets and a bypass for content that is already multichannel

### E15 Device-aware profiles

Plan: `docs/epics/E15.md` (awaiting owner approval; flag `e15.follow-output`).

- [ ] Opt-in "follow system output" mode that recalls the profile bound to each output UID
- [ ] Keep today's fixed-output policy as the default
- [ ] S4 `e15/ship` graduates `e15.follow-output` (default on; the mode still defaults to fixed; removal is the FC phase)

### E16 Automation and remote

- [ ] App Intents and Shortcuts for profile, volume, mute, bypass and correction on/off
- [ ] Local authenticated REST/websocket API, off by default

Owner decision, 11 Nov 2026: the iPhone remote moved to the post-v1 "iPhone companion app" entry
under "Platform reach after v1". The local API must stay usable by that future iPhone client
(documented, versioned, authenticated pairing that a phone can complete).

### E17 Export and dither

Plan: `docs/epics/E17.md` (awaiting owner approval; flags `e17.export`, `e17.dither`).

- [ ] Filter export to MiniDSP, Equalizer APO and WAV convolution sets
- [ ] Automatic TPDF dither only when the device's physical format is 16-bit integer
- [ ] S5 `e17/ship` graduates `e17.export` and `e17.dither` (default on; removal is the FC phase)

### E23 Legacy engine removal

Owner decision, 20 Oct 2026: the kernel stays behind `e6.legacy-kernel` until late in the roadmap,
then this epic deletes it before E22 hardware validation, so v1 ships and is validated on the
unified graph only.

- [~] First slice (owner decision 7 Nov 2026, E6 G1): graph-vs-kernel full-config corpus (every stage on, all layouts, eight rates) plus the E6 S5 stereo-chain parity and latency test (latency report equals measured impulse delay). `N60RenderKernel` must not be deleted until it is green. S1 `e23/graph-kernel-parity` built in part (PR #464); the rest is S1b `e23/precision-and-cleanup`
- [~] S1b `e23/precision-and-cleanup` (PR pending, needs-owner, engine): double state for E6 G18, G25 and the Linkwitz form for G31 built; cleanup whole-buffer pass (E6 G37) partly built, per-section hoisting open as E23 G5; wiring slice: graph path, not yet on the shipped UI as a separate check
- [ ] S1c `e23/parity-and-host-fold` (needs-owner, engine): G2 latency report at 44.1 and 88.2 kHz, G3 clipped-input level difference, E6 G48 Quiet Zone host fold
- [ ] Confirm nothing falls back to the kernel, the old N-channel path or the legacy binaural pipeline (E6 S12a–S12h)
- [ ] Remove the kernel headphone-delay clamp (4,095 frames) with the kernel (E7 G1)
- [ ] Delete `N60RenderKernel`, the old N-channel path and the `e6.legacy-kernel` flag
- [ ] Update `docs/DSP_KERNEL.md`, `docs/ARCHITECTURE.md` and the `AGENTS.md` mention, in coordination with E21

### E22 Hardware validation

Owner decision, 11 Nov 2026 (flag graduation): bench-dependent "is it good" acceptance and owner listening checks that used to gate an epic's flag removal live here; epics no longer wait for them to graduate their flag. A bench-only gap may be closed in its epic as "moved to E22" once an unchecked item here matches it.

Owner decision, 18 Oct 2026: there is no bench access for now, so every bench check is deferred to this epic, which runs once the software work is built. Software slices keep listing their checks under "Bench checks" in `docs/epics/E<n>.md`; this epic collects and runs them.

- [ ] Collect every epic's "Bench checks" list and the E3 cases H01–H08 into one campaign
- [ ] Run every E4 bench list in `docs/epics/E4.md` "Bench checks" (S4, S6, S7, S18b, S22a, S22b1 to S22b3, S25 arming, S26b, S30) after the graduation of the E4 flags (11 Nov 2026), including the 384 kHz feed-forward bridge shadow timing
- [ ] E4 S26b head follow: with the Mac camera (built-in and external) the head-pose estimate lands within tolerance of measured seat positions, the camera light is on only while head follow is on and stops on disable, sleep and background, and with a person moving the zone follows the head while the other-seat limit holds (`docs/epics/E4.md` Bench checks, S26b)
- [ ] Run E4 S8 (PR97 timing calibration and PR99 verification) and record results against `docs/ANC_QUALIFICATION.md`
- [ ] Run E4 S11 (owner, 1 Nov 2026: moved here from the E4 execution order): repeat S8 on the unified E6 graph, then fill the placeholder reduction table in `docs/ANC_QUALIFICATION.md` §4.1 from the S31 reviewer-kit noise files
- [ ] E4 S26a: ear-microphone check of the virtual-microphone design with a real head at the eight rates (E4 S26a wiring)
- [ ] Run the remaining bench checks at every rate from 44.1 to 384 kHz
- [ ] E6 G19: listening for level riding on speech and music at the eight rates (LOUDNESS stage, E6 S12c)
- [ ] E6 G43: binaural convolution cost per rate (16 channels, 8192 taps, 24 head orientations, 44.1 to 384 kHz) on the build machine (E6 S12g4)
- [ ] E6 G29: bypass and reference audition A/B while playing, and wide-EQ listening at the eight rates (E6 S12e)
- [ ] E6 G26: listening and bench check of multiband at the eight rates, including the kernel-to-graph hand-over with multiband on (MULTIBAND stage, E6 S12d); the reference-lab case is done (E6 S12h part 2a)
- [ ] E6 G47, G49, G53, G54: stereo five-lane graph CPU at 384 kHz, live stereo Quiet Zone arm/revoke/guard trip across a rebuild
- [ ] E6 S12h part 3: delta audition listening on 5.1 and stereo at the eight rates, ring memory at 16 lanes
- [ ] E27 owner release-build verification (owner decision 7 Nov 2026): Equalizer page running-window checks G3, G5, G9, G12, G16 and the DAC checks G14 (Listen ends on transport stop, glitch-free linear-phase A/B), per the checklist in `docs/epics/E27.md` Bench checks
- [ ] E9 S5 (G18): sub output under a +6 dB bass-heavy track, limiter audible check and loopback peak (E9 S5 bench item)
- [ ] Feed the results into the live-authorisation slices (E4 S10, E19), which still need real evidence
- [ ] Carried in by flag graduation (11 Nov 2026): E4 S30 checks, E19 modal-decay campaign, E20 no-overload-with-workers (gates FC removal of `e20.*`), E26 sub bench gaps (G10, G11, G19, G23, G24, G28, G30), E28 owner listen to S7a to S7d, E13 G8 (96 kHz tail versus 384 kHz benchmark), E9 bench lines (G18, G25, G26)

### FC Flag cleanup (owner, 11 Nov 2026)

Plan: `docs/epics/FC.md`. Epics graduate their flag at the end (default on, stays in `FeatureFlag.all`; AGENTS.md
section 11); this phase removes the flags after the E22 bench, as small per-epic PRs.

- [x] FC1 `fc/flags-off-ci`: nightly `macos-full` runs the suite with graduated flags off as well as on (before the first graduation)
- [ ] Per-epic removal PRs, in order: E26, E28, E9, E13, E4, E19, E7, E15, E17, E20, E21, E29 (`e6.legacy-kernel` goes with E23)
- [ ] Never remove a flag with an open E22 bench item against its feature; live ANC and MIMO keep `LiveTreatmentArm`

### E18 Launch readiness

Runs after the FC flag cleanup (owner, 11 Nov 2026).

- [ ] Developer ID and App Store signing, notarisation and App Review
- [ ] Legal and provenance review against `docs/PROVENANCE.md` and the SBOM
- [ ] VoiceOver and keyboard accessibility pass; localisation for the launch markets
- [ ] Competitive blind comparison against Dirac Live Processor and Clearroom on the same system
- [ ] Pricing against the $549–$899 Dirac bundle range, trial length, website, screenshots and launch reviews

## Platform reach after v1

The portable C++ core (E21) carries to every platform, but what each platform allows an app to do
with system audio differs, so the product shape differs too. This table is from platform knowledge
and has not been verified; check each before committing.

| Platform | Route to system-wide processing | Likely product shape |
| --- | --- | --- |
| macOS | Core Audio process tap (today) | Full product |
| Linux | PipeWire virtual sink or filter chain, no root needed | Full product with a new UI shell |
| Windows | Needs a signed virtual audio driver or an APO; loopback capture alone cannot intercept the default output | Full product after driver work and an installer |
| iPadOS / iOS | No system-wide processing for third-party apps | AUv3 plug-in, own player, measurement companion, remote for the Mac |
| Android | Restricted and inconsistent across devices | Own player, filter export to hardware, remote |

SwiftUI runs only on Apple platforms, so each non-Apple platform needs its own UI shell or a
cross-platform UI choice; that decision can wait until after v1. The rule until then: nothing in
the C++ core may depend on an Apple framework.

### Post-v1: iPhone companion app (owner, 11 Nov 2026; no epic number yet)

Outside the v1 completion requirement: v1 ships without it.

- [ ] iPhone remote for the Mac app, using the E16 local API
- [ ] iPhone as a measurement microphone for the Mac's measurement suite; needs its own
      calibration and accuracy design (per-model microphone response, timing against the Mac's
      clock, and the limits under which a phone capture is trusted) before any design path uses it

## How to run each epic in Claude Code

Run the build work in Claude Code on the Mac, where it can build the Xcode project, run XCTest
and reach the bench hardware. The repo is preconfigured: start Claude Code in the repository root
(the folder containing `CLAUDE.md`) after pulling `main`, then type `/next` or `/next E2`. If
you pull while a session is open, restart the session so new agents and instructions load.

- **`CLAUDE.md`** holds the session protocol (orient, plan, build one slice, verify, open a PR,
  close out, stop for bench work), the token rules, and the owner decisions.
- **`.claude/settings.json`** sets the model to Sonnet (Opus only through the epic-planner agent) and pre-approves routine git, build and test commands. Direct pushes to `main` and
  force pushes are denied, so every change arrives as a PR.
- **`.claude/agents/`** holds five helper agents that do routine work on cheaper models:
  `code-scout`, `build-test-runner`, `plan-tracker` and `pr-writer` (Haiku), and
  `realtime-reviewer` (Sonnet).

The owner's part each cycle: start a session with `/next`, approve new epic plans, review and
merge PRs labelled `needs-owner` (engine, transport, ANC/MIMO, protection, workflows, policy),
and do the bench checks a PR lists. Claude merges other PRs itself once CI is green, records plan
progress inside each PR, and continues for up to three PRs per session. CI: the PR check (about
3–5 minutes) runs on every code PR and skips docs-only PRs; the full macOS run is nightly. Switch to `/model opus` for design-heavy sessions (E4, E6, E10,
E19) if Sonnet's execution falls short.

Order: E2 first (small, proves the loop), then E1, then E3 at the bench; E5 can run at any time.

## Risks and open questions

The largest risk is that v1 now waits on the slowest item, speaker-ANC qualification, while
Dirac and Clearroom keep shipping.

| Risk | Mitigation |
| --- | --- |
| Speaker ANC fails or stalls physical qualification, holding v1 | Write the qualification criteria in Phase 1 and decide the fallback in advance |
| Competitors gain ground during a long build | Private TestFlight beta from Phase 3, under NDA if needed, to build reviewers and feedback |
| E6 regresses today's stereo sound | Side-by-side parity suite and the old kernel kept behind a flag |
| CPU at 384 kHz with ANC, MIMO treatment and 262k-tap FIR on a base Mac | Per-rate CPU budget measured on the slowest supported Mac; warn before enabling |
| Bench time is a single-person bottleneck | Batch bench sessions per phase; prepare scripts in advance with the PR112A harness |
| App Review questions on audio capture and Input Monitoring | Clear permission copy and a reviewer note, tested in TestFlight first |

Open questions:

- [ ] If speaker ANC cannot be qualified in time, does v1 wait, or ship with ANC as a labelled preview?
- [ ] Target price and trial length
- [ ] Is a private beta acceptable before the launch splash?
