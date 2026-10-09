# PR97 — Offline Physical Timing Evidence Protocol (v1)

This is an implementation contract, **not certification that Notch Sixty's
hardware performs active noise cancellation**. Instrument software and the
physical commissioning procedure remain separate engineering milestones.

## Required physical capture setup

- Keep Notch Sixty's selected stereo output transport running on the intended
  speaker DAC. Record its stable UID, **session-specific random lease** and
  native sample rate. A restart, rate change, unplug, or recovery invalidates
  the calibration session.
- Obtain explicit microphone permission. Use a cross-calibrated measurement
  clock for the external source emission witness, upstream mic ADC, DSP
  deadline, actual DAC analog endpoint and listener-position measurement mic.
- Repeat the source at listener → doorway → listener. The **same physical
  source, fixture and common calibrated clock** must be used; each emission
  needs a distinct ID. The return capture must agree within the PR96 drift
  tolerance.
- Record three to twenty independent, nonoverlapping physical start/end
  events for *each* latency stage:
  1. acoustic noise at reference mic → reference ADC-ready
  2. reference ADC-ready → actual anti-noise calculation deadline
  3. anti-noise command → analog DAC output
  4. analog speaker emission → listening-position acoustic arrival
- Correct each endpoint instrument's timing separately, especially the
  listener microphone/ADC used to measure propagation. An electrical cable
  loopback is not a direct measurement of stage 4.
- Capture median, upper delay bounds, jitter and clock uncertainty honestly.
  A Core Audio callback timestamp alone is not a DAC/ADC conversion delay.

## File handoff and signer enrollment

The controlling app issues \`evidenceSessionID\` (a fresh random UUID), an
exact session start date, selected output lease and route identifiers.
The external instrument must use the same session provenance. The caller
enrolls the instrument's Ed25519 **public key**, expected key ID, instrument
ID and calibration-record ID over an independently trusted channel. Do NOT
accept a public key from the same file as proof of identity.

\`QuietZoneEvidenceEnvelope\` consists of:

- \`version = 1\`
- \`signerKeyID\`: must match the separately provisioned key
- \`payload\`: the original, signed JSON UTF-8 bytes (encoded as base64 by
  Foundation's JSON Encoder when placed in the envelope)
- \`signature\`: raw 64-byte Ed25519 signature over exactly \`payload\` bytes

The inner \`QuietZoneEvidencePayload\` includes a v1 schema version, exact
session/project/microphone/output/clock identity, capture and calibration
expiration times, three timed source launches, and 12–80 timestamped endpoint
measurements. Dates are encoded in JSON as **milliseconds since 1970**.
There is no requirement to re-serialize or canonically normalize the signed
payload: its original bytes are verified before decoding.

The verifier accepts only a matching still-running output lease, an enrolled
key and fresh measurements. All event IDs must be distinct (including source
launches versus endpoint records). Existing conservative timing analyzers
still enforce segment bounds and required repetition counts. Acceptance is
atomic: failed verification must not consume a replay nonce.

## Explicitly missing

The current implementation does **not** include an external instrument
driver, key-enrollment UI, hardware-bound key provisioning/attestation,
independent clock provenance, durable anti-replay ledger, stored trusted
calibration receipts, live DSP anti-noise output, or acoustic attenuation and
stability qualification. An Ed25519 signature authenticates only key
possession and file integrity; it cannot prove physical source honesty.
The inspection result is always diagnostic and cannot arm ANC.

No GPL-derived source, privileged component, extra driver, network
dependency or playback modification is used in this interface.
