# PR114 — Commercial Release Candidate

Status: **IN PROGRESS — SLICES 1–4 IMPLEMENTED; EXACT-HEAD VALIDATION PENDING**

PR114 is stacked directly on the exact remotely-complete PR113B head
`f10008d8330c2dc29f195163c56cf4723fc16a6c`.

PR113B exact-head remote closeout passed at Actions run `38467523568`.
PR114 must preserve that product-finish baseline while converting the cumulative
application into one final, auditable commercial release candidate.

## Evidence classes

PR114 keeps four evidence classes separate:

1. **remoteSoftware** — source/configuration/build/test/package evidence that
   repository CI can establish;
2. **physicalHardware** — real Mac/audio-device/acoustic evidence owned by
   PR112;
3. **releaseCredential** — production Apple signing, App Store Connect,
   TestFlight/App Review and optional Developer-ID/notarization evidence; and
4. **externalReview** — any explicitly selected legal/IP or independent review
   gate.

Remote CI may never promote itself into the other three classes.

## Planned slices

### Slice 1 — Release baseline reconciliation

Re-audit the actual PR113B shipping tree rather than inheriting PR102 assumptions.

- reconcile README/release documentation to the current product boundary;
- inventory bundle/version/deployment target/architectures/entitlements/privacy
  strings and shipped notices;
- preserve the PR113B exact tested base;
- classify every unresolved release gate;
- establish a new PR114 machine-readable release-readiness contract.

### Slice 2 — App Store / privacy / security finalization

- validate shipping sandbox entitlements remain minimal;
- validate permission purpose strings and permission UX ownership;
- audit production source for privileged helpers, persistent HAL installs,
  self-updaters and other App-Store-incompatible architecture;
- assess whether a PrivacyInfo.xcprivacy manifest is required for the actual
  target/dependencies and add one only if justified by current Apple rules;
- keep production Apple credentials external to source control.

### Slice 3 — Licensing / provenance / dependency / SBOM final audit

- carry forward libmysofa v1.3.4 BSD obligations;
- reconcile all production source/assets added after PR102 into provenance;
- generate a deterministic dependency/SBOM-style release manifest;
- fail closed on unclassified vendored/linked production dependencies;
- verify required notices are embedded in the Release product.

### Slice 4 — Packaging, archive and release-manifest hardening

- build arm64 Debug and unsigned Release;
- run unsigned generic macOS archive preflight;
- validate bundle metadata/resources/architectures;
- validate ad-hoc sandbox entitlement evidence separately from production
  signing;
- harden the manual DMG lane without representing it as notarized/public-ready;
- generate exact-commit/version/build/artifact hashes.

### Slice 5 — Commercial metadata / support / release documentation

- reconcile release-facing README and product boundary;
- provide App Store metadata/support/privacy handoff templates where useful;
- document screenshots/marketing/support fields that require owner input;
- preserve non-modal Getting Started / in-app reference ownership;
- define final TestFlight/App Review smoke expectations.

### Slice 6 — Integrated RC gate and handoff

- rerun inherited PR113B and release safety contracts;
- full cumulative XCTest regression;
- build/archive/package validation on one exact head;
- publish a machine-readable PR114 release-candidate readiness artifact;
- leave physical, credential, public-release and merge authority false until
  genuine evidence is supplied.

## Slice 1 implementation — release baseline reconciliation

Slice 1 is implemented as release-contract work only. It:

- pins the exact PR113B base at
  `f10008d8330c2dc29f195163c56cf4723fc16a6c`;
- reconciles README and roadmap status to PR114;
- records the actual shipping version/build/deployment target, architecture,
  bundle identifier, entitlements and classified production dependency;
- carries forward current release-hardening rules without freezing obsolete
  PR45 source strings or historical icon hashes; and
- records final commercial app-icon owner approval as an explicit unresolved
  public-release gate.

The pinned Slice 1 candidate `a4fc2eda5f72e1711f7dee91d308c75dce2950be`
passed its portable contract. Its macOS job was later cancelled by normal
workflow concurrency when Slice 2 advanced the same branch. The combined
Slices 1–2 exact-head matrix therefore serves as the authoritative macOS
checkpoint rather than fabricating an intermediate result.

## Slice 2 implementation — App Store privacy & security

Slice 2 adds `docs/PR114_APP_STORE_PRIVACY_SECURITY.md` and a branch-local
source audit.

It:

- preserves the exact three-entitlement App Sandbox posture;
- broadens the microphone purpose string from stale “Room Correction only”
  wording to all explicitly initiated measurement/calibration workflows;
- aligns Preferences permission copy with the same boundary;
- scans the actual PR114 checkout for unreconciled app-owned network clients,
  analytics/tracking/crash-upload SDKs, advertising identifiers, self-updaters,
  privileged helpers and persistent HAL-install architecture;
- records that the one classified bundled third-party production component is
  still local-only libmysofa v1.3.4 under BSD-3-Clause;
- distinguishes user-installed Audio Units from bundled Notch Sixty SDKs;
- records a deliberate macOS-only decision not to add an empty
  `PrivacyInfo.xcprivacy` when the current source/dependency audit does not
  require one; and
- leaves App Store Connect privacy-policy URL and App Privacy questionnaire
  completion false until genuine owner/account evidence exists.

The privacy-manifest conclusion is release-date sensitive and must be
re-evaluated if Apple changes the macOS requirement, a manifest-requiring SDK
is added, or another Apple platform target is introduced.

## Slice 3 implementation — licensing, provenance & SBOM

Slice 3 closes the post-PR102 supply-chain/provenance gap.

The audit finds:

- no Swift Package dependency;
- no CocoaPods or Cartfile dependency;
- no packaged third-party framework/XCFramework/dylib/static library;
- exactly one production vendor root;
- exactly one bundled third-party production component:
  **libmysofa v1.3.4 / BSD-3-Clause**;
- no unclassified GPL/AGPL production dependency; and
- user-installed Audio Units and REW/EasyEffects/CamillaDSP interoperability are
  not bundled Notch Sixty dependencies.

`docs/PROVENANCE.md` now reconciles the major first-party post-PR42 feature
families through PR113B.

`ci/build_pr114_sbom.py` emits deterministic **CycloneDX 1.5** JSON tied to
the exact source commit, with libmysofa license/notice/source-set SHA-256
evidence. CI publishes that document as the `pr114-production-sbom` artifact.

`externalLegalIPReviewComplete` remains false. Automated provenance evidence is
engineering evidence, not legal advice or external-review authority.

See `docs/PR114_PROVENANCE_SBOM.md`.

## Slice 4 implementation — packaging, archive & release-manifest hardening

Slice 4 activates and hardens the packaging evidence that was intentionally
dormant during Slices 1–3.

The PR114 macOS gate now creates all release-candidate software evidence in one
exact-head workflow run:

- Apple-Silicon Debug build;
- targeted production/product-finish tests;
- unsigned Apple-Silicon Release build;
- an **unsigned archive** using `generic/platform=macOS`;
- Release/archive metadata, architecture and shipped-notice verification;
- an ad-hoc-signed sandbox RC copy whose effective entitlements must exactly
  equal the source shipping entitlements;
- a versioned remote RC DMG and SHA-256 sidecar;
- the deterministic CycloneDX production SBOM;
- the full cumulative XCTest regression; and
- a machine-readable PR114 remote commercial RC manifest.

The RC manifest binds those results to the **exact-commit** source identity and
records SHA-256 values for the Release, archive and ad-hoc RC executables, the
remote RC DMG, SBOM, release baseline, dependency manifest, shipping
entitlements, notices and provenance/security documents.

The remote RC package is deliberately signed **ad-hoc** only. It is **not
notarized**, does not contain production Apple credentials and is not
public-distribution ready. Its purpose is to prove package shape, metadata,
architecture, sandbox entitlement continuity and deterministic artifact
identity before credentialed release work.

The manual DMG workflow remains a separate operator-triggered lane. Slice 4
hardens it by emitting `release-package-manifest.json` alongside the DMG and
SHA-256 file. That manifest records source commit, marketing version, build
number, arm64 architecture, artifact name/hash, `signature=ad-hoc`,
`notarized=false` and `publicDistributionReady=false`.

Slice 4 does not perform App Store export, production signing, notarization,
upload, TestFlight or App Review. Those remain `releaseCredential` evidence.

## Existing release foundations to reuse

PR102 already established:

- App Sandbox in the shipping target;
- the current three shipping entitlements:
  - app sandbox;
  - audio-input;
  - user-selected read/write files;
- explicit system-audio and microphone purpose strings;
- Apple-Silicon-only Release builds;
- hardened runtime;
- credential-neutral source configuration;
- unsigned App Store archive preflight;
- an ad-hoc-signed manual DMG lane with SHA-256;
- libmysofa v1.3.4 BSD redistribution notice;
- production dependency manifest; and
- exact-head release-candidate manifest concepts.

PR114 revalidates and modernizes those foundations against the much larger
PR113B product. It does not assume PR102 evidence alone is sufficient.

## Historical release-hardening reconciliation

PR114 does not run the historical PR45 validator wholesale. PR45 mixed durable
release safeguards with source-string assumptions and exact icon hashes that
the modern PR113B product has legitimately superseded.

PR114 carries forward the durable requirements in its own validator:

- engineering/validation UI remains DEBUG-only;
- Launch at Login uses public `SMAppService` APIs and does not start audio;
- permission and support/diagnostic affordances remain present;
- the manual Release-DMG lane remains arm64, checksummed and explicitly
  ad-hoc/not notarized;
- one-shot PR45 staging machinery remains absent; and
- current icon assets must be technically complete.

**Final commercial app-icon owner approval remains pending by explicit owner
choice.** PR114 must not treat historical PR45 icon hashes as final release
approval. The RC baseline records `finalAppIconOwnerApproved=false`, and public
release remains blocked until that owner approval is supplied.

## Hard authority boundary

PR114 remote completion must **not** establish or imply:

- PR112 physical H01–H08 acceptance;
- release acceptance;
- production Apple signing;
- App Store Connect upload;
- TestFlight completion;
- App Review approval;
- Developer-ID signing/notarization;
- live feed-forward ANC authorization;
- public-release authorization; or
- permission to merge the stacked PRs.

Any PR114 readiness manifest must keep these false until genuine evidence exists:

- `physicalAcceptanceComplete=false`
- `releaseCredentialAcceptanceComplete=false`
- `publicReleaseAuthorized=false`
- `liveFeedForwardANCAuthorized=false`
- `mayMergeIntoMain=false`
- `physicalEvidenceSuppliedByCI=false`

PR114, PR113B, PR113, PR112A and every ancestor remain **OPEN, DRAFT and
UNMERGED** while the owner is away from the Mac/audio system. `main` remains
unchanged.
