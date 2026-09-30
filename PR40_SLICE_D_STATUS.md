# PR40 Slice D validation checkpoint

Slice D now builds on the green calibration capture transport with offline acoustic analysis, production microphone-calibration ownership, and a durable multi-position project layer associated with the selected Playback System.

Validated analysis work includes:
- regularized frequency-domain deconvolution of the exact generated ESS program;
- impulse-response recovery and direct-arrival detection;
- bulk-delay-removed transfer-function phase;
- logarithmic magnitude/phase response output using the existing Room Correction persistence models;
- microphone calibration gain application at the analyzer boundary;
- capture peak, noise-floor, SNR, clipping, usable-band and warning metadata;
- deterministic synthetic XCTest coverage for identity, gain/delay, calibration, malformed input, clipping and low SNR;
- generation-safe asynchronous controller publication from `analyzing` to `reviewing`;
- a production Review surface backed by measured Left / Right quality rather than placeholders.

Microphone-calibration production work in this gate includes:
- reuse of the existing calibration parser that normalizes, sorts and deduplicates frequency/gain points;
- log-frequency calibration interpolation retained in the analysis model;
- explicit controller ownership of the active microphone calibration curve;
- sandboxed user-selected read-only file access from Setup;
- production Import and Clear controls with original source filename retention;
- invalidation of the active curve when microphone input identity or input channel changes;
- restore of a persisted project calibration when the selected Playback System project is loaded;
- automatic use of the owned calibration curve by offline analysis;
- persistence of the same active curve with first-position microphone metadata;
- controller tests proving imported-curve ownership/invalidation and proving the owned curve is handed to the analysis operation;
- calibration remains analysis-only and is never inserted into daily playback DSP.

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

After this exact tree is green, Slice D is functionally complete enough to move into Slice E: target library/editor/import, smoothing and correction-range controls, boost/cut safety limits, bounded correction FIR design, and explicit headroom accounting. Final PR40 completion still requires later deployment/polish and the focused real-Mac acoustic acceptance gate.