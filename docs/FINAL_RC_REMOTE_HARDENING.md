# Final RC — Single-Batch Remote Hardening

Date: October 14, 2026. Branch: `feature/final-integrated-rc-qa`;
PR #130 stays OPEN/DRAFT/UNMERGED. Owner explicitly defers macOS 26:
the required deployment floor remains **macOS 27**.

## Changes included in this batch

- Repair the duplicated Xcode UI file-group reference that produced a warning.
- Remove ten unused/unassigned macOS dark-appearance `AppIcon` slots from
  the macOS icon catalog. The ten supported Finder icon images remain
  unchanged; approved Light/Dark **source masters remain byte-for-byte
  unchanged**, as do runtime Dock Light/Dark assets and dynamic appearance
  selection. The revised fourteen-output manifest verifies original hashes.
  Automatic Finder dark-appearance switching is not claimed.
- Add a source-only Release/performance hygiene audit with no runtime cost.
  It checks the optimized, non-debug Release Xcode configuration, Release
  origin of the test DMG, duplicate project membership, icon SHA and
  appearance selection, and direct synchronous logging in core C render/
  bridge files and `AudioIOEngine.swift`.
- Update README, roadmap and owner acceptance handoff without changing DSP,
  active audio routing, protections, headroom, app sandbox or ANC authority.

## Limitations

The source scan is **not** proof of no indirect framework, plug-in or
system logging; nor is it a complete static allocator/lock audit or a real
CPU/latency/dropout benchmark. Hardware/endurance and subjective/acoustic
measurements must still take place on a physical Apple Silicon Mac running
macOS 27. Runtime appearance behavior and final icon visuals require
on-device owner review.

## Validation and owner handoff

Commit with `[integration-ci]` once after the batch is complete to request
an exact-head arm64 Mac Release build, Debug/full XCTest, SBOM, archive,
checksummed ad-hoc test DMG and mounted image verification. Previous green
run #38581711406 at SHA `52f15da6f23bcc28e5b5c19705d3bcfea303aa81`
is historical after this patch; the new artifact is trustworthy only after
the new exact-head workflow passes.

Remaining: PR112 physical H01–H08, selected device replug/sleep recovery,
long-run thermal/dropouts, calibrated speakers/sub/driver and headphone
acoustics, 384 kHz real-DAC compatibility where supported, final owner icon
review, third-party rights/IP review, Apple credentials/signing/notarization/
App Store operations and **explicit owner merge/public-release approval**.
Speaker-connected feed-forward ANC remains unauthorized. `main` untouched.

## Final CI compiler-warning triage: DSP-critical repair

Review of the preceding full Mac compiler output identified a genuine
type mismatch in `N60MultichannelBassManagement.h`: crossover snapshots
hold double-precision `N60CrossoverPreciseCoefficients`, while the
multichannel processor previously passed them to float biquad coefficients
and float runtime states. This is a **functional risk**, not cosmetic
compiler noise. The runtime now uses matching `N60CrossoverPreciseState`
and `N60CrossoverPreciseProcessSample` for source and LFE crossover
paths; per-sub ordinary EQ remains its own float biquad stage. A native C
`-Werror` regression validates stable low/high-pass behavior at 48 and
384 kHz, including redirected bass and LFE; it runs in portable and Mac CI.

Other compiler messages include Swift `allowedFileTypes`/
`auAudioUnit` deprecations, local immutable-binding suggestions, and
integer-narrowing warnings in vendored `libmysofa`. They remain **known
nonfatal audit findings**, not falsely marked as resolved or silently
suppressed. Change to vendored code requires provenance and separate
risk assessment. No hardware sonic validation is inferred from this C fix.
