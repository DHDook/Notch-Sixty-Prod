# PR40 Slice D validation checkpoint

Slice D now builds on the green calibration capture transport with offline acoustic analysis plus the first durable multi-position project layer.

Validated analysis work includes:
- regularized frequency-domain deconvolution of the exact generated ESS program;
- impulse-response recovery and direct-arrival detection;
- bulk-delay-removed transfer-function phase;
- logarithmic magnitude/phase response output using the existing Room Correction persistence models;
- optional microphone calibration gain application;
- capture peak, noise-floor, SNR, clipping, usable-band and warning metadata;
- deterministic synthetic XCTest coverage for identity, gain/delay, calibration, malformed input, clipping and low SNR;
- generation-safe asynchronous controller publication from `analyzing` to `reviewing`;
- a production Review surface backed by measured Left / Right quality rather than placeholders.

Multi-position/project work in this gate includes:
- sidecar projects associated with the authoritative selected Playback System UUID;
- default Center / Left / Right naming while allowing additional positions;
- retained raw capture, IR, transfer-function and quality data per position;
- explicit inclusion and non-negative position weighting;
- normalized weighted magnitude averaging in the dB domain;
- no spatial phase averaging across unrelated seats;
- aggregate removal when every included position has zero weight or all positions are excluded;
- atomic project persistence before in-memory publication;
- transactional rejection of incompatible sample rates, sweep settings, microphone identity/calibration, or frequency grids;
- deterministic tests for reload, rename, exclusion, weighting, raw-data retention and duplicate-capture prevention.

The next Slice D step after this gate is green is product/UI ownership integration: retaining a reviewed measurement into the selected Playback System project and exposing position naming, inclusion and weight controls. Target/design work remains Slice E.
