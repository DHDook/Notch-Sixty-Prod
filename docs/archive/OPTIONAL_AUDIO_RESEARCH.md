# Optional Research Expansion — Three Post-Core Capabilities

**One consolidated draft PR** stacked on software-green Batch 4 #128.
**No code merge or physical/release authorization.** These additions must not
obscure the completed core product or force new dependencies into realtime DSP.

## 1. Adaptive Mixed-Phase Research (formerly proposed PR120)

Tools → Acoustic Research now examines the selected Room Correction FIR's
**actual generated minimum-phase left/right taps**. It builds an offline
causal, bounded mixed-phase proposal blending a specified symmetric component
with the existing measured-source-derived filter. The independent numerical
audit Fourier-transforms **actual candidate Float taps**, comparing them to
the source minimum-phase transfer. It displays:

- selected real sample rate through 384 kHz and available FIR tap budget;
- symmetric-share fraction and added delay budget (<=30 ms);
- maximum across-frequency magnitude deviation;
- pre-ringing energy prior to the declared delay;
- maximum filter gain, conservative attenuation and audible/technical blockers.

A candidate that exceeds ±1 dB magnitude drift, 15% pre-ring energy,
6 dB attenuation allowance or 30 ms delay is blocked. Even one that
passes remains **preview-only**: minimum-phase is still the authoritative
deployment choice. No rendered tap vectors are sent to the live graph or
stored as approved correction. The technique is deliberately limited to
tested FIR mixing, not a claim of optimized room phase inversion or group
delay. A measured acoustic improvement still needs PR112 physical evidence.

## 2. User-guided binaural/HRTF preference and interpolation (PR126 research)

The same Tools screen browses real **previously imported SOFA/HRTF files**
from the existing BinauralProfileAssetStore. It reports if the asset's
sample rate matches the currently selected output. Direction preview
uses unit-vector angular distance, a strict 30° maximum gap, up to three
recorded nearby directions with bounded inverse-square weights and per-ear
onset-aligned HRIR interpolation. Exact recorded directions reproduce
the original impulse; missing coverage fails closed rather than inventing
an HRTF. Measured phases, an individual ear shape, frequency-dependent
ITD interpolation or personalized binaural accuracy are **not** assumed.

A local HRTFAuditionPreferenceStore records a voluntary 1–5 subjective
rating and short user notes for an existing imported asset. This is an
on-device preference journal, NOT a biometric dataset or machine learning
model; it makes no network connections. The Headphones screen can select
an already-imported HRTF into its editable, unsaved draft, but still
requires a matching sample rate, stopped-playback Apply and the existing
true-peak/headroom protections. The interpolated impulse never enters
realtime playback without separate independent verification.

## 3. Source-provenance-aware headphone-model correction library (PR125)

The Headphones UI now imports user-provided, local JSON records of
**16–256 strictly increasing measured frequency points**, each with
separate left/right dB response and an explicit target dB value,
model name, credited source/attribution, stated license and acquisition
notes. The store is App Sandbox Application Support, limited to 256
files and 128 KB per file; it does not download, bundle or redistribute
a third-party measurement database. A stated license is metadata, not
legal permission to republish the file. Invalid, non-finite or
uncredited responses are rejected.

The model fitter generates 1–16 editable PEQ candidate bands per ear
(default max 8), using bounded +6 / -12 dB gains and a fixed safe Q
search. Its greedy score uses the **actual production biquad transfer**
on the supplied target grid, and exposes each ear's before/after
modeled RMSE, worst-point regression and required digital headroom.
The result is a HeadphoneCorrectionProposal with full provenance.
It is NEVER individually calibrated, verified at the eardrum, automatically
applied, or allowed to bypass the existing Stage in Draft and
stopped-playback Apply operations. Headphone coupling, seal, measurement
apparatus, high-frequency precision, personal target preference and
licensing remain outside its claims.

### Example local source format (synthetic, not a measured model)

\`\`\`json
{
  "schemaVersion": 1,
  "id": "00000000-0000-4000-8000-000000000001",
  "headphoneModel": "User's example headphones",
  "sourceName": "User-generated 2-ear measurement",
  "sourceAttribution": "The measurement creator",
  "sourceLicense": "License to be independently verified",
  "acquisitionNotes": "Calibration and measurement setup description",
  "points": [
    {"frequencyHz": 20, "leftMagnitudeDB": 0, "rightMagnitudeDB": 0, "targetMagnitudeDB": 0}
  ]
}
\`\`\`

**Note:** a real file must contain at least 16 valid increasing points; the
single-point example above documents keys only and intentionally fails
validation. The model is not a built-in headphone database entry.

## Validation and scope

- **One draft PR**, one final exact-head CI: portable model/UX/source
  guards, eight-rate C/Python reference lab, calibrated headroom/routing
  guards, generated real native SOFA/HDF5 files, Apple Silicon Release and
  full cumulative XCTest.
- New Swift tests check all standard 44.1–384 kHz rates for the
  mixed-phase identity, high gain rejection, bad/non-finite taps, HRTF
  nearest/wrapped-angle/coverage behavior, listener-rating persistence,
  model fitting at several output rates, per-ear independence, local
  provenance and rejection of malformed measurements.
- **No** new network SDKs, model binaries, bundled audio datasets,
  production C realtime changes, automatic phase correction, unauthorized
  ANC or altered Speaker/Main/Sub safety protection.
- **Still required:** actual DAC rate support, real measured per-seat
  acoustic response, personalized HRTF ear/listening tests, headphone SPL
  safety, IP/source-rights review and owner PR112 H01–H08 physical campaign.
  CI success alone cannot authorize a release or merge.
