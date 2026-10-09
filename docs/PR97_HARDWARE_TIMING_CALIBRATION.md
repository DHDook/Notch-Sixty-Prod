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

## Second implementation slice — passive HAL clock acquisition

The new `QuietZoneHardwareHALClockAcquisition` owns the already-existing
PR96 microphone reference transport while taking read-only output callback
timestamp snapshots through an injected physical-route-bound witness. It
converts Core Audio host ticks into common monotonic seconds using
`AudioConvertHostTimeToNanos`, discards repeated output snapshots, records
callback-first input samples only, rejects invalid timestamps, ring overflow,
route/device/rate changes and nonmonotonic clocks, and stops capture on fault.

`QuietZoneHardwareClockAccumulator` bounds memory to 4096 observations
per clock and invokes PR96's independent clock analyzer. A qualified record
may be passed to the PR97 calibration session's `qualifyClock` method;
this is **not** measurement of ADC/DAC round trip or sound arrival. The
output witness must be supplied by the currently running selected-output
transport; no new output stream, probe playback, capture polling timer or
speaker injection is created in this slice. Recorded time series are not
persisted automatically.
