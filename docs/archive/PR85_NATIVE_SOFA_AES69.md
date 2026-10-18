# PR85 — Native AES69 / SOFA Infrastructure

PR85 adds native Spatially Oriented Format for Acoustics (SOFA) import as an offline/control-plane capability and converts supported datasets into Notch Sixty's existing normalized acoustic assets.

## Standards target

The importer treats AES69 / SOFA 2.x metadata as authoritative and supports the FIR-family data model needed by Notch Sixty:

- SimpleFreeFieldHRIR
- GeneralFIR
- GeneralFIR-E
- FreeFieldHRIR when it can be reduced unambiguously to a two-receiver FIR measurement set
- compatible two-receiver FIR room datasets that expose resolvable source/emitter geometry

The initial renderer adapter is intentionally FIR-only. TF, TF-E, SOS and spherical-harmonic representations are rejected with an explicit unsupported-data-type error rather than being approximated silently.

## Architecture

1. A vendored, pinned BSD-3-Clause SOFA/HDF5 reader lives behind a narrow C bridge.
2. The C bridge owns file parsing and exposes immutable metadata / measurement copies only.
3. Swift performs product-specific validation, provenance capture, coordinate normalization and conversion into `BinauralProfileAsset`.
4. Realtime DSP never parses SOFA/HDF5, touches file I/O, allocates importer state, or depends on the third-party reader.
5. Imported data is persisted in the existing `.n60binaural` normalized format, so playback remains independent of the source file after import.

## Safety / fidelity rules

- Require `Conventions=SOFA`.
- Require a finite positive sampling rate.
- Require exactly two receivers for binaural import.
- Bound M, E, N and total FIR samples before allocating/copying.
- Reject non-finite coordinates, delays or IR samples.
- Respect FIR/FIR-E dimension semantics.
- Apply `Data.Delay` in samples; never discard per-receiver delay metadata.
- Normalize cartesian positions to spherical azimuth/elevation/distance before creating renderer measurements.
- Preserve source filename, SOFA convention/version, data type, room type, license and title as import provenance.
- No dataset license is assumed from the SOFA container; source-license metadata remains visible to the product.

## Dependency policy

The native reader is pinned to upstream libmysofa and retains its BSD-3-Clause notice. Only the offline reader/HDF subset required for file decoding and coordinate normalization is compiled into Notch Sixty. No upstream sample datasets are redistributed unless their individual licenses are separately reviewed.

## Out of scope

- realtime SOFA parsing
- automatic network download of HRTF databases
- TF/TF-E to FIR conversion
- SOS conversion
- arbitrary >2-receiver rendering
- spherical-harmonic decoding

Those can be layered on the normalized acoustic-data boundary in later work.
