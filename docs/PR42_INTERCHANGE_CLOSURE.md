# PR42 — Preset / Interchange Closure

Status: **IMPLEMENTATION COMPLETE — RETAINED IN FINAL PR42 GATE**

This slice closes the release-relevant persistence/interchange obligations identified by the PR34 source audit without transplanting legacy implementation expression.

## Product boundary

All codecs are control-plane-only and terminate in current proprietary `StereoEQConfiguration` / `DynamicsConfiguration` state. File panels and disk access are user-initiated SwiftUI/AppKit actions. No import/export work occurs on the physical-output realtime callback.

The existing Content Preset / Playback System ownership boundary remains authoritative:

- EQ, phase mode, dynamics, input gain and headroom belong to Content Presets.
- physical output association, crossover/routing, room correction, speaker correction and output trim belong to Playback Systems.
- Global Bypass and Reference/Delta audition are transient session state.

## Legacy `.eqpreset` migration

The importer accepts the audited v1/v2 native preset generations and migrates them into commercial state.

### v1

- shared band array -> Linked EQ;
- `activeBandCount` retained;
- legacy bandwidth-in-octaves -> Q conversion;
- integer filter identifiers mapped by observed behavior;
- unknown identifiers fall back to Parametric with an explicit migration warning.

### v2

- explicit Linked / Stereo / Mid-Side channel mode;
- separate legacy left/right arrays are routed to the corresponding commercial banks;
- native Q and string/abbreviation filter identifiers;
- optional dynamics/processing-mode state.

### Known historical persistence defects

The importer does not fabricate information that the legacy serializer failed to preserve. In particular:

- absent Constant-Q state uses the commercial default;
- absent Linkwitz target frequency/Q uses documented commercial defaults and a migration note;
- an ordinary legacy FIR band without a reconstructible embedded kernel is skipped with a warning rather than silently replaced;
- Global Bypass is ignored because it is transient audition state.

Pause Gate timing is semantically translated: legacy Attack (open/fade-in) becomes commercial Release, and legacy Release (close/fade-out) becomes commercial Attack.

## REW interoperability

Import covers the audited REW text subset: Parametric, shelves, low/high pass, band pass and notch; ON/OFF state; direct Q; bandwidth-to-Q conversion; finite-range normalization; and explicit failure when no usable filters exist.

Export emits the representable current EQ lane and reports unsupported filter/shape information rather than approximating it silently.

## EasyEffects interoperability

Import/export covers the audited equalizer subset, including separate left/right banks, Q, gain, mute/bypass and the common Bell/shelf/pass/band-pass/notch types.

EasyEffects `input-gain` maps to Content Preset input gain. `output-gain` does **not** overwrite Notch Sixty output trim because that value is owned by the selected Playback System; nonzero imported output gain is reported to the user and exports write 0 dB with an explanatory note.

Mid/Side export is rejected rather than flattened into Left/Right and changing its meaning.

## CamillaDSP export

The commercial exporter writes current-product-derived YAML with:

- sample rate and CoreAudio device placeholders/identity;
- independent or linked L/R EQ pipeline;
- IIR mappings for the representable current subset;
- high-order low/high-pass Butterworth combo export;
- inline FIR convolution values when a current per-band kernel exists;
- deterministic channel-specific pipeline order.

Linkwitz Transform is reported/omitted until coefficient-level representation is implemented rather than approximated with a different filter.

The machine-specific physical output-matrix/crossover portion of historical CamillaDSP export is intentionally not treated as a portable 1.0 interchange requirement. The final PR42 matrix records that narrower launch boundary and preserves richer cross-runtime speaker export as post-1.0 work rather than falsely claiming it here.

## App Sandbox

Because export is now a production workflow, the sandbox entitlement is `com.apple.security.files.user-selected.read-write`; access remains scoped to explicit user-selected URLs.

## Validation

`ci/validate_pr42_interchange.py` guards migration mappings, semantic Pause Gate translation, REW/EasyEffects/Camilla surface, ownership boundaries, and the sandbox entitlement. It remains chained into the final PR42 macOS gate alongside `ci/validate_pr42_parity_closure.py`.

The interchange implementation has already passed cumulative macOS and packaged-DMG validation on the PR40+PR41+PR42 tree. Final PR42 certification is the exact-head closure run containing the completed final matrix/provenance validator, followed later by the brief user smoke pass when a Mac is available.
