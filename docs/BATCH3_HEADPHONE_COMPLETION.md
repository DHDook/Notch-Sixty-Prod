# Batch 3 — Headphone Completion

**One consolidated owner-reviewed draft PR**, stacked on Batch 2 #126.
Core scope: PR124 headphone correction UX and the independently
verifiable local-proposal subset of optional PR125. No GPL relicensing,
vendor model database, research personalization, or unreviewed third-party
measurement assets are introduced.

## Finished product-facing features

### Two independent 16-band headphone PEQ editors

The existing production Headphones workspace now offers an editor for
left and right channels separately (peak, low shelf, high shelf).
Each band has independent enable, center frequency, gain and Q, with
add/remove and the product's existing 16-bands-per-ear cap. Channel
trim/delay/polarity and crossfeed remain separate device-profile settings,
not content presets. The editor binds directly to the existing serialized
HeadphoneDeviceProfileConfiguration, and applies through the previously
validated production N60HeadphoneDSPSnapshot control-plane compiler.

The paired log-frequency response view derives values from the same
N60BiquadDesign float coefficients that are sent to the live engine,
including per-ear trim and the global digital headroom cut. It is a
control-plane UI prediction of *electrical DSP* transfer, not an acoustical
measured ear response or headphone target match. Abnormal coefficient
or numerical values are excluded from the preview.

### Native HRTF/SOFA import in the actual picker

The pre-existing BinauralProfileAssetStore already parses native AES69
SOFA HDF5 with libmysofa via NativeSOFAImporter, normalizes units,
transforms azimuth handedness and bakes receiver Data.Delay into FIR.
Batch 3 finally exposes .sofa directly in the actual Headphones file
picker, in addition to Notch Sixty's normalized .json. It preserves
macOS file access scoping and stores its normalized asset in the
already-owned application sandbox. Native .sofa parsing is strictly
off the realtime audio callback. The earlier PR117D real generated
SOFA/HDF5 XCTest suite runs again at the final macOS integration gate.

**Explicit rate policy:** a selected HRTF's sample rate must exactly
match the output nominal rate (within existing 0.5 Hz tolerance).
The UI displays a blocking mismatch message; both the profile's
validateStructure and Core Audio binaural transport independently
reject mismatches. **No silent 48→384 kHz HRTF resampler exists.**
The product continues to target common sample-rate families through
384 kHz. A DAC's actual native transport and CPU/thermal capacity need
owner-supervised real-Mac validation.

### Local optional model-correction proposal

The optional user-supplied correction JSON includes schemaVersion=1,
headphoneModel, sourceName, sourceAttribution, sourceLicense,
optional referenceSampleRate and distinct leftBands/rightBands.
The import is a small 64 KiB bounded decode with 16 per-ear maximum,
unique UUIDs, filter frequency/gain/Q validation and optional strict
sample-rate declaration. It shows source attribution and the stated
license, which are **not** independent rights clearance or verified
measurements. It never downloads a model database, chooses a profile
automatically or modifies active playback. The user deliberately
chooses **Stage Bands in Draft**, at which point an automatic *extra
attenuation* floor conservatively covers all enabled positive gains
and the ordinary stopped-playback **Apply** action is still required.
Unqualified/unknown source and invalid band/rate inputs fail closed.

Example *illustrative only*, not a valid measured correction target:

    {
      "schemaVersion": 1,
      "headphoneModel": "Example headphone, user-supplied",
      "sourceName": "User measurement export",
      "sourceAttribution": "User documented measurement source",
      "sourceLicense": "User must verify permitted use",
      "referenceSampleRate": 48000,
      "leftBands": [{
        "id": "53BCAAF0-1660-4A1F-BD57-1CBD55DDB81E",
        "enabled": true,
        "type": "peaking",
        "frequencyHz": 1000,
        "gainDB": 0.5,
        "q": 0.707
      }],
      "rightBands": []
    }

The sample schema is intentionally explicit and documented; neither
an unverified licensed database nor a claimed "universal target"
constitutes the product's headphone correction engine.

## Evidence and acceptance gates

- Python source/ABI contract includes control-plane-only state, both
  independent EQ editors, explicit SOFA UTType, rate refusal, headroom,
  provenance, Xcode test membership, and no new implicit SRC.
- Swift XCTest covers actual compiled 384 kHz 16-band independent
  snapshots and serialization; coefficient-derived left/right response;
  headroom rejection and increase on staged proposals; missing source
  attribution and mismatched sample rates; explicit 48-versus-384 kHz
  virtual speaker refusal; disabled-band neutrality.
- Existing native SOFA and binaural-reference numerical tests continue
  to cover 44.1/48 families through **384 kHz**. The full macOS gate
  generates actual synthetic AES69 SOFA NetCDF4/HDF5 and runs cumulative
  Debug XCTest plus arm64 Release, not a marker-only source check.
- No production DSP C code or audio callback was modified. Every
  interface enhancement stays on the control plane.

## Explicit incomplete physical and research acceptance

- Real headphone model correction is only as trustworthy as the
  user's input measurement, target, microphone/calibration method,
  licensing and device-specific seal. The product does not claim
  validated corrections for a database/model that hasn't been
  independently vetted.
- The head-tracked virtual speaker motion transport is already in
  product. Personalized HRTF selection and model-specific measurement
  databases remain OPTIONAL post-core research (PR125 expansion / PR126).
- PR112 real Mac H01–H08, the sound output chain, actual 384 kHz
  compatibility and headset loudness/safety tests remain owner
  acceptance items. No simulated results authorize ANC or shipping.
- Keep this PR OPEN/DRAFT/UNMERGED; do not update main or ancestral PRs.

## GitHub Actions efficiency

Routine pull requests run only fast portable checks. The expensive
Apple Silicon Release/full XCTest runner is triggered deliberately by
the integration-ci PR label event, workflow_dispatch, or a single
commit annotated [integration-ci]. All requirements are run at the
exact tested SHA; any later edits invalidate its certificate.
