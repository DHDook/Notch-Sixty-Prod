# PR114 — Commercial Release Candidate

Status: **IN PROGRESS — SLICE 1 RELEASE BASELINE**

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
