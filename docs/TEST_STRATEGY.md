# Test Strategy

Testing is split into deterministic automated tests, realtime structural checks, and hardware/manual acceptance.

## Automated
- state-machine transitions
- device-selection policy
- ring-buffer FIFO/bounds behavior
- render-kernel unity transparency at 44.1 / 48 / 96 / 192 / 384 kHz
- immutable graph publication, gain/bypass, and latency contracts
- NaN/Inf containment and denormal handling
- gain/filter math reference vectors
- parameter validation
- latency accounting
- serialization/preset migrations
- DSP bypass equivalence where applicable

## Realtime structural checks
- zero allocations during render
- no blocking locks in render path
- no UI/application-state access from render
- bounded callback work
- one immutable DSP graph generation per hardware render buffer
- realtime graph acquisition is bounded and never waits
- graph publication occurs only on the serialized control plane
- diagnostics counters remain lock-free

## Hardware/manual regression matrix
At minimum validate:
- 44.1, 48, 96 kHz
- 176.4 / 192 / 352.8 / 384 kHz when hardware exposes them
- cold start at high rate
- live nominal-rate changes
- selected USB DAC unplug/replug
- default-output changes while explicit output remains selected
- sleep/wake
- permission revoke/regrant behavior
- Stop/Start cycles
- normal Quit with graceful fade/teardown
- force-quit recovery
- long-running playback
- built-in output

## POC baseline already established
The separate POC demonstrated, on Mac16,10 + Schiit Modi 5:
- stable native transport through 384 kHz
- more than two hours steady at 384 kHz with zero active-stream underruns/overruns
- live rate rebuilds
- selected-output persistence
- USB reconnect recovery
- sleep/wake continuity
- permission transition recovery
- failure-safe force-quit restoration

Production regression testing must re-establish these behaviors in this codebase rather than assuming the POC result transfers automatically.

## DSP-kernel foundation gate
After inserting or materially changing the realtime kernel, run a short unity hardware regression before adding substantive DSP. At 384 kHz on the validated Modi 5 path, verify:

- DSP graph sample rate equals output rate
- graph latency reports 0 frames for the unity/reference graph
- non-finite sanitation, denormal flush, and snapshot-read-miss counters remain 0 for normal program material
- steady-state transport underrun/overrun counters remain 0
- bridge queue remains around the validated one-to-two-buffer range
- audio is subjectively unchanged from the transport-only unity path

## Full-DSP qualification
Once substantive DSP is added, repeat latency/CPU/stability testing at representative rates and worst-case graph configurations, with special attention to FIR/convolution, room correction, and oversampling.
