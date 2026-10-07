# PR85 — Native AES69 / SOFA Import

PR85 adds direct .sofa import to Notch Sixty while preserving the existing normalized BinauralProfileAsset boundary and keeping all file parsing off the realtime path.

## Architecture

SOFA file → vendored libmysofa parser → Notch Sixty validation/normalization adapter → BinauralProfileAsset → existing prepared binaural renderer.

The parser is control-plane only. No HDF5/SOFA parsing, file I/O, allocation, metadata traversal, or third-party parser state reaches the realtime callback.

## Initial supported native convention

The production importer accepts AES SOFA FIR HRTF datasets that normalize to the existing two-receiver renderer boundary, with SimpleFreeFieldHRIR as the first-class convention. Unsupported convention/data combinations fail explicitly rather than being guessed.

## Validation

- SOFA/HDF5 parse success/failure is bounded and surfaced as typed errors.
- Dataset dimensions must be M > 0, R = 2, N > 0, C = 3, I = 1.
- Sampling rate must be singular, finite, and positive.
- Source positions must be finite and convertible to spherical azimuth/elevation/distance.
- Data.IR must contain exactly M × R × N finite samples.
- Tap counts must remain within Notch Sixty's binaural FIR capacity.
- Imported assets receive a fresh UUID and preserve source filename plus SOFA convention provenance.
- Imported assets pass the same existing BinauralProfileAsset validation as normalized JSON assets.

## Dependency policy

PR85 vendors only the required libmysofa reader/check/coordinate sources plus headers under its BSD-3-Clause license. The dependency is compiled into the app and uses the platform zlib implementation; it does not depend on Homebrew, a separately installed HDF5/netCDF runtime, or a user-side conversion tool.

## Non-goals

PR85 does not change the realtime binaural convolution engine. Frequency-domain TF/SOS datasets and non-two-receiver generalized acoustic datasets may be recognized in metadata, but are not silently converted into HRTF FIR assets in this PR.
