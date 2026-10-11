# PR102 — Integration & Commercial Release Preparation

Status: **IN PROGRESS — STACKED ON PR101 REMOTE SOFTWARE CLOSURE**

## Purpose

PR102 is the final integration and commercial-release preparation milestone for
the cumulative Notch Sixty product before the newly approved Speaker Optimizer
feature track.

PR102 does not add another DSP subsystem. It reconciles the accumulated product
surface, release metadata, licensing/provenance, sandbox configuration,
packaging, acceptance evidence, and release gates into one coherent commercial
release candidate.

The PR is stacked on PR101 exact head
`50532a0107853a02d762ec0c982456c13fa1d206`, whose exact-head PR101 workflow
run 38158055259 passed.

## Release-readiness evidence classes

PR102 uses four distinct classes. They must not be conflated:

1. **remoteSoftware** — source/configuration/CI evidence that can be established
   without physical hardware;
2. **physicalHardware** — real Mac/audio-device/acoustic evidence;
3. **releaseCredential** — Apple signing, App Store Connect, TestFlight, or
   notarization evidence that requires production credentials/services; and
4. **externalReview** — legal/IP or independent review evidence when explicitly
   selected as a release gate.

A remote CI pass cannot satisfy a physical-hardware or release-credential gate.

## Slice 1 — Release inventory and contract reconciliation

PR102 starts by auditing the actual cumulative shipping tree rather than relying
on earlier v1 documents.

### Confirmed release foundations

- App Sandbox is enabled in the shipping target.
- Shipping entitlements currently request only:
  - App Sandbox;
  - audio-input access; and
  - user-selected read/write file access.
- The production target uses an explicit Info.plist with system-audio-capture
  and microphone usage descriptions.
- The app target is Apple-Silicon-only and currently declares:
  - bundle identifier `com.dhdook.NotchSixty`;
  - marketing version `1.0.0`;
  - build number `1`;
  - macOS deployment target `27.0`;
  - hardened runtime enabled.
- No development-team identifier is hard-coded into the project.
- A manual Release-DMG workflow already builds the Release app, validates
  metadata/sandbox posture, ad-hoc signs it, creates a versioned arm64 DMG, and
  emits a SHA-256 checksum.
- That DMG workflow correctly states that ad-hoc signing is **not** production
  Developer-ID signing/notarization.

### Product-boundary drift that must be reconciled

Earlier README/roadmap material still describes a stereo-only/headphone-out-of-
scope product boundary. The cumulative branch now includes approved semantic
multichannel, headphone/binaural/head-tracking, Audio Unit hosting, advanced
room-treatment/ambient features, and Active Acoustics foundations.

PR102 must update release-facing documentation so the product that is described,
tested, packaged, and reviewed is the product actually present in the tree.

### Third-party notice discrepancy discovered by PR102

The current tree vendors a reader/HDF subset of **libmysofa v1.3.4** under
`NotchSixty/Audio/SOFA/Vendor/libmysofa` and compiles those source files into
the production application target for native SOFA decoding.

The vendored component carries the BSD 3-Clause license. That license is
compatible with proprietary redistribution when its notice conditions are
followed.

However, the current root `THIRD_PARTY_NOTICES.md` predates this addition and
still states that there is no linked or bundled third-party production
dependency requiring a redistribution notice. That statement is now stale.

PR102 must:

- identify libmysofa v1.3.4 in `THIRD_PARTY_NOTICES.md`;
- reconcile `docs/PROVENANCE.md`;
- retain the exact upstream license;
- ensure the required notice text is included in material shipped with the
  application rather than existing only in the source repository; and
- add a release validator that prevents this notice from silently disappearing.

No GPL/AGPL production dependency has been identified by this Slice 1 audit.

## Planned PR102 slices

### Slice 2 — Product/release metadata reconciliation

- update README and roadmap status to the cumulative approved product boundary;
- distinguish shipping capabilities from hardware-gated/experimental
  capabilities;
- reconcile version/build/deployment-target ownership;
- establish one machine-readable release-readiness catalog.

### Slice 3 — App Store and distribution configuration

- validate sandbox and privacy usage descriptions;
- validate Release/Archive build settings;
- define unsigned/ad-hoc CI package evidence separately from production signing;
- add an App-Store archive/export preparation path that does not fabricate
  credentials;
- verify no privileged helper/driver/root/self-updater architecture has entered
  the production target.

### Slice 4 — Licensing, provenance, SBOM and shipped notices

- complete cumulative dependency/provenance reconciliation through PR101;
- ship third-party license/notice material with the product;
- generate a deterministic release dependency/SBOM-style manifest;
- fail CI if an unclassified vendored/linked dependency appears.

### Slice 5 — Integrated release-candidate gate

- Release build and archive/package validation;
- full XCTest regression;
- retained PR101 reliability/safety gates;
- package metadata and architecture verification;
- reproducible release manifest containing commit/version/build/artifact hashes;
- explicit unresolved hardware/credential gates.

### Slice 6 — Hardware/credential handoff and closure

Remote closure may mark **PR102 remote release preparation complete**, but must
leave the following unresolved until genuine evidence exists:

- real device unplug/replug;
- real sleep/wake;
- prolonged thermal/endurance playback;
- speaker/emergency-mute safety;
- final acoustic acceptance;
- any remaining physical Active Acoustics/ANC qualification;
- production Apple signing/export;
- TestFlight/App Store Connect/App Review; and
- any selected external legal/IP review.

## Post-PR102 feature track

The newly approved Speaker Optimizer roadmap begins after PR102:

- PR103 — Optimizer Measurement Foundation;
- PR104 — Measurement-Driven Speaker Optimization Engine;
- PR105 — Guided Speaker Optimizer & Acoustic Verification;
- PR106 — Advanced Speaker Measurement Lab.

This ordering keeps PR102 focused on release integration rather than reopening
the feature surface while release contracts are being reconciled.


## Implementation checkpoint — Slices 1–5

The remote implementation for Slices 1–5 is now present on the PR102 branch:

- release inventory/evidence classification;
- cumulative product-boundary reconciliation;
- App Store/sandbox and unsigned archive preflight;
- libmysofa licensing/provenance reconciliation plus shipped BSD notice;
- fail-closed machine-readable production dependency manifest; and
- same-run remote release-candidate manifest tying validation, Debug/Release
  builds, archive preflight, and full XCTest to the exact commit/run.

The current release-candidate manifest deliberately keeps hardware, Apple
credential, and public-release authorization gates false/unresolved.

## Slice 6 — Closure and handoff

PR102 now includes:
- `docs/PR102_RELEASE_HANDOFF.md`, the physical Mac/audio/acoustic and Apple
  credential checklist; and
- `docs/PR102_SOFTWARE_CLOSURE.md`, the formal remote closure record.

Slice 6 remains pending until the exact branch head successfully generates the
formal `PR102_REMOTE_RELEASE_CANDIDATE` artifact. Documentation alone cannot
self-certify the release candidate.
