# PR40 Room Correction — Stereo Measurement Transport Architecture

## Decision

Room Correction measurement uses a **dedicated calibration transport**, separate from the normal system-audio `CoreAudioTransportSession` and its realtime DSP bridge.

Each named listening position records **two sequential acoustic measurements**:

1. left speaker excited, right output silent;
2. right speaker excited, left output silent.

The microphone capture for each sweep is retained independently. A position is therefore a paired L/R acoustic measurement, not one combined stereo response.

This is required to preserve information needed by the existing stereo room-correction FIR runtime, which can deploy independent left and right correction taps.

## Why not a simultaneous stereo sweep?

Playing the same sweep through both speakers and recording one microphone response measures the acoustic sum of both loudspeakers. Once summed in air, their individual transfer functions cannot be recovered reliably from that one capture.

That would prevent robust independent L/R correction and could turn seat-dependent inter-speaker interference into false correction targets.

The first production workflow therefore measures speakers sequentially. A future orthogonal/MIMO excitation scheme may be evaluated separately, but it is not required for PR40.

## Why not inject calibration into the normal DSP render callback?

Normal playback currently owns:

- the system-audio process tap;
- the physical-output IOProc;
- the preallocated realtime bridge;
- DSP graph publication and transitions;
- output startup/shutdown ramps;
- analysis demand/capture.

Room measurement has different requirements:

- known excitation rather than arbitrary program audio;
- microphone input rather than the system-audio process tap;
- deterministic capture start/stop boundaries;
- independent left/right speaker excitation;
- raw capture preservation;
- no content DSP, presets, metering, or process-tap dependency.

Adding sweep injection and microphone capture to the ordinary bridge would permanently increase complexity in the shipping realtime path for a workflow used only during calibration.

PR40 instead keeps measurement transport isolated. Normal playback remains unchanged when calibration is inactive.

## Calibration ownership / exclusivity

A measurement run requires the normal DSP transport to be **idle** before the calibration transport takes ownership of the selected physical output.

Setup, project editing, target editing, response review, and filter design do not require measurement transport ownership and must not interrupt ordinary playback.

Only the short Measure stage takes exclusive audio-I/O ownership.

On completion, cancellation, or failure, the calibration transport releases all aggregate-device / IOProc resources and returns to the idle calibration state. The user can then resume ordinary playback.

This avoids competing output IOProcs and gives measurement a single deterministic I/O owner.

## Core Audio topology

### Same physical device provides output and measurement input

When the chosen input and output resolve to the same Core Audio device, calibration may use that device directly where its stream topology exposes the required input and stereo output scopes.

### Separate measurement microphone and output device

When input and output are different Core Audio devices, create a **private aggregate device** containing:

- selected physical output as the main/clock-leading subdevice;
- selected microphone input as a second subdevice;
- drift compensation enabled for the microphone subdevice when it is not the clock leader.

The aggregate is calibration-session-only and is destroyed during teardown.

Use one aggregate-device IOProc for the measurement cycle. The IOProc receives device input for microphone capture and supplies device output for the current I/O cycle, preserving a common transport timeline.

Do not create a permanent aggregate device in Audio MIDI Setup and do not change the user's system default input/output devices.

## Format contract

Before arming a measurement:

- output must expose at least two output channels;
- microphone device must expose at least one input channel;
- aggregate/device sample rate must equal the selected measurement sample rate;
- sweep end frequency must remain below Nyquist with an explicit safety margin;
- buffer frame size is read from the active calibration device and treated as runtime state;
- no implicit sample-rate conversion is allowed in the first PR40 implementation.

If input hardware cannot operate at the selected output/sample rate through the aggregate, Setup must fail clearly rather than silently resampling.

## Channel contract

The first production implementation captures one selected microphone input channel and excites the physical stereo output sequentially:

```text
left sweep  -> output L = ESS, output R = 0 -> capture microphone
right sweep -> output L = 0,   output R = ESS -> capture microphone
```

A bounded silence/settling interval separates the sweeps.

The selected microphone channel is explicit project metadata so multi-channel interfaces do not silently choose an input.

## Sweep ownership

Sweep samples are synthesized completely on the control/worker plane before measurement starts.

The realtime callback receives only:

- immutable/preallocated sweep sample storage;
- atomic/bounded session state;
- preallocated capture storage;
- sample/frame indices.

The callback performs no:

- allocation/free;
- locks;
- logging;
- file access;
- UI work;
- FFT/deconvolution;
- filter design.

## Capture boundaries

Each channel capture contains enough data for:

1. pre-sweep noise estimate / lead-in;
2. complete excitation;
3. room-decay tail.

The callback records exactly the bounded capture capacity prepared before start. It never grows an Array or reallocates during I/O.

The completed raw capture is copied/materialized to ordinary Swift-owned project memory only after the IOProc has stopped writing that measurement buffer.

## Measurement identity

A named position owns:

- stable position UUID;
- user-facing position name;
- inclusion flag and spatial weight;
- sample rate;
- left-speaker channel measurement;
- right-speaker channel measurement.

Each channel measurement owns independently:

- capture timestamp;
- raw microphone capture;
- deconvolved impulse response;
- transfer-function magnitude/phase;
- quality/confidence metrics;
- arrival/timing information;
- usable-frequency estimate.

This keeps one spatial weight per seat while retaining the independent L/R acoustic paths required for stereo correction.

## Multi-position aggregation

Aggregate left responses only with left responses, and right only with right.

For correction-target magnitude aggregation:

- normalize included seat weights;
- average magnitudes in log/dB space;
- never complex-average unrelated seat phases;
- retain each seat's phase and timing independently for diagnostics and any later validated phase workflow.

The aggregate project state therefore contains separate left and right response curves.

## Correction design consequence

The first production correction designer should normally generate a stereo filter:

- left correction taps derived from the weighted left response;
- right correction taps derived from the weighted right response;
- shared target/range/safety policy unless a later UI intentionally exposes per-channel targets.

Both sides must obey the same declared-latency contract so the correction stage cannot introduce unintended inter-channel timing skew.

## Failure / teardown invariants

Cancellation or failure at any point must:

- stop the calibration IOProc if started;
- destroy its IOProc ID;
- destroy the private aggregate device if created;
- release preallocated sweep/capture memory;
- leave the selected Playback System's currently deployed correction FIR untouched;
- leave normal system-audio DSP configuration untouched;
- surface a recoverable calibration error.

A failed measurement never partially deploys a correction filter.

## Initial deterministic tests

Before real microphone acceptance, software tests should cover:

- calibration transport state-machine legality;
- same-device vs aggregate topology selection;
- subdevice description construction and drift-compensation policy;
- output-channel isolation for left/right sweep passes;
- exact capture frame boundaries;
- cancellation/teardown idempotence;
- synthetic paired L/R measurements surviving project round-trip;
- independent L/R aggregation;
- no correction deployment on measurement failure.
