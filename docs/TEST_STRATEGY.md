# Test Strategy

Testing is split into deterministic automated tests, realtime structural checks, and hardware/manual acceptance.

## Automated
- state-machine transitions
- device-selection policy
- ring-buffer FIFO/bounds behavior
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

## Full-DSP qualification
Once DSP is added, repeat latency/CPU/stability testing at representative rates and worst-case graph configurations, with special attention to FIR/convolution, room correction, and oversampling.
