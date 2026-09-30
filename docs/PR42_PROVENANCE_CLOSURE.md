# PR42 — Provenance / Third-Party Closure

Status: **FINAL COMMERCIAL PROVENANCE RECONCILIATION**

This document closes the provenance delta from the living `docs/PROVENANCE.md` register through PR42 and is the controlling PR42 evidence for the PR34–PR42 production surface.

## Clean-room conclusion

The production tree remains a proprietary clean-room rewrite.

- Historical GPL Notch Sixty / Equaliser source was used only to inventory externally observable behavior, compatibility data, known defects and migration semantics.
- Historical GPL source expression, tests, project metadata and implementation structure are not production implementation sources.
- No GPL/AGPL package is linked into the shipping target.
- The production repository has no approved third-party source dependency; platform functionality is provided by Apple frameworks.
- Public DSP/acoustic specifications and standard mathematical formulas are implementation references where noted, not copied code.

## PR34 — Core parity expansion

**Classification:** specification-derived / original commercial implementation.

Commercial additions including Band Pass, Constant-Q Peak, Linkwitz Transform, high-order LP/HP/shelf compilation, Tilt, Mid/Side, per-band FIR, Mixed Phase, Symmetry Balance, speaker crossfeed/crosstalk cancellation and Sub phase alignment were independently implemented against the existing proprietary realtime graph and public DSP mathematics. Legacy source established only observable contracts and defects.

No historical source/tests were ported. The source audits under `docs/PR34_*_AUDIT.md` are behavioral evidence, not code provenance.

## PR35 — Realtime performance/readiness architecture

**Classification:** original commercial implementation.

Immutable snapshot ownership, bounded transition acknowledgement, optional-stage parking, demand-gated telemetry, sparse-reset equivalence validation and realtime benchmarks were designed directly against the proprietary N60 graph. No third-party realtime framework or historical optimization code was imported.

## PR36–PR38 — Production UI / Equalizer / Dynamics

**Classification:** original commercial implementation.

The SwiftUI production shell, Equalizer workspace and Dynamics workspace are newly authored presentation/control-plane code against the proprietary models. Historical UI was used only to inventory capability and naming where needed. PR42's Dynamics presentation cleanup uses native SwiftUI `LabeledContent`, materials and text-field styles without copying another application.

## PR39 — Metering, analysis, profiles, and identity

### Metering / analysis

**Classification:** specification-derived / original commercial implementation.

Production RTA, VU/level views, phase correlation and goniometer consume proprietary demand-gated analysis data. Standard spectral/stereo analysis concepts are used; no external analysis library is bundled.

### Content Presets / Playback System Profiles

**Classification:** original commercial implementation.

The two-layer commercial archive and transactional ownership model are proprietary designs. They do not reuse the historical preset store structure.

### App artwork

**Classification:** asset with verified rights / owner-authored reuse.

`docs/PR39_APP_IDENTITY_STATUS.md` records that the Notch Sixty analog-meter artwork is user-authored. The owner-authored artwork was deliberately reused from the user's legacy project under the owner's independent rights, not because of the historical GPL distribution. Production light/dark derivatives and retained SVG source files are therefore cleared owner assets. No Equaliser branding, external font file or third-party branding asset is bundled by PR39.

## PR40 — Room Correction production workflow

**Classification:** specification-derived / original commercial implementation.

Sources of truth:

- proprietary Room Correction runtime and Playback System ownership model;
- Apple microphone/capture APIs;
- published exponential sine sweep measurement literature (including Farina's public AES measurement method);
- general acoustic transfer-function, interpolation, smoothing and minimum-phase concepts.

PR40's calibration controller, ESS synthesis/capture bridge, deconvolution/analysis, project model/store, spatial aggregation, target designer, FIR designer and production workspace are independently authored. Legacy Room Correction source/tests were not coding references.

## PR41 — Physical speaker routing / Active Crossover

**Classification:** specification-derived / original commercial implementation.

The 2–8 route model, same-device output map, private Aggregate Device plan/session, reference-clock selection, HAL drift compensation, speaker-bus splitter, Mains+Sub/Bi-Amp/Tri-Amp crossover behavior and driver-safe Global Bypass rules were independently authored against public Core Audio APIs and standard Linkwitz-Riley filter mathematics.

The legacy Software PLL was not ported. PR41 deliberately uses Core Audio Aggregate Device clocking instead.

## PR42 — Preset/interchange compatibility

**Classification:** original commercial implementation from interoperability specifications and behavioral compatibility requirements.

The `.eqpreset` migration code is a one-way compatibility reader written against the proprietary `StereoEQConfiguration` / `DynamicsConfiguration` models. Legacy JSON field names and enumerated user-visible values are data-format compatibility facts; no legacy serializer/parser source expression was copied.

REW and EasyEffects support is independently written from their public/user-visible interchange formats and the audited compatibility subset.

CamillaDSP YAML export is independently generated from current proprietary state. CamillaDSP is not linked, embedded or redistributed. The exporter emits text configuration only.

No external YAML/JSON library is added; Foundation serialization and direct text generation are used.

## Apple frameworks / system libraries

The production target relies on Apple SDK frameworks and system libraries available on the supported macOS platform, including SwiftUI/Foundation/AppKit/Combine and the Core Audio/graphics/Accelerate facilities used by the project. These are platform APIs, not third-party code shipped in the app bundle by this repository.

## Package/dependency inventory

PR42 repository review finds no approved package-manager dependency that introduces third-party production source. There is no production Swift Package dependency, CocoaPods/Carthage vendor tree, or bundled third-party DSP library recorded by the project.

If a dependency is added later, it must be entered in both `docs/PROVENANCE.md` and `THIRD_PARTY_NOTICES.md` before release.

## Interoperability names

REW, EasyEffects and CamillaDSP names appear only to identify user-requested compatible file/configuration formats. Their software is not embedded or linked and their names do not imply endorsement.

## PR42 provenance result

- unexplained production source origin: **none identified**;
- unresolved GPL/AGPL production dependency: **none identified**;
- third-party linked production component requiring a notice: **none identified**;
- owner-authored reused asset without an ownership basis: **none identified**;
- PR34–PR42 implementation areas without a provenance classification: **none identified**.

The commercial provenance gate is closed for the current PR42 tree, subject to the normal release-time recheck if new source, assets or dependencies are added after this audit.
