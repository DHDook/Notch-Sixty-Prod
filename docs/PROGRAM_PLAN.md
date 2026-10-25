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
| New engine quality (20 Oct 2026) | The unified graph is at least equal to `N60RenderKernel` in every area and better where it can be; the kernel stays as a frozen fallback until E23 deletes it before v1 |

## Epics at a glance

Twenty-three epics in four phases close every gap in the analysis and set the engine up for other
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
| E13 | Headphones complete | 4 | E6, E7 | Claude Code (Mac) | BYO files to PEQ in one click; live tuning |
| E14 | Upmixer | 4 | E6 | Claude Code + bench | Stereo plays on 5.1–7.1.4 layouts |
| E15 | Device-aware profiles | 4 | E6 | Claude Code (Mac) | Profile follows the output when the user opts in |
| E16 | Automation and remote | 4 | E6 | Claude Code (Mac) | App Intents, local API and iPhone remote ship |
| E17 | Export and dither | 4 | E8, E10 | Claude Code (Mac) | MiniDSP, APO and WAV exports; automatic dither |
| E23 | Legacy engine removal | 4 | E6, E4 S11, E7–E17 | Claude Code (Mac) | `N60RenderKernel`, the old N-channel path and the `e6.*` flags are gone; full suite green |
| E22 | Hardware validation | 4 | all software epics | Bench | Every deferred bench check passes on `main` at every rate |
| E18 | Launch readiness | 4 | all | Owner + Claude Code | Signed, reviewed, accessible, competitive ABX done, App Store live |

## Execution order (owner, 20 Oct 2026)

`/next` works down this list: the first epic with open slices whose dependencies are met. Within
an epic, slices go in their written order. Competitive features come first (what buyers and
reviewers compare with Dirac and REW), then engine depth, then breadth.

1. E6 Unified live N-channel graph, through S11
2. E11 Measurement suite
3. E10 Mixed-phase room correction and bass control
4. E8 Routing matrix and crossovers
5. E12 Guided setup and information architecture
6. E13 Headphones complete (bring-your-own import first)
7. E9 Multichannel protection and FIR parity
8. E7 384 kHz everywhere
9. E20 Engine performance
10. E19 MIMO room treatment, software parts (plan first)
11. E4 S11 Re-qualify ANC on the unified graph
12. E21 Portable C++ core, remaining items
13. E14 Upmixer, E15 Device-aware profiles, E17 Export and dither, E16 Automation and remote
14. E23 Legacy engine removal
15. E22 Hardware validation and E18 Launch readiness (owner-led)

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

### E5 UI scope clean-up

- [x] Move Hardware Acceptance and Acoustic Research to a hidden developer menu (#153)
- [x] Order the dynamics navigator by signal chain and fold niche processors (denoiser/de-hiss, de-esser, expander, DC offset, oversampling) under "More" within each group (revised with owner, 18 Oct 2026) (#154)
- [x] Fold Speaker Measurement Lab directivity tools into an Advanced tab; quasi-anechoic has no UI yet and moves to E11 (owner, 18 Oct 2026)

### E19 MIMO room treatment qualification, ART class (runs Phases 1–3)

The MIMO designer, FIR compiler and live runtime already exist but are hardware-gated (PR73–PR77);
Dirac now sells ART on the Mac, so this needs the same path to authorisation as ANC.

- [ ] Bench campaign with two or more subwoofers plus mains: modal decay (T20/T30 below 150 Hz) before and after at several seats
- [ ] Speaker support-range and exclusion controls, and an explicit LFE time target
- [ ] Headroom and excursion safety per contributing speaker
- [ ] Authorise live treatment only through the PR75 verification path, then re-qualify on the unified graph

## Phase 2 — Unified engine

Phase 2 replaces the three render paths with one graph that every later feature builds on.
**Gate G2:** stereo output matches today's kernel on the parity suite within -120 dBFS peak
(deliberate improvements excepted where the reference lab shows them equal or better), and live edits are click-free on hardware in stereo, 5.1 and binaural modes.
Gate G2 passed on 2026-10-25 (commit 07e82c6)

### E6 Unified live N-channel graph

- [x] Write a design note (`docs/epics/E6.md`, awaiting owner approval): lane stage list, snapshot layout, latency alignment, coefficient ramping, rebuild-with-fade rules, threading and multirate boundaries
- [ ] Build the unified graph in C++ from the start, per the engine-language decision (E21)
- [ ] Give every lane the full stereo stage set: PEQ, M/S where paired, dynamic EQ, dynamics, FIR, delay, protection
- [x] Represent stereo as a 2-channel layout and the binaural renderer as a stage, not a separate transport
- [ ] Make parameter edits live with ramped coefficients; rebuild with a short fade only on topology changes
- [x] S8c `e6/dynamics-readbacks`: gain-reduction, true-peak and over-range readbacks through a core ABI addition (#187; diagnostics UI row and two tests follow up)
- [x] S8e `e6/rack-and-routes`: AU rack as an external-processor node; same-device and aggregate routes render through the graph
- [ ] S8d `e6/translate-remaining-stereo`: move the kernel-fallback stereo stages (dynamic EQ, FIR/IR/convolution, mixed phase, crossover and bass management, denoiser, fractional delay, soft clipper, gain rider) to the graph
- [ ] Remove the `unsupportedActiveDSP` and `immutableSemanticTransportActive` restrictions in `AudioIOEngine.swift`, and the idle-only headphone profile rule
- [ ] Build a parity suite that renders the old stereo kernel and the new graph side by side
- [x] Make the graph the default once parity holds; keep `N60RenderKernel` as a frozen fallback behind a flag until E23
- [x] S8b2a `e6/engine-integration-3` built on branch (needs-owner, behind `e6.unified-graph`): graph reproduces M/S EQ, compressor, expander, ambient compensation, symmetry, crossfeed, crosstalk cancellation, integer inter-channel delay and pause gate; everything else keeps the kernel fallback
- [x] S8b2b: translate dynamic EQ, FIR/room/speaker IR, stereo crossover and bass management, denoiser, soft clipper and gain rider (or document keep-on-kernel); wire multichannel, layouts, 1 to 8 subs and binaural into the live N-channel session; metering and latency readbacks; compensate kernel/graph latency difference across the hand-over fade
- [x] S8b2c (next): wire live binaural into the N-channel session (it has no binaural mode today) and compensate kernel/graph fade latency (the N-channel path attaches the graph statically, with no mid-stream hand-over). S8b2c is split: S8b2c1 built on branch `e6/engine-integration-5` (needs-owner); S8b2d awaits owner approval of the binaural proposal
- [x] S9b `e6/live-session-edits` (needs-owner): setters live while an N-channel or binaural graph renders, with a fresh-build equality test at eight rates; bench in E22
- [x] S9c `e6/live-headphone-profile` (needs-owner): headphone profile edits live on graph-rendered binaural sessions, asset swap off the main actor, ear delay stages; bench in E22

### E7 384 kHz everywhere

- [ ] Express every buffer capacity in time, not frames, and size it at the 384 kHz worst case
- [ ] Lift the known frame caps: program FIR 32,768 taps, binaural 8,192 taps, headphone delay 4,096 frames
- [ ] Extend the PR117A double-precision fix beyond the crossover: user EQ, lane EQ, subwoofer EQ and headphone PEQ still use float32 coefficients and state, which loses low-frequency accuracy at high rates
- [ ] Keep HRIR resampling on activation; add the same policy for any imported IR or SOFA asset
- [ ] Run the XCTest acoustic reference lab at 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz
- [ ] Check Audio Unit hosting: report clearly when a plug-in refuses a rate
- [ ] Bench: confirm CPU headroom at 384 kHz on the slowest supported Mac

### E8 Routing matrix and crossovers

- [ ] Replace Mains+Sub / Bi-Amp / Tri-Amp modes with a source-to-output matrix and a per-output filter chain
- [ ] Filter library: Butterworth, Bessel, Linkwitz-Riley at 6–48 dB/oct, asymmetric slopes, Linkwitz transform
- [ ] Any number of ways per speaker, on any layout, not stereo only
- [ ] Linear-phase FIR crossovers reusing the Speaker Optimizer's linear-phase synthesis
- [ ] Driver linearisation from Measurement Lab near-field captures
- [ ] Raise the subwoofer limit from 4 to 8 (core bass management already supports 8 sub lanes since E6 S7b, ABI v7)
- [ ] Advanced pipeline view for power users, plus CamillaDSP YAML import alongside the existing export
- [ ] Migrate existing bi/tri-amp profiles automatically

### E9 Multichannel protection and FIR parity

- [ ] Per-output limiter, true-peak guard and soft clip, matching the stereo chain
- [ ] Move the program FIR onto the 262,144-tap non-uniform convolver
- [ ] Per-output headroom assistant

### E20 Engine performance

Performance comes from architecture rather than language: whole-buffer processing, multirate
paths, SIMD, multiple threads and the right algorithms. Today the stereo bridge calls the whole
chain once per frame, with no SIMD, on one thread.

- [ ] **Whole-buffer processing:** each stage processes the full buffer instead of the per-frame `N60RenderKernelProcessStereoFrameInContext` call; fuse adjacent stages with templates so audio stays in cache
- [ ] **Multirate:** run ANC, MIMO room treatment, subwoofer and bass-management processing and low-frequency analysis at decimated rates (32–64× below 384 kHz), with polyphase decimation and interpolation and exact latency accounting
- [ ] **SIMD:** Google Highway with runtime dispatch (NEON, SSE, AVX2, AVX-512); vectorise biquad cascades across channels
- [ ] **Multiple threads:** Audio Workgroups on Apple (and the equivalent realtime thread groups elsewhere) for lanes, MIMO and long convolution, with a lock-free job graph and a deterministic join before output
- [ ] **Right algorithms:** non-uniform partitioned convolution in every FIR path (program FIR, binaural, MIMO), long partitions spread across callbacks, double-precision or state-variable filters at high rates, polyphase sample-rate conversion
- [ ] Set flush-to-zero at callback entry instead of scanning every sample for denormals; keep the NaN guard at the output
- [ ] RealtimeSanitizer plus `nonblocking` / `nonallocating` attributes on every realtime entry point, run in CI
- [ ] CI benchmarks: per-stage ns/sample and worst-case callback time at 48, 192 and 384 kHz, with fail thresholds
- [ ] UI: move `ObservableObject` controllers (23 `@Published` in `AudioIOEngine`, 33 in `RoomTreatmentAdvisorController`) to `@Observable`, and draw meters with Canvas at display rate
- [ ] User-facing dynamics meters from the E6 S8c readbacks: gain reduction on the compressor, expander and limiter controls, true-peak beside the output meter, and a latching over-range indicator (owner, 20 Oct 2026)

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
- [ ] RTA with selectable fractional-octave resolution, plus an SPL meter and logger with A/C/Z weighting
- [x] Signal generator: pink and white noise, band-limited noise, tones, for level matching and listening checks
- [x] Waterfall / CSD and spectrogram from the existing impulse response
- [x] Harmonic distortion (H2–H5) from the log sweep's negative-time impulses
- [x] RT60 and EDT per octave and third-octave band
- [ ] Simultaneous multi-microphone capture to speed up multi-seat measurement
- [x] Measurement management: overlays, groups, notes, A/B against a reference
- [x] Quasi-anechoic (gated) speaker response view in the Measurement Lab's Advanced tab, using the existing analyser (`SpeakerMeasurementLabQuasiAnechoic.swift`; from E5)
- [ ] Import and export REW text, FRD and ZMA; a cross-check suite against REW on shared captures

### E10 Mixed-phase room correction and bass control

- [ ] Excess-phase correction with frequency-dependent windowing, built on the PR129 research designer
- [ ] Pre-ringing limits and a latency budget; keep minimum-phase as a low-latency / video mode
- [ ] Multi-seat robustness: correct only phase that is coherent across seats, with per-seat weighting
- [ ] Joint mains-and-subwoofer bass optimisation across all channels (Dirac Bass Control class), not subwoofers alone
- [ ] Target editor with curtain, limited-range, per-channel offsets and saved target library
- [ ] Flip `canDeploy` only through the verification path, with prediction and post-apply measurement
- [ ] Bench: blind ABX against minimum-phase on the reference room

### E12 Guided setup and information architecture

- [ ] One "Set up my system" flow: topology, levels and polarity, distances, multi-seat sweep, bass, correction, verification, saved profile
- [ ] Merge Speakers, Speaker Calibration, Measurement Lab and Room Correction into a clear System area
- [ ] Surface the room geometry and treatment advisor inside the flow
- [ ] Usability test with someone who has never seen the app

## Phase 4 — Complete scope and launch

Phase 4 finishes the remaining scope and prepares the launch. **Gate G4 (v1):** every epic
complete, speaker ANC qualified, and a full hardware regression passing at every rate from
44.1 to 384 kHz.

### E13 Headphones complete

- [ ] Bring-your-own import: AutoEq CSV, REW and squig.link frequency-response text, plus user target curves
- [ ] One-click PEQ from an imported response and a chosen target, using the existing model fitter
- [ ] Live PEQ and crossfeed tuning while playing (from E6)
- [ ] Raise the HRIR cap for room-included BRIRs; live HRTF interpolation with head tracking
- [ ] In-ear-microphone BRIR capture for personal virtual speakers

### E14 Upmixer

- [ ] Stereo to 5.1, 7.1 and 7.1.4 with centre extraction and ambience to surrounds
- [ ] Per-layout presets and a bypass for content that is already multichannel

### E15 Device-aware profiles

- [ ] Opt-in "follow system output" mode that recalls the profile bound to each output UID
- [ ] Keep today's fixed-output policy as the default

### E16 Automation and remote

- [ ] App Intents and Shortcuts for profile, volume, mute, bypass and correction on/off
- [ ] Local authenticated REST/websocket API, off by default
- [ ] iPhone remote app using that API

### E17 Export and dither

- [ ] Filter export to MiniDSP, Equalizer APO and WAV convolution sets
- [ ] Automatic TPDF dither only when the device's physical format is 16-bit integer

### E23 Legacy engine removal

Owner decision, 20 Oct 2026: the kernel stays behind `e6.legacy-kernel` until late in the roadmap,
then this epic deletes it before E22 hardware validation, so v1 ships and is validated on the
unified graph only.

- [ ] Confirm nothing falls back to the kernel (E6 S8d, S8e; E4 S11 for AQZ/ANC)
- [ ] Delete `N60RenderKernel`, the old N-channel path and the `e6.legacy-kernel` flag
- [ ] Update `docs/DSP_KERNEL.md`, `docs/ARCHITECTURE.md` and the `AGENTS.md` mention, in coordination with E21

### E22 Hardware validation

Owner decision, 18 Oct 2026: there is no bench access for now, so every bench check is deferred to this epic, which runs once the software work is built. Software slices keep listing their checks under "Bench checks" in `docs/epics/E<n>.md`; this epic collects and runs them.

- [ ] Collect every epic's "Bench checks" list and the E3 cases H01–H08 into one campaign
- [ ] Run E4 S8 (PR97 timing calibration and PR99 verification) and record results against `docs/ANC_QUALIFICATION.md`
- [ ] Run the remaining bench checks at every rate from 44.1 to 384 kHz
- [ ] Feed the results into the live-authorisation slices (E4 S10, E19), which still need real evidence

### E18 Launch readiness

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
