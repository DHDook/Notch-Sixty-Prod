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

## PR34–PR38

Core parity expansion, realtime-readiness work, production UI, Equalizer and Dynamics are specification-derived and/or original commercial implementations against the proprietary N60 architecture. Public filter/dynamics mathematics and native SwiftUI APIs are implementation specifications. Historical source/tests/views were not ported.

## PR39

Metering/RTA/stereo analysis uses standard analysis concepts and proprietary demand-gated telemetry. Content Presets / Playback System Profiles are a new commercial ownership/archive model. The analog-meter identity artwork is user-authored owner-controlled material; its production light/dark derivatives and retained SVG sources are cleared under the owner's independent rights, not merely because the artwork appeared in a historical GPL repository.

## PR40

Room Correction is specification-derived / original commercial implementation from proprietary runtime requirements, Apple capture APIs, published exponential-sine-sweep/acoustic transfer-function concepts, and general interpolation/smoothing/minimum-phase mathematics. The calibration controller, ESS path, analyzer, project store, spatial aggregation, target/FIR design and production workspace are independently authored.

## PR41

Physical routing / Active Crossover is specification-derived / original commercial implementation from Apple Core Audio APIs, standard Linkwitz-Riley mathematics and product requirements. The commercial Aggregate Device/HAL drift approach intentionally replaces the legacy Software PLL; legacy PLL/SRC implementation code was not ported.

## PR42

The `.eqpreset` migration reader is independently written against proprietary `StereoEQConfiguration` / `DynamicsConfiguration`. Historical JSON field names and enum values are interoperability facts, not reused implementation expression. REW/EasyEffects support is independently authored against their public/user-visible formats. CamillaDSP export generates text YAML from current proprietary state; CamillaDSP is not linked, embedded or redistributed. Foundation serialization/direct text generation are used; no external YAML/JSON library is added.

## Platform / dependency inventory

The shipping target relies on Apple SDK frameworks/system libraries supplied by supported macOS. These are platform APIs, not third-party code bundled by this repository.

PR42 review finds no approved package-manager dependency or bundled third-party DSP library introducing production source. Any future dependency must be recorded in both `docs/PROVENANCE.md` and `THIRD_PARTY_NOTICES.md` before release.

REW, EasyEffects and CamillaDSP names identify compatible formats/workflows only and do not imply endorsement.

## PR42 provenance result

- unexplained production source origin: **none identified**;
- unresolved GPL/AGPL production dependency: **none identified**;
- third-party linked production component requiring a notice: **none identified**;
- owner-authored reused asset without an ownership basis: **none identified**;
- PR34–PR42 implementation areas without a provenance classification: **none identified**.

The commercial provenance gate is closed for the current PR42 tree, subject to the normal release-time recheck if new source, assets or dependencies are added after this audit.
