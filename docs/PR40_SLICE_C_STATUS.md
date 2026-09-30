# PR40 Slice C Status — Measurement Transport Foundation

Current foundation on the PR40 branch:

- deterministic exponential-sine-sweep generation with bounded level, fades, inverse-filter data, Nyquist safety, and exact lead-in/tail frame accounting;
- one named listening position is measured as sequential independent left-speaker and right-speaker passes;
- immutable measurement timeline with explicit inter-pass settling and exact per-pass capture destinations;
- calibration lifecycle state machine independent from ordinary playback state;
- direct-device versus private-aggregate topology planning, including native-rate validation and microphone drift-compensation policy for separate devices;
- fixed-capacity, contiguous single-writer capture buffers allocated before measurement;
- allocation-free sample-domain measurement-session executor that writes isolated stereo excitation and paired microphone captures across arbitrary callback quanta;
- a dedicated C realtime measurement bridge with copied sweep storage, fixed paired capture buffers, atomic completion diagnostics, explicit microphone-channel selection, and auxiliary-output silence;
- a separate calibration-only Core Audio transport that owns either the selected full-duplex device or a private output-led aggregate, installs one full-duplex measurement IOProc, restores temporary microphone sample-rate changes, and tears down without touching the normal process-tap DSP bridge;
- deterministic C-bridge tests for exact left/right routing, arbitrary callback quanta, capture boundaries, reset behavior, post-completion silence, and frame-count overflow rejection;
- deterministic Swift tests for sweep generation, routing, topology, state transitions, capture contiguity, arbitrary callback boundaries, and post-completion silence.

The physical transport is now compiled into the production target for CI validation. Remaining Slice C work is to resolve any build/test findings, add calibration-session coordination around ordinary playback exclusivity and permission/input selection, then run the focused real-Mac microphone/output acceptance path before treating capture as complete.

This transport remains calibration-only. It does not alter the normal process-tap DSP bridge or the deployed room-correction convolution path.
