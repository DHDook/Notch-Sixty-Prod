# Room Correction Runtime Foundation

## Scope

PR #20 establishes the production **runtime** stage that will execute room-correction FIR programs. It deliberately does not implement measurement capture, acoustic analysis, multi-seat averaging, target-curve selection, or correction-filter design yet.

The stage is default-bypassed until a future control-plane component prepares and publishes a real correction program.

## DSP ordering

The production render order after PR #20 is:

```text
input
  -> input preamp
  -> internal headroom attenuation
  -> EQ (minimum-phase IIR OR linear-phase FIR)
  -> post-EQ meter
  -> bass management / crossover
  -> room-correction FIR
  -> DSP output gain
  -> output meter
```

Room correction is intentionally separate from linear-phase EQ. The two features may be active at the same time and their latencies therefore add.

## Independent convolution ownership

Linear-phase EQ and room correction each own a separate `N60PartitionedConvolver` instance.

Each convolver has its own three-program-slot namespace. Slot `0` in the linear-EQ convolver and slot `0` in the room-correction convolver are unrelated storage and may be prepared and referenced simultaneously.

This preserves the safe replacement model established for linear-phase EQ:

- two immutable DSP graph snapshot slots may still be referenced by render;
- three program slots leave a spare control-plane preparation target;
- a graph stores both program slot and generation;
- publication rejects an unprepared, stale, or metadata-mismatched program;
- realtime render never prepares or replaces an FIR program.

The two convolver instances prevent a room-correction update from retiring or overwriting a linear-EQ FIR, and vice versa.

## Realtime contract

Room-correction FIR preparation is control-plane work. FFT preparation and program generation happen before graph publication.

The realtime callback performs only bounded processing against preallocated state. It does not allocate/free memory, block on locks, log, perform file/network I/O, touch UI state, perform graph construction, or design filters.

If an impossible program mismatch reaches render, the room-correction stage fails dry for that sample and increments `roomCorrectionProgramMisses`. Publication-time validation is intended to prevent this in normal operation.

## Latency

The current uniform partitioned convolver contributes `256` frames of engine latency whenever the room-correction stage is enabled. A room-correction program may additionally declare filter/group-delay latency.

Graph latency is the sum of all enabled latency-bearing stages. In particular:

```text
linear-EQ total latency
+ room-correction engine latency
+ room-correction declared latency
= graph latency contribution when both FIR stages are active
```

A bypassed room-correction stage contributes zero latency.

At native sample rates, the 256-frame engine latency corresponds to approximately:

| Sample rate | Engine latency |
|---:|---:|
| 48 kHz | 5.33 ms |
| 96 kHz | 2.67 ms |
| 192 kHz | 1.33 ms |
| 384 kHz | 0.67 ms |

The runtime does not impose a fixed sample-rate whitelist. Device-native rates remain authoritative.

## Stereo semantics

The current product transport is two-channel. The room-correction FIR therefore accepts independent left/right impulse responses but remains a stereo processor.

This is compatible with future multi-seat measurement and averaging: multiple listening positions produce one correction solution for the two-channel playback system; they do not imply multichannel output.

## Validation in PR #20

Deterministic tests cover:

- default-bypassed room correction preserving the unity path and adding zero latency;
- same-numbered program slots in linear EQ and room correction remaining independent;
- summed latency when both FIR stages are enabled;
- rejection when a program prepared for the linear-EQ convolver is referenced as a room-correction program;
- deterministic room-correction impulse execution;
- a 384 kHz combined stress path with 64 PEQs, LR48 bass management, a 4,096-tap linear-EQ FIR, and a separate 4,096-tap room-correction FIR;
- zero program misses, snapshot misses, and non-finite output in the deterministic stress path.

Hardware validation will follow once the control plane exposes a deterministic validation IR or the measurement/correction pipeline can supply a real correction program.

## Deferred intentionally

The following are later milestones rather than simulated inside PR #20:

- microphone input and measurement-session lifecycle;
- sweep / excitation generation and response capture;
- impulse-response extraction and acoustic analysis;
- three-seat measurement storage and averaging/weighting;
- target-curve selection, editing, and import;
- correction-window and correction-range policy;
- correction-filter/FIR generation;
- automatic correction gain/headroom compensation;
- calibration persistence, export/import, and preset integration;
- final room-correction UI;
- subwoofer time/phase alignment and any future independently routed sub correction.

## Provenance

The PR #20 runtime architecture and integration are original commercial implementation in `DHDook/Notch-Sixty-Prod`, derived from the repository's product requirements, realtime rules, and the existing clean-room convolution interface.

No historical GPL Notch Sixty / Equaliser source, tests, project files, or implementation expression were used as a coding reference. No third-party DSP dependency is introduced.
