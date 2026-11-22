# AGENTS.md

These rules apply to all human and automated contributors, including Codex and other coding agents.

## 1. Clean-room rule is mandatory

This repository is a fresh proprietary implementation.

Do **not** copy, import, transliterate, adapt, cherry-pick, or mechanically reproduce source expression from the historical GPL Notch Sixty / Equaliser repository or its upstream history. Do not import its tests, scripts, Xcode project, resources, presets, assets, generated files, or configuration unless a specific item has first been independently cleared and documented in `docs/PROVENANCE.md`.

Do not use the historical GPL repository as a coding reference while implementing commercial source. Implement behavior from public specifications, Apple documentation, independently written design notes, and testable product requirements.

The separate CoreAudioTapPOC-N60 repository is owner-authored clean-room validation work. Treat it primarily as behavioral and architectural evidence. Source reuse from the POC is **not automatic**: reuse requires an explicit provenance note and a deliberate review that the code is suitable for production rather than experimental scaffolding.

If provenance is uncertain, stop copying and reimplement from specification.

## 2. Product scope

Notch Sixty v1 ships as a macOS DSP application for stereo speakers plus a subwoofer.

Existing v1 scope:
- stereo playback
- bass management
- subwoofer integration
- room correction
- multi-seat measurement/averaging
- EQ, FIR, convolution, crossovers, dynamics, metering, and related loudspeaker DSP

### Post-v1 explicitly approved expansion

The project owner has explicitly approved a staged post-v1 architecture expansion for:
- semantic N-channel program layouts and channel-aware DSP
- conventional multichannel speaker playback/routing
- multichannel bass management and per-channel/group processing
- headphone device correction and channel matching
- headphone crossfeed
- binaural / virtual-speaker rendering, including HRTF/SOFA-based processing
- future head tracking and multi-input/multi-output room optimization

This approval does not permit unsafe partial activation: each PR must preserve shipping stereo behavior until the relevant N-channel transport/DSP path is complete and validated.

Still out of scope unless explicitly approved:
- installing audio drivers from the app, or any audio driver other than the optional add-on below
- privileged helpers
- kernel/system extensions
- proprietary object/bitstream decoders (for example a Dolby Atmos decoder) without the required licensing/product decision

Multi-seat room correction and multichannel program audio remain distinct concepts.

### Optional virtual audio driver add-on (owner decision, 16 Nov 2026; post-v1, V2-1)

The owner has approved Notch Sixty's own user-space virtual audio driver as an optional add-on, planned in `docs/V2_ROADMAP.md` (V2-1). It is not v1 work and does not start until the owner says so.

- The app never depends on the driver. It installs, runs and ships every v1 feature without it, and the process tap stays the default input path.
- The driver is a separate product in its own repository with its own signed, notarised installer and uninstaller. Only that installer touches `/Library/Audio/Plug-Ins/HAL` or restarts `coreaudiod`. The sandboxed app never downloads, installs, updates or removes it; it only detects an installed driver and uses it as an audio device.
- User-space AudioServerPlugIn only. No kernel or system extension, no privileged helper.
- The clean-room rule (section 1) and the licence rule (section 7) apply: no GPL driver code (for example BlackHole or Background Music), and not as a coding reference.
- If the app stops for any reason, the virtual device must go away so macOS returns to a real output (section 5).

## 3. Transport architecture

Use public Core Audio APIs and the driverless process-tap architecture. The optional virtual audio driver (section 2) is a second input path beside the tap, never a replacement: the flow below stays the default and must work with no driver installed.

Expected flow:

```text
Other applications
    ↓
Device-scoped private Core Audio process tap
    ↓
Private aggregate/tap input path
    ↓
Realtime bridge
    ↓
RenderKernel / DSP graph
    ↓
Explicitly selected physical output device
```

The selected physical output is authoritative. Do not silently follow a later macOS default-output change and do not silently fall back to another device if the selected device disappears. Recovery should wait for the same stable device UID unless product requirements explicitly change.

The transport layer must not impose a fixed 44.1/48/96 kHz whitelist. It must remain native-rate and support device-exposed rates through 384 kHz. Do not add SRC simply to hide a transport mismatch; SRC must be an explicit DSP/product decision.

## 4. Realtime rules

The audio callback must never:
- allocate or free memory
- take blocking locks
- perform disk or network I/O
- log
- touch SwiftUI, Observation, Combine, or AppKit state
- spawn tasks
- await async work
- construct or destroy filters/graphs
- parse files or JSON
- perform device discovery

Build immutable or preallocated processing state off the realtime thread and atomically swap it into the render path.

Any new realtime component must document:
- allocation behavior
- synchronization behavior
- latency
- sample-rate assumptions
- channel-count assumptions
- reset behavior

See `docs/REALTIME_RULES.md`.

## 4a. Portable core (owner decisions 17 Oct and 11 Nov 2026)

The engine core is `libn60core`, in `core/`. New engine code (realtime and design maths) is C++ and goes in `core/`, never in `NotchSixty/Audio/Realtime`. Existing C migrates file by file as E6 rewrites each stage.

- **Layout.** Portable sources live in `core/src`; public headers in `core/include/n60`. Platform backends of core interfaces live in `core/platform/<os>/` and compile only on that OS. The macOS audio backend (Core Audio bridges, tap, aggregate, `AudioBufferList`) stays in `NotchSixty/Audio/` and may be C. The macOS shell (app, Core Audio control, UI) is Swift. A future shell links `libn60core` and writes its own backend.
- **No platform dependence.** The core must not depend on any Apple framework or platform audio API (no Accelerate, Core Audio, Foundation, Dispatch, `os_*`). Platform facilities come in through core-defined interfaces with a backend per OS.
- **Language.** C++20 baseline. C++23 features only once every CI toolchain accepts them. C stays legal for tests and the macOS backend.
- **C++ realtime subset.** On any path reachable from `process`: no allocation, locks, exceptions, RTTI, `dynamic_cast`, `std::function` or other allocating type-erased wrappers, iostreams, `thread_local` with dynamic initialisation, or function-local statics with non-trivial constructors. Off-thread design maths may allocate but never throws across the C boundary and is deterministic (fixed summation order, no threads, seeded noise). Enforcement: compile flags, `test_alloc`, realtime-reviewer, and RealtimeSanitizer when available.
- **FFT and linear algebra.** One FFT contract (`core/src/fft.hpp`); vDSP is a backend on Apple, the in-house radix-2 elsewhere. Engine code never picks an implementation by flag. Dense linear algebra is in-house (`core/src/linalg/`) unless the owner approves a library after licence review.
- **One versioned C interface.** `n60/n60.h` includes every domain header and `n60_core_abi` reports each domain version and struct size. Domains keep their own versions; changing one domain does not bump another.
- **Licences.** No GPL or AGPL code in the core (no FFTW); BSD, MIT or similar only, recorded per section 7.

## 5. Lifecycle and recovery

Use an explicit control-plane state machine. Production states should distinguish normal reconfiguration from hardware failure recovery.

Target states:

```text
Idle
RequestingPermission
CreatingTap
CreatingAggregate
OpeningOutput
Starting
Running
Reconfiguring
RecoveringOutput
Stopping
Failed
```

Normal Quit must stop/fade audio before teardown. A true force-quit cannot rely on application cleanup, but it must not leave system audio wedged.

## 6. App Store constraints

The minimum supported macOS is 27 (owner decision, 17 Nov 2026, E34 S0). Raising it again needs the project owner's explicit approval.

App Sandbox is required from the beginning. Do not introduce architecture that depends on:
- root privileges
- Authorization Services
- installing HAL drivers into `/Library/Audio/Plug-Ins/HAL`
- restarting `coreaudiod`
- self-updaters in the App Store build
- writing outside permitted sandbox/user-selected locations

The optional virtual audio driver add-on (section 2) is the one exception to the HAL-driver and `coreaudiod` lines, and only for its own separate installer. The app itself still follows every line above and must work with no driver installed.

See `docs/APP_STORE_REQUIREMENTS.md`.

## 7. Dependencies

Prefer Apple frameworks and small independently implemented DSP primitives.

Before adding a third-party dependency:
1. justify why it is needed;
2. verify the license is compatible with proprietary Mac App Store distribution;
3. add it to `THIRD_PARTY_NOTICES.md`;
4. add provenance information to `docs/PROVENANCE.md`;
5. consider whether the dependency is safe on a realtime path.

Do not add GPL/AGPL dependencies to production targets.

## 8. Testing

Every audio-path change should include deterministic tests where possible and identify required hardware/manual validation.

No audio architecture change is considered complete solely because it compiles.

Tests check behaviour, not source text. Do not add `ci/validate_*.py` scripts (or similar) that grep Swift, C or C++ source; write a deterministic XCTest or C harness that exercises the behaviour instead. The only remaining Python validators check release metadata that exists only in the release job.

DSP changes need deterministic tests and an acoustic reference-lab case at the standard rates: 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz.

Regression requirements include:
- 44.1 / 48 / 96 kHz
- high-rate native operation through available device rates up to 384 kHz
- live nominal-rate changes
- device unplug/replug
- sleep/wake
- permission lifecycle
- selected-device policy
- Stop/Start
- normal Quit
- force-quit recovery
- long-run transport/resource stability

See `docs/TEST_STRATEGY.md`.

## 9. Quality rule

When touching code, improve the design rather than reproducing legacy structure. Do not recreate old type names, routing hierarchies, or store architecture simply because the historical application used them.

Prefer small explicit components, narrow responsibilities, deterministic state transitions, and testable boundaries.

## 10. Pull requests

Each substantial PR should state:
- purpose
- architecture impact
- realtime impact
- provenance/source-of-truth
- tests added/run
- manual validation required
- App Sandbox/App Store impact
- feature flag used, if any
- required bench/hardware checks (remote CI never substitutes for them)

If a PR introduces DSP math, cite the public specification or derivation used to implement it.

## 11. Trunk, feature flags and CI

`main` is the trunk and must always build, pass CI and be shippable with every flag off.

- Work in short-lived branches, one slice per PR, merged to `main` by squash. Do not build stacked or long-lived draft PR chains.
- Name branches `e<n>/<slice>` and name the program-plan epic (`docs/PROGRAM_PLAN.md`) in every branch, commit and PR.
- Unfinished user-visible work merges dark behind its epic's feature flag (`FeatureFlag.all` in `NotchSixty/State/FeatureFlags.swift`; see `docs/FEATURE_FLAGS.md`). Flags default off. Release builds ignore stored overrides and honour only the `-NotchSixtyFeatures` launch argument.
- Only Swift reads flags. The realtime engine never does: Swift decides and publishes the resulting configuration through the normal snapshot path.
- **Flag graduation (owner decision, 11 Nov 2026).** An epic ends when its software is done, wired through production UI and passing its tests, and its flag is *graduated*: it stays in `FeatureFlag.all` but defaults on, in release builds too (`graduated: true`). Owner acceptance and bench-dependent "is it good" checks are not part of the epic; they belong to E22. Flags are not removed at ship. Removal is a separate flag-cleanup phase after E22 and before E18, run as small per-epic PRs.
  - Graduated means *available*, never *armed*. Live ANC and live MIMO room treatment keep their arm switch (`LiveTreatmentArm`, never persisted) and written authorisation path. Graduating a flag never arms anything.
  - No new code may depend on a graduated flag. A graduated flag exists only as an escape hatch until cleanup.
  - A release user can switch a graduated feature off with `-NotchSixtyFeatures -<id>` (or `<id>=off`); `<id>` or `<id>=on` switches one on. Off wins over on. Release builds still ignore stored overrides.
  - While flags exist, the flags-off path stays tested: nightly `macos-full` runs the suite with graduated flags off as well as on (owned by FC1 in `docs/PROGRAM_PLAN.md`).

CI is three workflows:

- `pr.yml`: every PR to `main`. Debug build, XCTest and the behavioural C harnesses. Docs-only PRs skip it.
- `macos-full.yml`: nightly on `main`, PRs labelled `full-ci`, and manual runs. Full XCTest, the Release performance build and render benchmarks.
- `release.yml`: manual only. Builds, checks and packages a release.

Do not add per-PR or per-branch workflows. Extend one of these three instead.


## 12. Definition of done (E24 S7, owner-approved 3 Nov 2026)

- `[x]` in a plan means reachable from the shipped UI through production wiring. Code that is built but not wired is `[~]` ("built dark") and names the slice that wires it.
- A "not wired", "left for" or "follow-up" note in an epic Log becomes an unchecked plan item with an owning slice. A slice with an open ledger entry is not ticked.
- A flag-graduation (or "ship") slice needs an end-to-end test through production wiring and no open ledger entries for its epic. A gap whose only remaining work is a bench or owner acceptance check may be closed with "moved to E22" only when E22 holds a matching unchecked item; every software gap must be fixed first. The same test is needed again by a flag-cleanup PR only for the behaviour it touches.
- Production code has no `Unconnected*` (always-unavailable) defaults on injectable services; tests inject fakes explicitly.
- Every PR body states "Reachable from UI: yes/no", with the path from the user action to the engine.
- Every epic file has a `## Gaps` ledger (`docs/epics/README.md`). A slice with an `open-question` gap is not ticked. A `scoped` gap needs an unchecked plan item in its owning slice. A flag-graduation or "ship" slice needs every gap in its epic `closed`.

## 13. Screen fit (owner decision, 21 Nov 2026)

Every app window and page must fit comfortably on a 1920 x 1080 display without taking up the whole screen, at the default window size.

- No page needs horizontal scrolling at the default or minimum window width. Control rows reflow (wrap to a second line or collapse into a menu) instead of scrolling sideways.
- Controls never force the window wider than its content area; fixed-size controls sit in a `ViewThatFits` or similar reflow, not a bare `HStack`.
- Vertical scrolling is fine for long pages, but a page's default state has no large empty bands of dead space.
- A UI slice checks this by hosting the page at 1,280 x 800 and at 1,920 x 1,080 minus the menu bar and Dock (about 1,920 x 1,000), reading the laid-out control frames and asserting that none extends past the page width. Any slice that adds controls to a row re-checks it.
