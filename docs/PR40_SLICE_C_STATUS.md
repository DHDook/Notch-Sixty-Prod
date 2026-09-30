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
- atomic transport progress/completion is polled from the control plane; raw paired captures are materialized only after the dedicated IOProc timeline is complete and stopped;
- the production Room Correction workspace now exposes permission, microphone/input-channel selection, sweep duration/level, explicit playback-idle ownership, live measurement progress, cancellation, and paired raw-capture completion;
- analysis/target/design controls are intentionally not simulated in Slice C; completed captures are handed to the next analysis stage;
- deterministic C-bridge tests cover exact left/right routing, arbitrary callback quanta, capture boundaries, reset behavior, post-completion silence, and frame-count overflow rejection;
- deterministic Swift tests cover sweep generation, routing, topology, state transitions, capture contiguity, arbitrary callback boundaries, permission behavior, exclusive hardware ownership, atomic completion polling, cancellation, and capture handoff.

The full Slice C software path is integrated into the production target and is under exact-head software/DMG validation. The remaining Slice C acceptance item is the focused real-Mac microphone/output run; capture is not considered hardware-complete until that pass is performed or explicitly waived.

This transport remains calibration-only. It does not alter the normal process-tap DSP bridge or the deployed room-correction convolution path.
