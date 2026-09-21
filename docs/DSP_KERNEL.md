# Realtime DSP Kernel

PR #12 establishes the production realtime DSP boundary without adding an EQ algorithm or importing legacy DSP source.

## Current signal path

```text
RealtimeBridge
    ↓
InputGain
    ↓
IdentityReferenceStage
    ↓
OutputGain
    ↓
Physical output
```

The reference stage is intentionally transparent. It exists to prove the graph publication, realtime render, latency, bypass, reset, and diagnostic contracts before substantive DSP stages are introduced.

## Format contract

- stereo only
- 32-bit floating-point samples at the render boundary
- native device sample rate
- no transport SRC
- graph sample rate must be finite and greater than zero
- graph channel count must be exactly 2

A transport session publishes a unity graph using the selected output's actual sample rate before Core Audio callbacks start.

## Realtime contract

`N60RenderKernel` executes on the physical-output callback. Its render functions perform:

- no heap allocation or deallocation
- no blocking locks
- no file or network I/O
- no logging
- no UI, AppKit, Combine, actor, task, or async work
- no graph construction or destruction
- no device discovery

One graph snapshot is acquired at the beginning of a hardware render buffer and held for the complete buffer. A parameter publication therefore cannot split one hardware buffer across two graph generations.

## Graph publication

`N60DSPGraphSnapshot` is a render-ready value containing the graph-wide fields currently required by the reference kernel:

- sample rate
- channel count
- input gain
- output gain
- bypass
- algorithmic latency in frames
- publication generation

The kernel owns two preallocated snapshot slots. The active slot index and per-slot reader counts use C11 atomics. The realtime reader performs a bounded acquisition (maximum three attempts). If pathological publication churn prevents acquisition, the callback passes sanitized samples through and increments `snapshotReadMisses`; it never waits.

Publication is a serialized control-plane operation. The writer fills the inactive slot and may yield while an older realtime reader releases that inactive slot, then atomically publishes it. The control plane may wait; the realtime callback may not.

Future graph implementations may replace the scalar snapshot with richer preallocated render-ready state while preserving these publication and lifetime rules.

## Latency

The PR #12 graph has **0 frames algorithmic latency**. Transport/device buffering is separate and must not be reported as DSP algorithmic latency.

Every future DSP stage must declare its latency in frames. The graph snapshot reports the resulting graph latency so UI, video-sync policy, and later latency compensation can consume one authoritative value.

## Bypass

Graph bypass skips input gain, processing stages, and output gain. Input sanitation still applies so non-finite values cannot escape the render boundary.

Individual stage bypass contracts will be defined as stages are added.

## Numerical safety

At the kernel boundary:

- NaN and positive/negative infinity are replaced with zero and counted.
- subnormal/denormal floating-point samples are replaced with zero and counted.
- finite normal samples pass unchanged unless a graph stage processes them.

These checks provide a deterministic containment boundary; they do not replace processor-specific stability tests.

## Reset

`N60RenderKernelReset` resets runtime diagnostic counters. It does not allocate memory or rebuild the graph. Stateful DSP stages added later must document and implement their own reset semantics as part of graph construction/reconfiguration.

## Diagnostics

The kernel exposes:

- rendered frame count
- non-finite samples sanitized
- denormals flushed
- snapshot-read misses
- current graph generation
- current graph latency
- current sample rate/channel count
- graph bypass state

Normal production operation should report zero sanitation events and zero snapshot-read misses.

## Validation

Deterministic unit tests cover:

- unity transparency at 44.1, 48, 96, 192, and 384 kHz
- input/output gain application
- graph bypass
- latency reporting
- rejection of invalid channel-count graphs
- NaN/Inf sanitation

Hardware validation after this PR should confirm that inserting the unity kernel does not regress the validated transport: zero steady-state underruns/overruns, low bridge depth, correct native rate, and subjectively unchanged audio.
