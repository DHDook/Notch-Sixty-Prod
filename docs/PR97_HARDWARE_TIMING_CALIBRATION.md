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

## Third implementation slice — bind the running stereo output

The application now offers an internal `AudioIOEngine.makeHardwareClockAcquisition`
factory. It selects PR97's existing microphone HAL reference input while
holding a weak read-only witness to the **exact** current running stereo
output session. The output session issues a fresh random route lease on each
reconstruction; selected device UID, Core Audio device ID, native output rate,
active stereo transport identity, real output callbacks and the absence of
aggregate/multi-device routing are independently required. A new session,
recovery, device change, sample-rate change or loss of output callbacks
revokes the capture on its next poll. The binding never opens or controls
a second speaker output and cannot arm anti-noise.

The host application currently exposes this as an internal control-plane
entry point only. A user-driven measurement wizard, controlled physical
source trigger, speaker-to-seat impulse timing, physical ADC/DAC deadline
qualification and instrumented acoustic verification remain outstanding.

## Fourth implementation slice — instrumented external-source probe capture

`QuietZoneInstrumentedProbeCollector` accepts PR96 microphone HAL frame
records in sample-contiguous order, converts observed Core Audio callback
host-time ticks into a common timebase and rejects clipping, unbounded
capture length, skipped frames, timebase errors and missing pre-trigger audio.
A separate **physically calibrated external source** must supply a witnessed
acoustic-emission host timestamp, calibrated uncertainty, fixture/clock/route
identity, independent launch ID and known probe waveform. App button presses,
queued output writes and unsynchronized phone playback cannot substitute.
The collector returns a real `QuietZoneFeedForwardProbeCapture`, suitable
for the existing matched-filter detector and three-position survey.

A microphone-only `QuietZoneInstrumentedProbeAcquisition` adapter starts,
polls and stops the existing PR96 reference transport with exact route-lease
checks; it does not itself trigger any loudspeaker. Input waveforms remain
in temporary memory, not saved alongside the calibration. Synthetic tests
exercise valid arrivals, broken clocks, missing preroll, timestamp gaps and
clipped recordings. A hardware source trigger driver and physical timing
attestation are **not yet implemented**. Do not report a physically verified
latency or arm ANC based on simulated source-trigger certificates.

The fourth slice also exposes `addInstrumentedSourceCapture` on the
calibration session: three accepted positions must have distinct physical
launch IDs, one physical source identity, one source fixture, and matching
probe waveform/route/clock evidence. Replayed launches and swapped sources
fail before survey advancement; listener-return drift invalidates launch
history along with the survey. This is diagnostic evidence only, not a
cryptographically attested hardware launch source or an ANC arm permit.

The audio engine now exposes an internal
`makeInstrumentedSourceProbeAcquisition` factory using exactly the active
stereo output route and weak session-bound provenance, reusing the microphone
input-only HAL ring. It does not provide an autonomous calibrated source
actuator or user wizard. The source emission witness must come from separately
instrumented hardware and remains unverified until real-Mac commissioning.


## Fifth implementation slice — decomposed physical latency and causal reserve

The PR97 \`QuietZonePhysicalLatencyBudgetAnalyzer\` requires **four separately
instrumented** timing stages on the current microphone/DAC clock and route:

1. microphone ADC and reference acquisition
2. reference processing, buffering and scheduling
3. command-to-DAC and output latency
4. speaker electroacoustics and physical travel to listening seat

Each stage requires at least three unique captured hardware events, a nonzero
median, a measured upper bound, worst-case jitter, measured clock uncertainty,
and freshness inside the same calibration session. Duplicate/missing stages,
synthetic/estimated values, stale/replayed captures, mismatched routes or
sample rates, impossible bounds and invalid clocks are rejected.

The conservative calculation is:

\`\`\`
noise lead lower bound = measured listener-vs-upstream difference
                        - 3σ arrival timing uncertainty - listener return drift/2

nominal response path = ADC + processing + DAC/output + speaker-to-seat
response upper bound = nominal path
                     + sum(stage upper-bound excesses)
                     + sum(worst-case jitter)
                     + 3 × sum(stage timing uncertainty)

causality reserve = noise lead lower bound - response upper bound
remaining safety reserve = causality reserve - PR96 required 2 ms
\`\`\`

The final readiness decision is deliberately delegated to the PR96
\`QuietZoneFeedForwardBudgetAnalyzer\`; no new permissive ANC arm criterion is
introduced. Electrical cable-loopback delay is **not decomposed** into ADC or
DAC time and cannot replace acoustic speaker-to-seat measurements.
\`QuietZoneHardwareCalibrationSession.evaluatePhysicalLatency\` exposes the
new detailed diagnostic only after the full guided evidence sequence.
The existing Quiet Zone view shows the known path, uncertainty and jitter
breakdown, explicitly marking it diagnostic rather than an active control.

A positive timing bound only establishes **causal timing plausibility**.
Frequency-dependent coherence, secondary-path response, attenuation and
closed-loop stability are not inferred and remain unverified. CI fixtures
exercise arithmetic and fail-closed validation; a software-provided
\`instrumentedHardware\` label is not trusted physical hardware attestation.
The actual timing-stage acquisition/verification and live control are still
gated on real equipment and separate PR98/PR99 acceptance.


## Sixth implementation slice — repeated physical timestamp witness workflow

PR97 now has a bounded, in-memory \`QuietZonePhysicalLatencyMeasurementRun\`.
The separate instrument must supply synchronized start/end host timestamps
for each stage, corrected for *independently measured* endpoint instrumentation
latency. Four distinct witness methods are required:

- acoustic reference sound → upstream microphone ADC-ready
- ADC-ready → real anti-noise DSP command
- real anti-noise command → analog DAC output
- analog speaker output → listener-seat microphone arrival (subtracting the
  listener measurement microphone's separately calibrated ADC delay)

At least three nonoverlapping capture events per method are mandatory.
Each must share the exact measurement rig, clock identity, DAC session lease,
valid cross-clock witness, and separately verified endpoint correction.
Replayed/out-of-order event IDs, overlapping sample timelines, invalid
uncertainty, negative corrected latency, expired data and estimates fail
closed. Data collection is capped at 20 repetitions per stage.

For each stage, the collector computes a robust observed median and the
maximum independently measured corrected latency. It keeps the worst measured
jitter and the conservative additive uncertainty of start clock, endpoint
clock and correction, then hands the four typed results to the existing
physical timing-budget analyzer. The new
\`QuietZoneHardwareCalibrationSession.evaluateInstrumentedLatencyRun\`
requires the same session and prior completed clock/loopback/A-B-A sequence.

This is a **control-plane data contract and analysis**, not a live hardware
instrument: software Boolean claims about a witness cannot independently
prove ADC/DAC or acoustic timing, and a test fixture cannot commission the
hardware. Until the actual Mac/measurement chain supplies physical witnesses
and the results pass separate acceptance, no live ANC can arm. There is no
Core Audio callback modification or autonomous output/playback.


## Seventh implementation slice — commissioning preflight and acceptance blockers

The read-only \`QuietZoneHardwareCommissioningEvaluator\` generates eleven
commissioning gates with statuses: missing, recorded but not independently
verified, invalid/recapture, or physical verification required. They cover
the **exact running output lease**, concurrent HAL clocks, independent
electrical loopbacks, the A/B/A single-microphone source survey, four
separate timing stages, conservative causality, independent instrumentation
review, and physical cancellation/stability acceptance.

\`preview(calibration:)\` reads the saved PR96 plan conservatively. A saved
\`timingPath\` cannot prove ADC, DAC, electrical loopback or physical seat
propagation. The Quiet Zone UI displays this checklist without a live arm
control or a claim that its preview represents an active capture session.

\`assess(session:run:currentOutput:plan:project:now:)\` examines the exact
in-memory route lease, capture age, input/output clock evidence, electrical
loopback evidence, A/B/A order and repeated physical endpoint events.
When a complete staged measurement run and actual measurement project exist,
it delegates to the existing PR97 four-stage physical analyzer and records
the conservative budget as **diagnostic only**. Old, mismatched or
invalid evidence becomes invalid rather than silently qualifying.

**Independent hardware attestation remains unimplemented.** A caller-provided
\`origin = instrumentedHardware\` or \`clockCalibrationVerified = true\` is
not proof that a calibrated physical source produced the measurement.
The independent hardware review and actual measured acoustic
attenuation/stability gates therefore remain blocked even when all
synthetic fixtures pass. Runtime authorization, output wiring, persistence,
and the realtime callback are unchanged.
