# PR40 Slice C Status — Measurement Transport Foundation

Current foundation on the PR40 branch:

- deterministic exponential-sine-sweep generation with bounded level, fades, inverse-filter data, Nyquist safety, and exact lead-in/tail frame accounting;
- one named listening position is measured as sequential independent left-speaker and right-speaker passes;
- immutable measurement timeline with explicit inter-pass settling and exact per-pass capture destinations;
- calibration lifecycle state machine independent from ordinary playback state;
- direct-device versus private-aggregate topology planning, including native-rate validation and microphone drift-compensation policy for separate devices;
- fixed-capacity, contiguous single-writer capture buffers allocated before measurement;
- allocation-free sample-domain measurement-session executor that writes isolated stereo excitation and paired microphone captures across arbitrary callback quanta;
- deterministic tests for sweep generation, routing, topology, state transitions, capture contiguity, arbitrary callback boundaries, and post-completion silence.

The next Slice C step is physical Core Audio ownership: create/configure the calibration-only device or private aggregate, install the dedicated measurement IOProc, bind its buffers to the preallocated realtime session, and prove teardown/cancellation returns the physical output cleanly to normal playback.

This transport remains calibration-only. It does not alter the normal process-tap DSP bridge or the deployed room-correction convolution path.
