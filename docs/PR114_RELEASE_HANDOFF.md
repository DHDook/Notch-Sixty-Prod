# PR114 Slice 6 — Integrated RC verification and handoff

**Status: CI GATE WIRED — PASS ON THE FINAL EXACT HEAD REQUIRED.**

## One-run remote software acceptance

The `PR114 Commercial Release Candidate` workflow must succeed on one exact
current PR114 head. The portable job verifies all PR114 slice contracts,
inherited commercial safeguards, and negative tests preventing owner/physical
gates from being promoted. The macOS job must additionally pass Apple Silicon
arm64 Debug and Release builds, targeted regression, a generic unsigned
archive, effective ad-hoc sandbox entitlement verification, a checksummed RC
DMG, complete cumulative XCTest, CycloneDX production SBOM and an exact-head
release-candidate manifest.

`ci/validate_pr114_commercial_handoff.py` runs after manifest creation and
before publication. It checks exact source SHA, Actions run ID, version/build,
arm64 identity, the complete remote requirement set, DMG and SBOM SHA-256, SBOM
source SHA and hard-false authority flags. A passing preflight is evidence of
**remote commercial RC software completion**, not public-release acceptance.

## Independent evidence handoff

| Class | Authority and evidence | Status |
| --- | --- | --- |
| `remoteSoftware` | Current-head Actions PASS, RC JSON, SBOM, package hash and all test gates | Awaiting exact-head CI |
| `physicalHardware` | Owner's real Mac/audio system; PR112 H01–H08 and independent physical review | BLOCKED |
| `releaseCredential` | Production Apple signing, provisioned archive, App Store Connect, TestFlight and App Review | BLOCKED |
| `externalReview` | Independent provenance/licensing/IP/privacy review as required | PENDING |
| Owner presentation | Final icon, truthful screenshots, store copy, support/privacy URLs, rating/pricing | PENDING |
| Public release | Explicit owner go/no-go *after* all required evidence | NOT AUTHORIZED |
| Merge | Independent explicit owner instruction | NOT AUTHORIZED |

Do not infer physical acceptance from an archived test fixture, synthetic
measurement, portable CI or ad-hoc signed DMG. PR112 H01–H08 requires actual
output/microphone/driver/speaker validation, selected device lifecycle,
unplug/replug, sleep/wake, emergency mute and relevant endurance, acoustic and
safety evidence, including multi-output/clock behavior where applicable.
Speaker-connected feed-forward ANC remains unauthorized.

Production App Store export/signing is an external credential task. A manual
ad-hoc DMG is not notarized and not a public download; a future direct
distribution path requires separate Developer-ID signing/notarization if
selected. Record actual TestFlight and App Review outcomes rather than treating
the unsigned archive as their substitute.

Final handoff includes: H01–H08 physical campaign, actual clean-device smoke,
production signing/entitlements, final icon/screenshot owner approval,
published privacy/support URL, App Privacy declarations, rights/export/pricing
fields, TestFlight acceptance, App Review outcome and explicit public-release
decision. Until instructed otherwise keep PR114, PR113B, PR113, PR112A and all
ancestors OPEN/DRAFT/UNMERGED and keep `main` unchanged.
