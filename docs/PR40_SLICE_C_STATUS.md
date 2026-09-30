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
- the separate-device aggregate explicitly uses the selected physical output as both main subdevice and clock device, with drift compensation enabled only for the microphone subdevice;
- transport setup verifies the live output nominal rate, applied aggregate rate, and input/output stream sample rates so calibration remains native-rate and does not silently introduce SRC;
- the App Sandbox audio-input entitlement and a dedicated microphone privacy usage description are present for the AVFoundation measurement-microphone permission path;
- a MainActor calibration controller owns the user-initiated microphone permission flow, input selection, sweep settings, calibration state, and measurement-transport lifetime;
- calibration hardware ownership is permitted only while the ordinary `AudioIOEngine` is exactly `idle`; the controller never silently stops or resumes normal DSP playback;
- raw paired captures are handed from the calibration controller to the subsequent analysis stage only after the dedicated transport has stopped and materialized its bounded capture buffers;
- deterministic C-bridge tests cover exact left/right routing, arbitrary callback quanta, capture boundaries, reset behavior, post-completion silence, and frame-count overflow rejection;
- deterministic Swift tests cover sweep generation, routing, topology, state transitions, capture contiguity, arbitrary callback boundaries, permission behavior, exclusive hardware ownership, cancellation, and capture handoff.

The physical transport and calibration controller are compiled into the production target. Remaining Slice C work after exact-head software/DMG validation is production Setup/Measure UI integration and the focused real-Mac microphone/output acceptance path before treating capture as complete.

This transport remains calibration-only. It does not alter the normal process-tap DSP bridge or the deployed room-correction convolution path.
