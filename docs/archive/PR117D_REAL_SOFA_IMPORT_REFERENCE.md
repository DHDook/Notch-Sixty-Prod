# PR117D — Real AES69/SOFA Import Regression

**Slice 5 of PR117, based on PR117C. OPEN/DRAFT/UNMERGED.**

## Product scope

This is the real-file end-to-end test previously absent from the independent
normalized SOFA view references. It uses the **existing native SOFA HDF5
bridge** (pinned libmysofa reader) plus the existing Swift importer and
SOFABinauralAssetAdapter, without creating a competing parser, importer,
resampler, or realtime audio stage.

At macOS CI runtime, the script ci/generate_pr117d_sofa_fixtures.py creates
four small, deterministic, license-clean **actual NetCDF4/HDF5 .sofa files**.
No SOFA binary samples are checked into GitHub. All fixtures declare synthetic
license CC0-1.0 and use explicit listener coordinates, spherical source
coordinates, FIR data, source metadata and sample-rate/delay attributes.

- integer384.sofa: 384,000 Hz, receiver delays 2 and 5 samples. Native load,
  HRTF azimuth handedness (-30/+30), per-ear FIR tap index/amplitude, and
  store import/persist/reload are checked.
- fractional48.sofa: 48,000 Hz, delays 0.5 and 1 sample. Native import,
  finite normalized fractional-delay output and expected DC weight are checked.
- negative441.sofa: 44,100 Hz, delays -1 and 0 samples. Common-offset delay
  baking retains relative timing and source-per-ear amplitude.
- nonfinite384.sofa: same 384 kHz file with NaN Data.IR, expected to be
  rejected by the native bridge before an audio asset can be constructed.

The original PR85 actual-file fixture is generated alongside, ensuring its
existing native import test executes rather than being silently skipped.

## Verified vs not verified

The new macOS job uses real files, native C HDF5 decoding, Swift coordination,
import to the normalized binaural asset and a temporary round-trip asset
store. It distinguishes this from PR117C's pre-normalized synthetic arrays.
It enforces the exact file sampling rate in stored metadata; it **does not
silently convert** a 48 kHz HRTF into a 384 kHz HRTF. The playback
preparation/rendering layer must explicitly reject mismatches or use
separately tested resampling before later claiming 384 kHz end-to-end.

It is NOT evidence of output device 384 kHz support, every AES69 convention,
realtime HDF5 decoding (forbidden), arbitrary coordinate frames or Data.Delay
unit variants, physically personalized HRTFs, perceptual localization,
CPU/thermal safety or headphone listening validation. Owner-supervised
hardware acceptance remains open under PR112.

## Fast workflow

Portable source contract plus inherited PR85/PR117C guards runs on Ubuntu.
Only the macOS leg installs netCDF4/numpy to **generate** fixtures (not a
shipping dependency) and executes focused NativeSOFAImporterTests under
Apple Silicon. No duplicate full Release build for a test-only slice.
Production files, sample-rate negotiation and audio DSP remain unchanged.

Later testing should cover more atypical SOFA layouts and file-metadata units,
explicit intentional resampler policy, declared HRTF latency, and real
headphone perceptual evaluation. Keep all parent and child PRs draft/unmerged.
