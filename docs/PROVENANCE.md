# Provenance Register

This file is the commercial repository's living provenance register.

## Classification

Each nontrivial imported/reused implementation should be classified as one of:

- **Original commercial implementation** — written in this repository from product requirements/public specifications.
- **POC-derived, owner-authored** — deliberately reused or adapted from `CoreAudioTapPOC-N60` after review.
- **Third-party permissive** — external component with compatible license and notice.
- **Specification-derived** — implemented from a public mathematical/technical specification.
- **Asset with verified rights** — images/audio/fonts/resources whose commercial rights are documented.

Historical GPL Notch Sixty / Equaliser source is not a permitted production source category.

## Initial register

| Area | Classification | Source of truth | Notes |
|---|---|---|---|
| Commercial repo bootstrap/docs | Original commercial implementation | Product requirements + clean-room architecture decisions | No GPL source imported |
| Production Xcode project and Swift app shell | Original commercial implementation | `DHDook/Notch-Sixty-Prod` bootstrap requirements | Freshly and independently generated for this repository. No source, project file, test, asset, configuration, or Git history was imported from historical Notch Sixty, Equaliser, BlackHole, or `CoreAudioTapPOC-N60`; the app shell is newly generated bootstrap material. |
| Core Audio device discovery and output-selection foundation | Specification-derived / original commercial implementation | Apple public Core Audio property APIs + production architecture requirements | Independently implemented in this repository. Uses `AudioObjectGetPropertyData` / `AudioObjectGetPropertyDataSize` and public device-property selectors. No POC or historical source copied. |
| Core Audio process-tap and aggregate transport | Specification-derived / original commercial implementation | Apple public `CATapDescription`, process-tap, aggregate-device, IOProc, and property-listener APIs + product requirements | Independently implemented in this repository. Behavior is informed by prior product validation, but no POC or historical source code/project metadata was copied. |
| Realtime transport bridge | Original commercial implementation | `docs/REALTIME_RULES.md` + SPSC transport requirements | New fixed-capacity stereo C11-atomic ring bridge. No third-party atomics dependency; no allocation/locking/logging in capture/render callbacks. |
| Audio lifecycle state machine and diagnostics foundation | Original commercial implementation | `docs/ARCHITECTURE.md` lifecycle and output-policy requirements | Production control plane includes intentional reconfiguration, same-UID recovery, sleep/wake handling, graceful Stop/Quit, and cumulative transport diagnostics. |
| Realtime DSP kernel and graph-publication foundation | Original commercial implementation | Product requirements + `docs/REALTIME_RULES.md` + `docs/DSP_KERNEL.md` | Independently implemented in the commercial repository. C11-atomic preallocated snapshot publication, unity/reference render stage, gain/bypass/latency contracts, and numerical-safety diagnostics. No historical GPL or POC source copied; PR #12 contains no substantive EQ/filter algorithm. |
| DSP implementations | Pending | Public specs / independent derivations | Add per-module entries as substantive processors are implemented or independently cleared for reuse. |
| Third-party dependencies | None approved | — | Update before adding any dependency |
| Assets | None added | — | Verify rights before inclusion |

## Required entry for reused POC source

If code is intentionally reused from the POC, add:
- production path
- POC source path/commit
- ownership basis
- changes made for production
- reviewer/date

Do not treat architectural similarity by itself as source reuse.
