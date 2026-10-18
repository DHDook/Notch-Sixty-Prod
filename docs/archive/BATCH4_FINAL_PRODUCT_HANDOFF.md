# Batch 4 — Final Product Validation & Owner Handoff

**One consolidated reviewable draft PR, stacked on Batch 3 #127.**
Notch Sixty remains a Mac hi-fi processing tool; there is no new
production audio engine in this batch. PR122/123 core work closes with a
software integration packet, not an unauthorized public release.

## 1. Optional blind A/B/X listening (PR122)

A searchable **Tools → Blind Listening** screen and corresponding
User Guide article offer a deliberately offline, exploratory trial.
The user selects two local WAV/AIFF stereo PCM excerpts with the same
sample rate, exact frame count, peak below -1 dBFS and recorded
file RMS within 0.10 dB; both must be under 90 seconds and 128 MB.
The user must match time, mastering and subjective loudness separately:
simple RMS does NOT certify alignment, codec transparency, equal LUFS
or perceptual fairness. Reject invalid/nonfinite material. Local files
are copied only after security-scoped permission to temporary sandbox
locations and removed when the workspace closes.

A, B are labeled references; each X is an independently unpredictable
fair-coin A/B assignment, NOT a prebalanced assignment whose final
trials can be predicted. The listener must audition X before choosing.
The hidden X identity stays unavailable in the visible session until
all 12/16/24 trials complete. Completion reveals the fair-guess
one-sided exact-binomial p-value, trial scores and optional explicit
JSON export. It never automatically uploads listening evidence or
collects microphone samples. No claims of double-blind experimenter
blinding are made; the X assignment is blind to the listener only.

The tool uses Apple's bounded offline AVAudioFile analyzer and
AVAudioPlayer, not the Notch Sixty realtime render graph. It requires
live processing stopped, plays through macOS *default* routing rather
than reconfiguring the selected production route, and limits player
software volume to 20% with an additional warning to start hardware
gain low. It cannot verify physical headphone SPL, loudspeaker
headroom, 384 kHz DAC operation or calibrated processing improvement.
Even p < 0.05 is NOT a release safety or correct-DSP certificate,
and p >= 0.05 does not prove two signals sound identical.

## 2. PR123 integrated release-readiness evidence

Final Batch 4 GitHub Actions explicitly triggers expensive macOS
validation once for the selected exact SHA; ordinary PR changes run
fast source and numerical guards. The deliberate full gate covers:

- Prior PR117 core numerical/acoustic references, rate families
  44.1/48/88.2/96/176.4/192/352.8/384 kHz and 384 kHz crossover
  double-precision guards.
- Headphone native SOFA/HDF5 real *generated* fixtures, per-ear PEQ,
  no implicit sample-rate conversion, limiter/headroom invariants.
- Batch 2 Room Advisor/seat uncertainty, held-out-seat and
  multi-objective bass regression tests.
- The new real production ABX XCTest (hidden assignment, exact
  binomial, invalid/unsupported trial and audio evidence).
- Apple Silicon arm64 Release build, cumulative Debug XCTest and
  shipped CI provenance/third-party legal-notice/SBOM checks.
- PR112 H01–H08 hardware acceptance authority gates, including the
  quiet-zone live ANC authorization boundary. A software result
  cannot mark a physical gate passed.

The final **ci/build_batch4_final_handoff.py** packet runs after the
same CI job records successful check markers. It checks the exact
40-character git commit and branch, verifies that Batch 1/2/3 known
tested heads are ancestors, calculates SHA256 for key shipped source,
Xcode project, entitlements and legal/provenance notice files, and
hashes a freshly generated CycloneDX SBOM. Its flags explicitly
remain false for physical evidence, product release, external legal
IP review, native 384 kHz DAC transport, HRTF listening acceptance,
signing, Apple publishing, live ANC, and mayMergeIntoMain. File hashes
are change detectors, **not a digital code signature**.

## 3. Owner's real-Mac hardware acceptance checklist

This packet is an actionable handoff, not a claim those tests passed.
The owner needs to run H01–H08 under the existing Hardware Acceptance
workspace using *the exact final tested build*, selected Playback
System, real output and microphone identity, sample rate and buffer
frames, timestamped artifacts and qualified independent review.

1. H01–H08 according to the in-app physical runbooks: actual device
   startup, disconnect/reconnect, sleep/wake, recovery, underruns,
   extended playback and thermal behavior at real rates.
2. Verify actual DAC/Core Audio device compatibility at each rate
   advertised, including 384 kHz where a connected device supports
   it; test supported/stable rate transitions. No software-only claim
   replaces real output telemetry and listening.
3. Verify measured speaker placement, main/sub crossover summation,
   speaker/driver protection, bass phase/delay, per-seat outcomes and
   calibration with a known microphone and real speaker hardware.
4. For multichannel and physically independent Sub outputs, document
   the actual output routing matrix, synchronized clock and source
   capture configuration. Do not enable an unsupported configuration
   solely because the synthetic multi-objective reviewer rates it.
5. Headphones: low starting volume, gain staging, no clipping or
   excessive SPL, left/right PEQ isolation and phase/polarity,
   HRTF profile provenance, 48/96/192/384 mismatch rejection,
   static/head-tracked listening comfort and a deliberately selected
   actual device. Verify program-routing semantics separately.
6. ABX is optional for listener preference/discrimination, not
   required to grant hardware acoustic correction acceptance.
   Physical tests should use recorded before/after response,
   known signal conditions and separate independent checks.
7. User-facing quality audit of Dashboard/VU icons, meters, system
   audio permissions, onboarding User Guide, saved profile migration,
   disabled controls, error messages, reliable Stop, accessibility.
8. Independently review **source rights**: proprietary rewrite
   provenance, bundled libmysofa BSD license and ship notices,
   optional user-supplied model correction rights, final app
   trademarks/names, Apple privacy disclosure and microphone data
   handling. Existing SBOM automated checks cannot replace legal
   judgment.
9. Provision the owner's real Apple credentials, Developer ID or
   App Store signing, notarization if used, TestFlight, App Store
   Connect listings/privacy declarations/review and any actual
   commercial release pipeline steps. These are not exercised
   with GitHub's unsigned CI build.
10. **Only the owner** may decide whether all physical, legal,
    operational and Apple acceptance is complete, and then
    explicitly approve merging each stacked draft into main.
    No CI or ABX output can infer consent.

## 4. Batch roadmap state

- **Batch 1 — Acoustic Reference**: separately tested remotely.
- **Batch 2 — Acoustic Intelligence**: separately tested remotely.
- **Batch 3 — Headphone Completion**: separately tested remotely.
- **Batch 4 — Product Validation**: software acceptance depends
  on its **own exact-head** Release, all XCTest and the generated
  manifest; otherwise pending.
- **Optional research deferred**: adaptive mixed phase PR120,
  personalized binaural PR126, third-party headphone model catalog.
  These cannot block the core app unless they reveal an actual
  reproducible defect in currently supported product behavior.

All batches remain OPEN / draft / unmerged until the owner changes
their status; main is not altered by the remote software validation.
