# PR101 — Full-System Reliability & Acoustic Acceptance

## Purpose

PR101 is the final reliability and acceptance campaign before PR102 integration
and commercial-release preparation. It does not add another DSP feature family.
It proves that the cumulative Notch Sixty system behaves predictably under
stress and makes the remaining physical acceptance work explicit.

The program covers stereo transport, semantic multichannel playback,
headphone/spatial runtime, Audio Unit hosting, Room Treatment, Active Acoustics,
lifecycle recovery, DSP regression, resource stability, dropout/fault recovery,
real-device recovery, sleep/wake, prolonged thermal runtime, speaker safety,
and final acoustic acceptance.

## Slice 1 — Acceptance framework and evidence authority

Slice 1 introduces one shared acceptance catalog and evaluator so later stress
campaigns cannot each invent their own meaning of "passed."

Every requirement declares:

- the subsystem or acceptance area being tested;
- the minimum evidence authority required;
- whether the requirement is hardware-only; and
- the reliability behavior that must be demonstrated.

The evidence ladder is deliberately monotonic:

1. **deterministic simulation**;
2. **macOS CI**;
3. **physical hardware**; and
4. **independent physical review**.

A stronger evidence class may satisfy a weaker requirement. A weaker class can
never satisfy a stronger requirement.

## Remote software requirements

The first ten requirements can ultimately be exercised remotely:

- stereo transport stability;
- semantic multichannel stability;
- headphone and spatial runtime stability;
- Audio Unit fault containment;
- Room Treatment fail-closed behavior;
- Active Acoustics fail-closed behavior;
- lifecycle recovery modeling;
- cumulative DSP correctness regression;
- CPU/memory stress instrumentation; and
- dropout/fault recovery stress.

The evaluator records completed iterations, injected faults, unexpected
dropouts, non-finite samples, unrecovered faults, crashes, memory change, CPU
telemetry, and callback-utilization telemetry.

Injected faults are not failures by themselves. They become a failure only when
they produce an unexpected dropout, non-finite output, an unrecovered fault, or
a crash.

Resource measurements are recorded in Slice 1 but no arbitrary CPU or memory
number is promoted to a product acceptance threshold yet. Later PR101 slices
will establish measured budgets from controlled campaigns instead of encoding
an unsupported constant.

## Hardware-only requirements

Five requirements are deliberately impossible to satisfy with remote or
synthetic evidence:

- real input/output device unplug and replug recovery;
- real macOS sleep/wake recovery and clock reacquisition;
- prolonged runtime and thermal stability on production-class hardware;
- speaker protection and actual emergency-mute behavior; and
- final measured acoustic acceptance.

Real device, sleep/wake, and long-run thermal requirements need physical
hardware evidence. Speaker safety and final acoustic acceptance require
independent physical review.

This preserves the PR98–PR100 rule: software evidence must never masquerade as
physical acoustic or safety verification.

## Acceptance states

The evaluator produces a result for every catalog item:

- **passed**;
- **failed**;
- **missing**;
- **insufficient evidence**; or
- **hardware required**.

It then exposes three intentionally separate rollups:

- **remoteSoftwareAccepted** — every remotely automatable requirement passed;
- **physicalAcceptanceComplete** — every hardware-only requirement passed; and
- **releaseAcceptanceComplete** — both of the above are true.

Therefore CI can eventually produce a clean remote-software acceptance report
while release acceptance remains false until genuine physical evidence exists.

## Evidence hygiene

Every observation carries a unique run identifier. Duplicate run IDs are
rejected so one campaign cannot be silently reused as evidence for two
requirements.

Observations with invalid iteration counts or non-finite/negative CPU or
callback-utilization telemetry are rejected before the acceptance matrix is
evaluated.

A high iteration count cannot compensate for insufficient evidence authority.

## Safety boundary

Slice 1 does not:

- connect or authorize feed-forward ANC output;
- certify a microphone, sound meter, reviewer, speaker, or DAC;
- simulate physical unplug/replug or sleep/wake and call it hardware evidence;
- claim acoustic attenuation or listening quality;
- define unsupported thermal, CPU, or memory limits; or
- mark a build release-qualified from CI alone.

## Planned follow-on work

Remote PR101 work will build on this contract with deterministic full-stack
stress campaigns, fault/recovery injection, resource and callback-performance
instrumentation, memory-growth checks, repeated DSP correctness runs, and
machine-readable acceptance reporting.

Real unplug/replug, sleep/wake, long-duration thermal behavior, speaker safety,
listening tests, and measured acoustic performance remain reserved for the
physical acceptance campaign.


## Slice 2 — Deterministic cross-subsystem reliability campaign

PR101 now has one portable deterministic campaign runner instead of relying on
the historical PR workflows as disconnected evidence islands.

The campaign replays the retained hardening simulations for six remote
reliability areas:

1. stereo adaptive-clock transport;
2. semantic N-channel adaptive-clock transport;
3. headphone, binaural, and head-tracking integration;
4. Audio Unit rack exchange and stage-fault containment;
5. Room Treatment transition and physical-output fail-closed simulation; and
6. Active Acoustics / feed-forward disconnected-output enforcement.

For stereo and multichannel transport it reruns the PR69/70/71 adaptive sample
rate quality and drift simulations. For Audio Units it reruns the lock-free
rack-exchange and deterministic stage-fault gate. Room Treatment reruns both
the transition simulator and physical-output integration simulator. Active
Acoustics reruns the PR98 runtime validator and disconnected-output audit.

The same runner executes on Linux/clang and Apple clang. It emits a
machine-readable JSON report naming every requirement, step, exit code, and
elapsed time. The report explicitly labels itself
`deterministicSimulation` evidence and hard-codes physical and release
acceptance to false.

The macOS PR101 job supplements that portable campaign with targeted XCTest for
the PR101 acceptance model, live Audio Unit runtime/mutation handling, live
Room Treatment integration, feed-forward clock monitoring, and native shadow
timing transport, followed by the full application regression suite.

This slice intentionally does **not** claim that the six deterministic
scenarios finish all ten remote PR101 requirements. Lifecycle recovery breadth,
resource/CPU/memory instrumentation, cumulative long-run dropout stress, and
machine-level resource budgets remain later PR101 slices. Likewise, none of
this software evidence satisfies the five hardware-only requirements.


## Slice 3 — Lifecycle recovery soak

PR101 now exercises the production lifecycle state machine as a deterministic
fault/recovery campaign rather than relying only on a few example transitions.

Each campaign iteration runs the complete startup path, repeated
reconfiguration/output-recovery transitions, orderly shutdown, and an
intentionally invalid idle → running jump. It then injects a failure at every
lifecycle state where failure is legal—from permission/startup through running,
reconfiguration, output recovery, and stopping—and requires every injected
fault to converge through **failed → stopping → idle**.

The targeted macOS test runs **5,000 complete iterations**, producing tens of
thousands of legal transitions and **45,000 injected lifecycle faults**. A
campaign passes only when all injected faults recover, every invalid direct
jump is rejected without state mutation, and no unrecovered transition remains.

The campaign result can create reliability evidence only at
`deterministicSimulation` or `macOSCI` authority. It explicitly rejects
attempts to label the result as `physicalHardware` or
`independentPhysicalReview`.

PR101 also adds a separate stable-UID route recovery soak. A stub device catalog
repeatedly removes the selected device and reintroduces the same stable UID with
a different transient Core Audio device ID. Across 250 cycles, the engine must
retain the selected UID while absent and reconnect the new transient ID when
the device reappears.

That test validates the **software recovery model only**. It deliberately leaves
the distinct `physicalDeviceRecovery` requirement at **HARDWARE REQUIRED**:
a simulated catalog disappearance is not evidence of a real USB/DAC unplug,
Core Audio driver teardown, clock reacquisition, or physical reconnect.


## Slice 4 — Resource and performance baseline

PR101 now reactivates the mature PR35 render-kernel and realtime-bridge
microbenchmarks against the **current cumulative engine** rather than treating
their older measurements as permanent truth.

The macOS CI job first builds the dedicated Release performance scheme, then
compiles the current realtime C sources at `-O3` for Apple Silicon and runs
five independent benchmark repetitions. The retained workloads cover:

- global DSP bypass;
- unity/parked DSP;
- active compressor;
- full metering;
- the full capture → DSP → output bridge; and
- the bridge with output VU metering enabled.

Each repetition reports nanoseconds per rendered frame and the corresponding
theoretical share of one core at 96 kHz. The wrapper also records process
wall/user/system time when available and the child process maximum resident set
size reported by macOS `/usr/bin/time -l`.

The generated JSON artifact contains every raw sample plus minimum, median,
mean, maximum, and population standard deviation for each benchmark case. It is
retained as a CI artifact so later PR101 runs can be compared against a known
exact commit instead of relying on screenshots or manually copied numbers.

### Why this is a baseline, not a hard gate

Hosted CI hardware, virtualization, runner contention, compiler revisions, and
thermal state can move microbenchmark numbers without a product regression.
PR101 therefore **does not invent a percentage threshold** and does not fail a
build merely because one hosted runner is slower than another.

The baseline runner does fail closed on invalid evidence: compilation or
execution failure, missing expected benchmark cases, non-finite/non-positive
measurements, or inconsistent bridge callback counts.

The report explicitly records
`hardPerformanceThresholdsApplied = false` and
`resourceStabilityAccepted = false`. Slice 4 establishes repeatable
instrumentation and trend evidence; it does not yet claim the complete
`resourceStability` acceptance requirement.

Peak RSS from short-lived benchmark processes is likewise **not** proof that
the shipping app is free of leaks. A later PR101 slice will add a longer
same-process resource/dropout soak before that remote requirement can become
eligible for acceptance.

None of these CI measurements establish real-machine thermal behavior,
production transport CPU, real sleep/wake or unplug/replug recovery, speaker
safety, acoustic acceptance, or live feed-forward ANC qualification.


## Slice 5 — Same-process realtime resource and dropout soak

Slice 5 upgrades the short-lived Slice 4 resource measurements into a
same-process reliability campaign around the production realtime bridge.

The macOS harness creates one `N60RealtimeAudioBridge`, publishes a unity
graph, disables optional meters, and keeps that same bridge alive for the entire
campaign. It performs **2,048 matched capture/output callbacks as warmup**
before taking its retained-heap baseline. No process restart is allowed to
erase leaked state between checkpoints.

The soak then performs **16 blocks × 1,024 normal capture/output callbacks**
for **16,384 normal callbacks**. Each block additionally injects **32 deliberate
starvation faults**, for **512 injected faults total**.

For each injected fault the direct SPSC ring is intentionally empty and the
output callback is invoked without a preceding capture. The required behavior
is exact fail-closed silence for that 512-frame quantum. The harness then
re-primes exactly one 512-frame input quantum and requires the immediately
following output callback to contain finite, nonzero signal.

Acceptance is exact rather than statistical:

- 512 injected starvation faults must produce exactly **262,144 underrun
  frames**;
- every injected fault must recover on the next primed callback;
- no unexpected silent output may occur outside the injected faults;
- no non-finite sample may escape;
- overrun frames must remain zero;
- unsupported buffer-layout events must remain zero;
- the bridge must end with zero buffered frames; and
- callback counts must match the exact campaign schedule.

### Same-process retained-memory gate

After warmup the harness primes the macOS allocation and task-info telemetry,
then records `malloc_zone_statistics(...).size_in_use` as its retained-heap
baseline. The same process remains alive for every subsequent callback.

At the end of every soak block, retained heap is sampled again. The remote
resource-stability gate requires **zero positive retained-heap growth at every
checkpoint** and final retained heap no greater than the post-warmup baseline.

Resident memory from `MACH_TASK_BASIC_INFO` is also recorded at baseline,
final state, and maximum observed level, but it is observational rather than a
hard gate: resident-set behavior can include allocator/VM effects that are not
equivalent to an application leak.

A successful Slice 5 artifact may mark the remote
`resourceStability` and `dropoutRecoveryStress` campaign evidence as
accepted at **macOS CI** authority. It still cannot establish prolonged thermal
behavior on a production Mac, real device unplug/replug, sleep/wake recovery,
speaker safety, physical acoustic acceptance, or live feed-forward ANC
authorization. Those hardware-only requirements remain unchanged.
