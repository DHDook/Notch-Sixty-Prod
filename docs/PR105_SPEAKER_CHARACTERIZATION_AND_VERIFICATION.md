# PR105 — Guided Speaker Characterization & Verification

Status: **SLICES 1–8 REMOTE SOFTWARE VERIFIED — SLICE 9 CI PENDING — PHYSICAL ACOUSTIC ACCEPTANCE PENDING**

Base: PR104 measurement-driven Speaker Optimization Engine.

## Why this prerequisite exists

The existing Speaker Optimizer listening-position campaign deliberately measures
each whole speaker/subwoofer separately at listener seats. That is excellent for
in-room optimization and system integration, but it still contains room and
placement response.

PR105 adds a SECOND, independently typed evidence domain for whole-speaker
characterization. It is intended to help later logic distinguish response traits
that follow the loudspeaker from effects that vary strongly by listening seat.
This is not an anechoic measurement claim.

## Slice 1 — Geometry-bound whole-speaker characterization foundation

- One movable calibrated microphone.
- Whole loudspeakers only; subwoofers remain listening-position measurements
  because room modes dominate their useful integration evidence.
- The speaker remains in its normal installed position.
- Default mic distance 1.0 m. Accepted geometry 0.75–2.0 m and within ±10°
  of the selected acoustic/tweeter/manufacturer axis.
- Geometry is persisted per acoustic source. Capture position identity is the
  characterization target ID, so near-speaker evidence cannot be mistaken for
  a listening seat.
- Three stationary repeated sweeps per speaker before moving the microphone.
- Qualification reuses PR103's exact repeated-sweep evidence evaluator: SNR,
  clipping, magnitude repeatability, arrival stability, common usable bandwidth
  and inter-repeat phase consistency.
- Characterization may link to a listening-position baseline, but pairing
  requires the same playback system, route, microphone/calibration and sample
  rate.
- Separate compact persistence; no raw sweep or impulse buffers are retained.

## Safety and interpretation

A 1 m installed-room sweep is still speaker + nearby boundaries + room. It is
expected to be less seat-dependent than a couch measurement, not a true
free-field or anechoic response.

No filter design consumes this new domain in Slice 1. No playback DSP,
crossover, polarity, delay or limiter is modified.

Protected Low/Mid/High driver buses remain blocked. We characterize the whole
speaker only through an already safe acoustic-source route.

## Slice 2 — Bounded early-window characterization

- Derives an additional response from the in-memory deconvolved impulse before
  compact persistence discards raw capture and impulse buffers.
- Default gate keeps 0.75 ms before the direct-arrival peak and 6.0 ms after it,
  with a 1.5 ms raised-cosine tail.
- The gate is an explicit analysis assumption; PR105 does not claim to detect
  the first room reflection or produce a true anechoic/free-field response.
- The trusted low-frequency boundary is derived from gate duration. The default
  requires two complete periods inside the 6 ms post-arrival window (~333 Hz)
  and then snaps to the actual analyzed frequency grid.
- The result is magnitude-only. Windowed phase is discarded so it cannot enter
  crossover, polarity or synchronized timing decisions.
- The same microphone calibration curve is explicitly reapplied to the gated
  impulse-derived magnitude, and the characterization microphone calibration
  identity is retained in the compact evidence.
- A late reflection outside the gate is rejected from the derived magnitude in
  deterministic tests; frequencies below the gate-derived boundary continue to
  rely on the ordinary listening-position campaign.
- Compact characterization persistence stores only the derived frequency
  response and audit metadata, never the raw sweep or impulse response.

## Slice 2 exact-head verification

Slice 2 code at `3052415b759b86f483b36e90651d9659add380cf` passed both
GitHub Actions paths:

- push run 38204073457;
- pull-request run 38204076224.

Both runs passed the PR105/PR104/PR103 contract validators, Apple Silicon Debug
build, targeted Speaker Optimizer characterization tests, and full XCTest
regression. This documentation-only checkpoint creates a subsequent head that
must pass the same workflow before it is treated as the final verified Slice 2
handoff.

Physical microphone distance, loudspeaker integration distance, actual room
reflection timing and acoustic benefit remain unverified.

## Slice 3 — Cross-domain speaker-vs-room classification

- Requires BOTH the ordinary listening-position baseline and the separately
  qualified characterization campaign to pass their existing evidence gates.
- Compares local response SHAPE rather than absolute dB. A ~1 m capture and a
  listening-seat capture have different propagation gain, so direct absolute
  level subtraction would be invalid.
- Each domain is reduced to residual response around a 1/3-octave
  log-frequency-smoothed local trend.
- A feature is `speakerPersistent` only when a significant near-speaker
  deviation appears in the same direction and magnitude at the listening
  positions with low seat-to-seat spread.
- A feature is `roomSeatDependent` when characterization is locally
  flat but the listening area has a strong deviation or strong seat variation.
- Disagreement or insufficiently decisive evidence remains `ambiguous`.
- Flat regions are explicitly `noMaterialDeviation`; the classifier does
  not manufacture a speaker defect merely because two data sets exist.
- Classification is constrained to the early-window reliable frequency band.
  Frequencies below that boundary remain listening-position evidence only.
- Classification is preview/advisory evidence: `canDeploy == false`. It
  never authorizes PEQ/FIR, timing, polarity, crossover or live DSP mutation.

## Slice 4 — Classification-aware PEQ/FIR correction authority

- PR105's guided path recomputes cross-domain classification from the qualified
  characterization and listening-position measurement sets. It does not accept
  an externally supplied correction-authority map.
- Only `speakerPersistent` points become eligible to drive speaker-correction
  synthesis.
- `roomSeatDependent`, `ambiguous`, `noMaterialDeviation`, frequencies below
  the early-window trust boundary, and missing classification points are
  protected by default.
- The desired PEQ/FIR correction is zeroed at protected points BEFORE fitting or
  FIR synthesis. This prevents a ranking penalty from merely hiding a candidate
  that still alters a room-specific feature.
- PEQ band centers must lie on authorized points, and the actual cumulative
  biquad response may leak no more than 0.5 dB into protected measured points.
- FIR synthesis receives the same masked desired response. The actual Float-tap
  forward response is rejected if it exceeds the same protected-region leakage
  bound.
- The generic PR104 preview designers retain their original unmasked behavior
  for regression compatibility; PR105's guided Speaker Optimizer route uses the
  stricter classification-aware wrapper.
- Both products remain preview-only and non-deployable. This slice grants
  correction evidence authority, not permission to mutate live DSP.

## Slice 5 — Guided Speaker Calibration workflow

- Adds a dedicated characterization controller under SYSTEM → Speaker
  Calibration while reusing the existing safe targeted-output transport.
- The guided order is Listening Baseline → Speaker Characterization → Compare
  Evidence. Characterization cannot start until the paired listening baseline
  is optimizer-ready.
- Whole speakers only are characterized; subwoofers stay in the listening-area
  integration campaign.
- The UI presents the ~1 m installed-speaker placement instruction and completes
  all three stationary repeats before moving to the next speaker.
- After deconvolution, the controller derives the early-window magnitude from
  the in-memory impulse before compact persistence drops raw/impulse buffers.
- Progress, evidence confidence and early-window completeness are visible.
- Once both campaigns qualify, the UI shows per-source speaker-persistent and
  room/seat-dependent percentages plus ambiguous counts.
- The screen explicitly states that only speaker-persistent regions may feed the
  guided speaker-correction path.
- Speaker Optimizer controller failures are now included in the shared visible
  calibration error banner.
- No Apply control is added in this slice; classification-aware candidates
  remain preview-only.

## Slice 6 — Commissioning contract, explicit approval & rollback snapshot

- Converts a classification-aware PEQ or FIR preview into an immutable
  commissioning proposal bound to the exact baseline, characterization,
  Playback System, routing signature and sample rate.
- Captures the complete `PlaybackSystemState` as the rollback snapshot before any
  future live mutation.
- Creates deterministic stale-candidate fingerprints for selected PEQ
  coefficients or accepted FIR taps.
- Explicit approval is a separate, user-initiated object bound to the proposal
  ID and exact aggregate candidate fingerprint. Approval cannot be silently
  minted or reused after candidate changes.
- Approval is necessary but NOT sufficient to Apply.
- Existing `SemanticSpeakerCalibration.eqBands` remain owned by ordinary Speaker
  Calibration; PR105 refuses to append/replace them as an optimizer shortcut.
- The current Playback System model also has no dedicated per-speaker optimizer
  FIR stage. FIR deployment therefore remains blocked.
- Both deployment-stage states are represented explicitly and `canApply` remains
  false until a separately owned optimizer stage is implemented and audited.
- No ProductProfileController, AudioIOEngine, crossover, limiter, room
  correction or persisted system state is mutated by this slice.

## Slice 7 — Separately owned live PEQ deployment substrate

- Adds an optional `speakerOptimizerPEQ` object to the Output Device Profile.
  It is persisted separately from `SemanticSpeakerCalibration`, so optimizer Apply
  never replaces or silently edits ordinary Speaker Calibration trim, delay,
  polarity or EQ ownership.
- Deployment metadata remains bound to the approved proposal, baseline,
  characterization set, routing signature, sample rate and aggregate candidate
  fingerprint.
- The first live optimizer stage is intentionally PEQ-only and cut-only.
  Whole-speaker roles only are accepted; LFE/subwoofer optimizer deployment is
  not introduced by this slice.
- Each semantic realtime lane already owns a bounded 16-section biquad cascade.
  The compiler installs ordinary Speaker Calibration sections first, then
  appends separately owned Speaker Optimizer sections.
- Aggregate Speaker Calibration + Speaker Optimizer section count is validated
  against the 16-section realtime ceiling before activation.
- The measurement routing signature deliberately excludes optimizer coefficients,
  just as it excludes ordinary deployed calibration, so applying a correction
  does not rewrite the identity of the physical topology that was measured.
- A qualified cut-only PEQ commissioning proposal can now report its dedicated
  stage as available. Explicit approval can produce a deployment configuration,
  but this slice still does NOT mutate the selected Playback System.
- FIR remains blocked pending a dedicated per-speaker FIR/latency stage.

## Slice 8 — Transactional PEQ Apply & rollback

- Adds the first live Speaker Optimizer mutation path, restricted to the
  separately owned cut-only PEQ stage introduced in Slice 7.
- Apply requires the engine to be idle because Output Device Profile changes
  require a live N-channel restart boundary.
- The exact complete Playback System state captured in the commissioning
  proposal is used as an optimistic-concurrency snapshot. Any state drift after
  review blocks Apply and requires regeneration/review.
- Explicit user approval is revalidated against the exact proposal and aggregate
  candidate fingerprint immediately before mutation.
- Only `outputDeviceProfile.speakerOptimizerPEQ` is changed. Ordinary Speaker
  Calibration trim/delay/polarity/EQ ownership is preserved.
- Production mutation goes through
  `ProductProfileController.replaceSelectedSystemOutputDeviceProfile`, which
  atomically coordinates live engine state and persisted Playback System state.
- The transaction verifies the full expected Playback System state after the
  write and returns an immutable Apply receipt bound to proposal/baseline/
  characterization/routing/candidate identities.
- Every Apply receipt remains `requiresMeasuredVerification == true`; installing
  coefficients is not acoustic verification.
- Rollback requires the engine to be idle and the current full Playback System
  state to exactly match the expected post-Apply state. If any unrelated edit
  occurred after Apply, rollback fails closed rather than overwriting it.
- Successful rollback restores the exact pre-Apply Output Device Profile and
  verifies the full Playback System against the captured commissioning snapshot.
- FIR Apply remains blocked; Slice 8 does not add a per-speaker FIR stage.

## Slice 9 — Independent measured post-Apply verification

- Requires a new `.verification` measurement set captured after the Apply
  receipt. Baseline captures cannot be reused as verification.
- Baseline and verification must have identical Playback System, routing,
  calibrated microphone identity, sample rate, listening positions and planned
  acoustic sources.
- Both campaigns independently re-run the PR103 repeated-sweep SNR, clipping,
  magnitude-repeatability, timing and phase-consistency gates.
- The Apply receipt is revalidated against the exact deployed PEQ metadata and
  classification-aware candidate identity before acoustic scoring.
- For each deployed whole speaker, the verifier reconstructs the actual digital
  PEQ response and compares it with the measured verification-minus-baseline
  acoustic delta.
- A single constant dB level offset may be fitted out of that DELTA so minor
  measurement-level drift cannot create a false failure. Spectral shape is not
  normalized away.
- Speaker-persistent regions must show measured local spectral-error
  improvement, with a per-seat regression guard.
- Room/seat-dependent, ambiguous and otherwise protected regions have a
  separate regression guard.
- A deployment is accepted only if every deployed source clears filter tracking,
  persistent improvement, seat regression and protected-region checks.
- Failed measured acceptance sets `shouldRollback == true`; modeled
  improvement alone can never finalize the deployment.
- This slice produces the independent acceptance report. Automatic rollback/UI
  orchestration comes next.

## Planned follow-on slices

1. Add provisional Apply/rollback UI review plus a guided post-Apply
   verification capture controller.
2. Automatically invoke guarded rollback when fresh measured acceptance fails,
   while preserving the existing no-overwrite-on-state-drift rule.
3. Persist a verified deployment status only after the independent acceptance
   report passes.
4. Add synchronized reference capture before any crossover timing/polarity
   deployment; saved PR103 v1 evidence remains insufficient for that action.
5. Keep FIR deployment blocked until a separately owned per-speaker FIR stage
   coordinates latency/headroom across channels and video paths.

Physical testing remains required for actual mic-distance guidance, integration
distance for unusual loudspeakers, reflection-window limits and safe/beneficial
correction.
