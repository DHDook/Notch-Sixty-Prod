# PR114 Slice 3 — Licensing, Provenance & Production SBOM

Status: **IMPLEMENTED REMOTELY — EXACT-HEAD VALIDATION PENDING**

PR114 re-audits the complete PR113B shipping tree instead of assuming the
earlier PR102 dependency evidence is sufficient forever.

## Production dependency result

The current macOS Release target has exactly one classified bundled
third-party production component:

- **libmysofa v1.3.4**
- upstream: `hoene/libmysofa`, tag `v1.3.4`
- license: **BSD 3-Clause**
- purpose: local decoding of user-selected SOFA/HRTF files
- realtime render path: **false**
- required upstream license retained in the vendored tree
- required binary redistribution notice shipped in
  `NotchSixty/ThirdPartyNotices.txt`

The audit finds:

- **no Swift package** reference or Package.swift / Package.resolved;
- **no CocoaPods** Podfile/lockfile;
- no Cartfile;
- **no packaged binary framework**, XCFramework, dylib or static library;
- no second `Vendor/<component>` production tree; and
- no unclassified linked/bundled third-party code.

The dependency policy continues to forbid GPL/AGPL production dependencies and
continues to reject an unclassified production dependency.

## First-party provenance reconciliation

`docs/PROVENANCE.md` now extends the commercial implementation register beyond
the old PR42 cutoff through the major post-PR42 feature families:

- advanced speaker optimization / factory content / release hardening;
- semantic N-channel and multichannel DSP;
- headphone, binaural, virtual-speaker and head-tracking;
- adaptive sample-rate / clock transport;
- ambient analysis and MIMO active room treatment;
- production information architecture;
- Audio Unit hosting and fault containment;
- native SOFA/AES69 integration;
- calibration prediction / intelligent targets / room-treatment planning;
- Active Acoustics / Quiet Zone / feed-forward foundations;
- reliability and commercial evidence tooling;
- Speaker Optimizer / Advanced Measurement Lab / coherent Sub and driver work;
- PR112A hardware-acceptance infrastructure;
- PR113 Production UX / Reference; and
- PR113B product-finish capabilities.

These rows preserve the repository's clean-room classification rules:
first-party commercial implementation, specification-derived independent
implementation, owner-controlled assets, or explicitly classified permissive
third-party code.

## Deterministic CycloneDX SBOM

`ci/build_pr114_sbom.py` produces a deterministic **CycloneDX 1.5** JSON SBOM
from:

- the PR114 release baseline;
- `release/production-dependencies.json`; and
- the exact checked-out Git commit.

The application is the root SBOM component. The dependency graph contains one
bundled third-party edge: Notch Sixty → libmysofa v1.3.4.

The libmysofa component carries release evidence properties for:

- vendored root;
- purpose;
- realtime-path classification;
- license file + SHA-256;
- shipped notice file + SHA-256;
- compiled production-source count; and
- deterministic production-source-set SHA-256.

The app component carries the exact source commit, version/build, target
platform/architecture/minimum macOS and proprietary production-source license
classification.

The generator deliberately omits a wall-clock timestamp so the same checked-out
commit and classified inputs produce byte-for-byte identical output.

## What is not a bundled production dependency

### Apple platform frameworks

Core Audio, SwiftUI, AppKit, Accelerate and other Apple SDK/platform APIs are
provided by the target platform. They are not vendored third-party binaries in
the Notch Sixty application bundle and are not represented as bundled SBOM
components.

### User-installed Audio Units

Notch Sixty can host **user-installed Audio Units**, but those components are
not shipped, linked into the Notch Sixty product at build time, or classified
as Notch Sixty bundled dependencies. The user controls what external plug-ins
are installed and selected.

### Interoperability targets

REW, EasyEffects and CamillaDSP support is **interoperability** only. Notch
Sixty independently reads/writes supported interchange formats; code from
those projects is not bundled or linked.

## Artwork and owner approval

The provenance register retains the independent ownership basis for the
owner-controlled Notch Sixty artwork. PR114's commercial release gate separately
keeps **final app-icon owner approval pending**. Ownership/provenance clearance
does not mean the owner has selected the final commercial colorway/artwork for
this RC.

## Automated release gate

`ci/validate_pr114_provenance_sbom.py` fails if:

- a Swift Package / CocoaPods / Cartfile dependency surface appears;
- a packaged binary framework/library appears;
- another vendor tree appears without classification;
- the dependency policy permits unclassified or GPL/AGPL components;
- the libmysofa classification/notices/source list drift;
- major post-PR42 provenance rows disappear;
- the SBOM is not deterministic; or
- the generated SBOM no longer describes exactly one bundled third-party
  dependency.

The generated SBOM is remote software evidence. It does not establish legal
advice, PR112 physical acceptance, production Apple credentials, App Review
approval, public-release authorization or merge authority.
