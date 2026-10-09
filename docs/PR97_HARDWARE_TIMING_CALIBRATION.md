# PR97 — Instrumented Hardware Timing Calibration

## Scope of the first implementation slice

PR97 assembles real, clock-qualified measurement evidence in a fail-closed
sequence: concurrent input/output HAL clock qualification, at least three
independent wired electrical loopbacks within those observed clocks, and a
single-microphone listener / upstream / listener-return controlled-source
survey. Strict route, clock, sample-rate and project identity checks prevent
accidental reuse; return-position drift invalidates the whole acoustic survey.

QuietZoneHardwareCalibrationSession is an offline control-plane assembler
built on PR96's independently validated analyzers. It accepts separately
instrumented audio and timestamps; it does not itself activate a microphone
or DAC. Its typed diagnostic receipt is never an ANC live-arm permit.

## Outstanding hardware engineering

- The hardware capture/launch driver does not yet automate sampling.
- True shared source launch/ADC/DAC timestamps must be gathered on the Mac.
- Electrical round-trip delay cannot be substituted for speaker-to-listener
  acoustic latency or reference-to-speaker render deadlines.
- Calibrate microphone/speaker secondary paths, verify headroom, and measure
  actual noise attenuation at the virtual listening seat.
- Live anti-noise output remains disconnected and cannot arm.

## Validation

Dedicated PR97 structural CI, deterministic XCTest sequencing and failure
cases, arm64 macOS build, full XCTest suite, and PR96–PR90 inherited guards.

## Safety

No callback modifications, external dependencies, automatic playback,
persistence changes or creation of fake physical measurement evidence.
