# PR42 — Preset / Interchange Closure

Status: **IMPLEMENTATION COMPLETE — RETAINED IN FINAL PR42 GATE**

This slice closes the release-relevant persistence/interchange obligations identified by the PR34 source audit without transplanting legacy implementation expression.

All codecs are control-plane-only and terminate in current proprietary `StereoEQConfiguration` / `DynamicsConfiguration` state. File panels and disk access are user-initiated SwiftUI/AppKit actions. No import/export work occurs on the physical-output realtime callback.

The Content Preset / Playback System ownership boundary remains authoritative: EQ/phase/dynamics/input gain/headroom are Content Preset state; physical output association/crossover/routing/room correction/speaker correction/output trim are Playback System state; Global Bypass and Reference/Delta remain transient.

## Implemented compatibility

- Legacy `.eqpreset` v1 shared-bank migration to Linked EQ, including `activeBandCount`, bandwidth-to-Q conversion and explicit warnings/defaults for unrecoverable fields.
- Legacy `.eqpreset` v2 Linked/Stereo/Mid-Side bank migration with supported dynamics/processing state.
- Pause Gate semantic timing translation: legacy Attack=open/fade-in -> commercial Release; legacy Release=close/fade-out -> commercial Attack.
- REW filter-text import/export for the audited representable subset, with unsupported-shape warnings rather than silent approximation.
- EasyEffects equalizer import/export, including separate L/R banks and input gain. EasyEffects output gain cannot overwrite Playback System output trim.
- CamillaDSP YAML export for current proprietary content EQ/FIR state. Linkwitz Transform is omitted with a note until a coefficient-level portable representation exists.

The machine-specific private HAL Aggregate Device and physical Playback-System route topology are intentionally not serialized as though they were a portable foreign-runtime configuration. A richer cross-runtime speaker-matrix exporter remains a named post-1.0 enhancement in the final PR42 matrix.

## App Sandbox and validation

User-selected interchange files use App Sandbox user-selected read/write access only. `ci/validate_pr42_interchange.py` permanently guards migration mappings, Pause Gate translation, REW/EasyEffects/Camilla surface, ownership boundaries and the sandbox entitlement. It runs alongside `ci/validate_pr42_parity_closure.py` in the final macOS gate.

The interchange implementation has already passed cumulative macOS and packaged-DMG validation on the PR40+PR41+PR42 tree. The remaining PR42 certification requirement is a green exact-head final closure run and, when the user again has Mac access, a brief UI/interchange smoke pass.
