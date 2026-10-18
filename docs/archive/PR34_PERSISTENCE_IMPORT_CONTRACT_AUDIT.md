# PR34 Legacy Persistence / Import-Export Contract Audit

Status: **SOURCE/TEST AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

The commercial rewrite intentionally deferred product persistence while the realtime graph was being rebuilt. This audit establishes what legacy files actually preserve, what migration semantics are required, and which apparent model fields were never really persisted.

## 1. Native preset format

Legacy user presets use the `.eqpreset` extension and JSON serialization with an explicit integer `version`.

Two format generations are directly covered by legacy migration tests:

### Version 1

- one shared `bands` array,
- explicit `activeBandCount`,
- no `channelMode`,
- no separate right-channel bands,
- filter type stored as an integer raw value,
- bandwidth stored in octaves rather than native Q,
- missing factory-preset metadata is accepted.

Migration behavior:

- defaults to Linked channel mode,
- copies the shared v1 band list to both left and right state,
- converts stored bandwidth to Q,
- maps known historical filter raw values,
- unknown filter raw values fall back to Parametric rather than aborting the entire preset.

### Version 2

- `channelMode` stored explicitly,
- separate `leftBands` and `rightBands`,
- Q stored natively,
- filter type stored by string/abbreviation,
- active count derived from the stored band arrays,
- dynamics and processing mode are optional backward-compatible additions.

**Classification: LATER MILESTONE — persistence / preset compatibility, with migration support required before commercial release.**

The commercial preset schema does not have to reuse the legacy representation internally. It should have its own versioned model and a one-way legacy importer.

---

## 2. Preset state that is intentionally transient

Legacy regression tests explicitly require `globalBypass` **not** to be encoded in current presets. Old files containing the key must still load, but bypass must return to false.

This establishes a useful product rule:

- A/B audition/transient bypass state is not part of a musical preset.

**Commercial requirement:** keep global/reference audition controls transient unless a future product design deliberately introduces a separate session/workspace snapshot format.

---

## 3. Band persistence contract

Where the legacy preset serializer is complete, the per-band persisted contract includes:

- frequency,
- Q (or migrated v1 bandwidth),
- gain,
- filter type,
- bypass,
- slope, with **12 dB/oct default when absent**,
- Dynamic-EQ enabled flag when present,
- Dynamic-EQ parameters when present.

Legacy regression tests explicitly guard slope and Dynamic-EQ application back into the live EQ model.

The commercial legacy importer should preserve those values where the corresponding commercial processor exists. If an imported band uses a capability whose clean-room implementation is not yet available, the importer should report that unsupported item clearly rather than silently substitute a different filter.

---

## 4. Important legacy persistence defect: Constant-Q and Linkwitz target frequency

The old `PresetBand` model contains coding-key/property declarations for:

- `constantQ`,
- `linkwitzTargetHz`.

However, the actual legacy source does **not** complete the persistence path:

- the custom decode path does not read either value,
- the encoder does not write either value,
- `init(from eqBand:)` does not copy either value,
- `toEQBandConfiguration()` does not restore either value,
- `PresetManager.applyPreset()` does not apply either value.

Therefore historical `.eqpreset` files written by this legacy code cannot be assumed to preserve those live settings.

**Commercial migration rule:** do not invent missing Constant-Q or Linkwitz target values from unrelated preset data. Import what exists; use documented commercial defaults for absent values and, where appropriate, show a migration note for legacy Linkwitz/Constant-Q presets whose full live state could not have been serialized by the old app.

This is a legacy file-format limitation, not new commercial parity debt.

---

## 5. FIR persistence boundaries

The old ordinary `PresetBand` schema does not persist a per-band FIR kernel. Consequently per-band FIR behavior may exist live but is not reconstructible from a normal `.eqpreset` band entry alone.

The legacy advanced Dynamics configuration does serialize its own `firImpulseResponse` configuration, so that separate advanced global FIR slot belongs to the dynamics/preset migration contract.

The separate global `convolutionConfig` / FIR Correction slot is not part of `PresetSettings` in the audited native preset model.

**Commercial implication:** preset compatibility must distinguish DSP state that was actually embedded in `.eqpreset` from app/session resources that required separate IR files/bookmarks. Do not claim a full FIR preset round-trip where the source format never contained the kernel/resource reference.

---

## 6. Dynamics backward compatibility

Legacy preset decoding treats Dynamics configuration as optional and defaults missing fields safely. The dynamics audit already identified additional migration semantics that the commercial importer must apply, especially:

- legacy Pause Gate Attack -> commercial Release (open/fade-in),
- legacy Pause Gate Release -> commercial Attack (close/fade-out),
- preserve explicitly stored compressor makeup gain,
- preserve stored De-Esser and multiband values rather than replacing them with new-product defaults,
- preserve stored limiter enabled state.

Additional legacy regression tests confirm missing newer fields should receive documented defaults instead of causing preset decode failure (for example Sub-Bass Phase Q and Infrasonic Filter state).

**Classification: LATER MILESTONE — persistence / legacy migration.**

---

## 7. REW filter-text import is a confirmed product workflow

Legacy tests establish support for REW-style text filter files.

Accepted mappings include:

- `PK`, `PEQ`, `PA`, `PARAMETRIC` -> Parametric,
- `LS`, `LOWSHELF` -> Low Shelf,
- `HS`, `HIGHSHELF` -> High Shelf,
- `LP`, `LOWPASS` -> Low Pass,
- `HP`, `HIGHPASS` -> High Pass,
- `BP`, `BANDPASS` -> Band Pass,
- `NOTCH` -> Notch.

Other behavior:

- `OFF` filters are imported as bypassed rather than discarded,
- `None` filters are skipped,
- Q is accepted directly,
- `BW/60` is converted to Q,
- missing Q/BW receives a default Q,
- out-of-range frequency/gain/Q values are clamped with warnings,
- an input containing no usable filters is an error rather than a silent empty preset.

The historical clamping tests used the then-current legacy EQ ranges; the commercial importer should clamp to the commercial supported ranges and report any changed value rather than blindly retaining obsolete limits.

**Classification: LATER MILESTONE — import/export.**

Band Pass support is a prerequisite for lossless import of the full legacy REW subset.

---

## 8. EasyEffects import/export is a confirmed product workflow

Legacy tests confirm bidirectional EasyEffects equalizer interoperability for the EQ subset:

- Left and Right band collections,
- input gain,
- output gain,
- Q,
- mute <-> per-band bypass,
- Parametric/Bell,
- Low Pass,
- High Pass,
- Low Shelf,
- High Shelf,
- Band Pass,
- Notch.

Band ordering is preserved and the tested supported subset round-trips.

**Classification: LATER MILESTONE — import/export.**

Again, commercial Band Pass parity is a prerequisite for lossless support of the full previously accepted subset.

---

## 9. CamillaDSP export is substantially broader than a simple EQ-text export

Legacy tests establish a real CamillaDSP YAML export surface containing:

- `devices`, `filters`, `mixers`, and `pipeline` sections,
- sample rate,
- per-channel EQ,
- bypass omission,
- IIR filter-type mapping including All-Pass and Band Pass,
- per-band FIR exported as convolution values when a kernel exists,
- active crossover definitions,
- high-order crossover slope/order mapping,
- per-output delay,
- per-output gain trim,
- polarity inversion,
- per-output all-pass/group-delay coefficients,
- output-matrix mixer dimensions/routing,
- deterministic pipeline ordering with EQ before crossover before mixer.

**Classification: LATER MILESTONE — advanced export, naturally after Active Crossover Matrix / per-output processing.**

A commercial CamillaDSP exporter should be generated from the new product graph, not by transplanting the legacy YAML writer.

---

## 10. AutoEQ export

The legacy source contains AutoEQ export support, but the rewrite's product scope explicitly excludes headphone-focused functionality.

**Classification: OUT OF CURRENT PRODUCT SCOPE**, unless a speaker-oriented AutoEQ-compatible interchange use case is separately defined later.

---

## 11. Factory presets

Legacy factory presets are source data, not a reason to inherit obsolete DSP defaults mechanically. Commercial factory presets should be recreated/tuned against the final commercial graph, while preserving user-recognizable preset intent where useful.

**Classification: LATER MILESTONE — product preset pack / production UI.**

Legacy user-created `.eqpreset` migration is a compatibility requirement; legacy factory preset byte-for-byte identity is not.

---

# 12. Commercial persistence acceptance requirements

The later persistence milestone should include deterministic tests for at least:

1. commercial native-schema round-trip of every supported processor field,
2. schema version migration,
3. v1 legacy `.eqpreset` migration,
4. v2 legacy `.eqpreset` migration,
5. unknown/unsupported field tolerance where safe,
6. explicit warning for unsupported legacy filter/process types rather than silent substitution,
7. legacy Pause Gate semantic translation,
8. missing-field defaults documented per field,
9. stereo/Mid-Side channel-state preservation once those modes exist,
10. Dynamic-EQ band/state preservation,
11. resource-backed FIR handling without embedding invalid/stale filesystem assumptions,
12. REW import regression fixtures,
13. EasyEffects import/export fixtures,
14. CamillaDSP export fixtures after the output-matrix milestone,
15. atomic writes and corrupt-file isolation so one bad preset cannot hide or destroy unrelated presets.

# 13. PR34 disposition

Persistence is **not a current realtime-DSP implementation blocker**, but it is a release-parity milestone with several now-explicit migration dependencies on current PR34 DSP blockers.

In particular, the commercial importer cannot honestly claim lossless legacy EQ migration until the core-EQ work covers the legacy filter types and channel/phase modes that can actually appear in stored files.

No production persistence code is changed by this audit slice.
