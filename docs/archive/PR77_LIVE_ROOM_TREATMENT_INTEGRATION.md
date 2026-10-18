# PR77 — Hardware-Gated Live MIMO Room-Treatment Integration

## Purpose

PR77 connects the PR76 room-treatment transition runtime to the production semantic N-channel physical-output path while preserving a **hardware-gated, default-off** product contract.

This is the first PR in which the room-treatment runtime can exist in the same callback path that writes real speaker/subwoofer samples.

That does **not** mean room treatment is enabled by default.

A live treatment instance can only be staged from a PR76 activation permit, and that permit can only exist after the complete PR75 chain has passed:

- physical-source safety declarations;
- repeat acoustic verification;
- real hardware/lifecycle acceptance.

PR77 adds no UI arm control and no persisted armed state.

## Insertion point

The treatment stage is inserted at the **physical-output boundary**:

```text
semantic program
  -> PR54 lane calibration
  -> PR55 bass management / native LFE -> Sub N
  -> physical source frame
  -> PR77 latency-matched room-treatment integration
  -> startup/master output gain
  -> physical meters
  -> Core Audio output
```

This is deliberate.

PR73 measurements describe the actual physical speakers/subwoofers. Applying the MIMO matrix after bass management and source calibration keeps the runtime domain aligned with those measurements.

The PR77 stage does not reinterpret native LFE as a physical subwoofer. It operates only on the exact physical source list carried by the PR73/74/75/76 chain.

## Full-array latency matching

The PR74/76 treatment subsystem has substantial fixed latency.

At the default 4096 taps:

- FIR causal delay: 2048 frames;
- partition engine latency: 256 frames;
- total: 2304 frames, approximately **48 ms at 48 kHz**.

Applying that delay only to treated sources would time-shift those speakers/subwoofers relative to the rest of the array.

PR77 therefore delays **all physical outputs** by the exact treatment-subsystem latency whenever a treatment integration is configured.

Selected treatment source channels are then replaced by PR76's latency-matched identity/treatment transition outputs.

Untreated channels remain exact delayed identity.

Consequences:

- treatment active and bypassed states have identical system latency;
- arm/bypass/fault transitions do not change speaker timing;
- untreated surrounds/heights/mains cannot become ~48 ms early relative to treated subs/speakers;
- published N-channel latency includes the treatment subsystem.

When no treatment is staged, this latency layer does not exist and the previous N-channel path is unchanged.

## Exact physical route binding

A PR76 permit alone is not enough for live use.

PR77 also binds the staged treatment to:

- the exact accepted `OutputDeviceProfileConfiguration`;
- the exact selected output UID used during staging;
- the exact ordered PR74 treatment source list;
- the current physical channel mapping for every treatment source.

At live N-channel startup, a profile or selected-output change causes startup to fail closed with a permit/route mismatch.

Treatment source mapping is explicit:

- `speaker(role)` -> that semantic speaker's compiled physical output;
- `subwoofer(index)` -> physical Sub N output.

Unmapped native LFE, missing sources, duplicate physical destinations, or out-of-range physical channels fail closed.

This prevents an acceptance record for one two-sub/speaker system from being silently reused on a different system that happens to have the same channel count and sample rate.

## AudioIOEngine staging contract

PR77 introduces internal control-plane staging:

- `stageRoomTreatmentForNextStart`;
- `clearStagedRoomTreatment`;
- runtime arm/bypass/fault/revoke calls.

Staging is allowed only while the audio lifecycle is idle.

The staged value is:

- private;
- nil by default;
- not `@Published`;
- not persisted;
- not surfaced as a user enable toggle in PR77.

The current Output Device Profile and selected output UID are captured at staging time.

At N-channel startup those exact values must still match.

If no staged treatment exists, `CoreAudioNChannelTransportSession` receives `nil` and the prior live path is unchanged.

## Permit validation

Before treatment is installed into the live bridge, PR77 revalidates:

- output sample rate;
- FIR sample rate;
- permit sample rate;
- treatment source order;
- tap count;
- declared FIR latency;
- engine latency;
- total latency;
- transition fade configuration;
- physical route availability.

Only after those checks does the session create the physical-output integration and mark the PR76 transition runtime authorized.

Authorization alone does not arm treatment.

The runtime begins in latency-matched bypass.

Arming still requires an explicit control-plane request.

## Realtime behavior

`N60MIMOTreatmentLiveProcessPhysicalFrame` is called after the existing N-channel render has produced one physical frame and before output gain/meter/write.

It performs:

1. copy selected physical-source samples into the bounded <=4-channel treatment input;
2. run the continuously warm PR76 latency-matched identity/treatment engines;
3. advance the full-physical-output latency ring;
4. replace only selected physical channels with treatment-transition output;
5. apply the emergency sample fail-safe;
6. publish lock-free counters/state through the existing bridge snapshot.

The realtime integration performs no:

- allocation/free;
- blocking lock;
- logging;
- trigonometry;
- file/network I/O;
- device discovery;
- filter design;
- async task creation.

All FIR programs, FFT kernels, transition engines and delay memory are prepared before callbacks start.

## Emergency sample clamp

PR77 adds a final emergency sample clamp while the treatment integration is configured.

Any non-finite or >|1.0| physical sample is:

- replaced/clamped to a finite [-1, +1] value;
- counted;
- used to latch a PR76 `Protection` fault.

The transition then moves toward latency-matched identity using the shorter fault fade.

If the treatment FIR runtime itself fails, PR76 uses its warm identity path.

If the latency-matched identity runtime fails, PR77 zeros the entire physical frame rather than emitting a partially delayed/misaligned speaker topology.

The emergency sample clamp is **not a substitute** for:

- physical excursion modeling;
- thermal limits;
- true-peak/limiter validation;
- amplifier/speaker/subwoofer protection;
- the PR75 hardware acceptance record.

It is a final software fail-safe.

## Fault and lifecycle behavior

PR77 exposes the PR76 fault controls through the live session:

- request arm;
- request bypass;
- latch fault;
- clear fault;
- revoke authorization.

Reset revokes authorization.

A newly rebuilt Core Audio session only regains authorization by replaying the staged PR76 permit validation against the current route.

Sample-rate or profile mismatch therefore fails closed during rebuild.

No armed-state persistence is introduced.

## Diagnostics

Production semantic transport telemetry now includes:

- treatment configured/not configured;
- authorized;
- arm requested;
- active/transitioning/faulted;
- treatment mix;
- treatment source count;
- treatment latency;
- processed frames;
- protection clamp samples;
- integration failures.

The published semantic-path latency includes:

- PR54/55 graph delay;
- adaptive SRC buffering when active;
- PR77 treatment latency when configured.

The Transport page may display treatment health, but PR77 intentionally adds **no UI arm control**.

## Validation

Portable C validation covers:

- exact full-array latency matching;
- selected-source MIMO replacement;
- untreated-channel delayed identity;
- active treatment state;
- protection clamp/fault behavior;
- invalid/duplicate physical mapping rejection.

Swift/XCTest covers:

- Sub N source -> physical channel mapping;
- mixed speaker/sub treatment order;
- unmapped native LFE fail-closed behavior;
- permit/sample-rate mismatch;
- production diagnostics contract.

Structural CI proves:

- live treatment runs after physical render and before hardware write;
- all physical outputs are latency matched;
- realtime callback contains no forbidden operations;
- AudioIOEngine staging is private/default-off/not published;
- exact profile + selected-output route binding is enforced;
- the UI contains health telemetry but no arm/bypass/stage controls.

CI also retains PR76 transition validation, PR75 verification gates, arm64 build and the full XCTest suite.

## Remaining hardware acceptance

PR77 can be software-complete without claiming a successful physical activation.

Before this path should be used on the user's actual system, perform the previously defined PR75/76 acceptance on real hardware:

- verify exact Output Device Profile and physical source mapping;
- verify actual excursion/thermal assumptions;
- confirm final protection-chain ordering;
- start in bypass and confirm all channels retain timing;
- arm at low level;
- verify 20–150 Hz response at every accepted seat;
- verify predicted vs measured improvement;
- test long-run thermal behavior;
- test Stop/Start;
- unplug/replug;
- sleep/wake;
- sample-rate changes;
- emergency/protection fault;
- listen for clicks, latency discontinuities, pumping, image shifts or bass localization artifacts.

Until that is done, PR77 should remain draft and the product should ship with no staged treatment.

## Relationship to Active Quiet Zone

PR77 is still playback-derived active room treatment.

It controls the room response caused by Notch Sixty's own program signal.

It is not environmental ANC and does not use reference microphones or FxLMS.

The later Active Quiet Zone branch remains separate and should build on PR72 ambient analysis plus the now-bounded physical-output/arming/fault infrastructure.

## Provenance

PR77 is clean-room proprietary work built on the proprietary PR54/55/69–76 architecture and standard bounded delay/matrix-filter concepts. It adds no third-party DSP library, private API, driver, helper, entitlement or network dependency.
