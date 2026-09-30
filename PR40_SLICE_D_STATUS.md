# PR40 Slice D validation checkpoint

Slice D now builds on the green calibration capture transport with offline acoustic analysis plus a durable multi-position project layer associated with the selected Playback System.

Validated analysis work includes:
- regularized frequency-domain deconvolution of the exact generated ESS program;
- impulse-response recovery and direct-arrival detection;
- bulk-delay-removed transfer-function phase;
- logarithmic magnitude/phase response output using the existing Room Correction persistence models;
- optional microphone calibration gain application at the analyzer boundary;
- capture peak, noise-floor, SNR, clipping, usable-band and warning metadata;
- deterministic synthetic XCTest coverage for identity, gain/delay, calibration, malformed input, clipping and low SNR;
- generation-safe asynchronous controller publication from `analyzing` to `reviewing`;
- a production Review surface backed by measured Left / Right quality rather than placeholders.

Multi-position/project work in this gate includes:
- sidecar projects associated with the authoritative selected Playback System UUID;
- ProductController ownership of the active room-correction project controller;
- project reload when the selected Playback System changes;
- default Center / Left / Right naming while allowing additional positions;
- production retention of a reviewed measurement into the selected Playback System project;
- retained raw capture, IR, transfer-function and quality data per position;
- production rename, explicit include/exclude, and non-negative weight controls;
- normalized weighted magnitude averaging in the dB domain;
- no spatial phase averaging across unrelated seats; per-position phase/timing remain retained;
- aggregate removal when every included position has zero weight or all positions are excluded;
- a deliberate Start New Project recovery path for changing measurement conditions;
- atomic project persistence before in-memory publication;
- transactional rejection of incompatible sample rates, sweep settings, microphone identity/calibration, or frequency grids;
- deterministic tests for reload, rename, exclusion, weighting, raw-data retention and duplicate-capture prevention.

This checkpoint intentionally does not claim the full microphone-calibration Setup contract is complete. The analyzer accepts calibration data and the project model persists it, but production Setup still needs an import/clear owner and must pass that exact active calibration through analysis and first-position retention. That gap must be closed before PR40 is considered complete.

After this named-position tree is green, the next work is to close that microphone-calibration production path, then move to Slice E target/smoothing/range/boost-cut/FIR design and headroom accounting.