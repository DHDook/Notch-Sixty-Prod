# PR81 — Live Audio Unit Rack Activation

## Purpose

PR81 activates the Audio Unit rack in production playback.

PR79 established discovery, state, planning, quarantine, and latency policy.
PR80 proved real Audio Unit instantiation and rendering off realtime.
PR81 is the first layer that lets already-prepared third-party effects execute from the live audio callback.

The activation boundary remains deliberately narrow:

- all discovery, instantiation, state restore, format negotiation, resource allocation, buffer allocation, and graph construction happen before callbacks start;
- the callback sees only an immutable processor descriptor, preallocated buffers, prepared AU render blocks, and lock-free fault publication;
- System correction, routing, room treatment, headphone correction, and final protection remain downstream.

## Signal chain

Stereo:

```text
source
 -> existing Playback prefix through EQ / dynamic EQ
 -> Audio Unit rack
 -> crossover / room correction / Speaker IR
 -> existing downstream dynamics / spatial speaker tools
 -> headphone correction when applicable
 -> protection
 -> pause gate / output alignment / master
 -> hardware
```

PR81 intentionally inserts the rack at the existing post-EQ Playback/System boundary without otherwise reordering the mature stereo stages.

Semantic speakers:

```text
canonical semantic program channels
 -> Audio Unit rack
 -> per-channel System lanes
 -> bass management / native LFE routing
 -> semantic-to-physical map
 -> active room treatment when armed
 -> physical output
```

Virtual Speakers:

```text
canonical semantic program channels
 -> program gain
 -> Audio Unit rack
 -> head-tracked binaural renderer
 -> headphone correction
 -> true-peak protection
 -> physical stereo headphones
```

## Immutable session-bound runtime

`AudioUnitLiveRackRuntime` is built before Core Audio IOProcs start.

Each active process slot owns a fresh live Audio Unit instance built from the exact state that passed PR80 offline preparation.

The runtime preallocates:

- two full rack interleaved scratch blocks;
- each slot's latency-compensation delay memory;
- each process slot's dry scratch;
- each AU output `AVAudioPCMBuffer`;
- all Audio Unit render resources.

The C callback receives only `N60AudioUnitLiveRackProcessor`:

- opaque context;
- C function pointer;
- exact channel count;
- bounded maximum frames per callback;
- declared serial rack latency.

The Swift runtime remains strongly owned by the active Core Audio transport session until after its IOProcs are stopped and destroyed.

## Slot-specific state

Live-readiness is slot-specific.

A process slot must have a PR80 report matching:

- component identity;
- sample rate;
- semantic channel count;
- maximum render quantum;
- exact captured opaque state.

The live instance restores that exact state and must reproduce the prepared latency and tail within one frame before activation.

The same Audio Unit binary may therefore appear in multiple slots with different states and different latency.

## Wet/dry and bypass timing

Every active process slot runs a parallel dry delay equal to the slot's validated latency.

Wet/dry mixing therefore combines time-aligned paths.

A user-bypassed, missing, incompatible, or quarantined slot enters the rack as a latency-matched dry stage according to the PR79 execution plan.

Serial stage latency is preserved exactly.

The live rack publishes its total latency to:

- the stereo graph, including Reference/Delta audition delay;
- semantic N-channel diagnostics;
- Virtual Speakers diagnostics.

## Runtime fault behavior

A live process slot can encounter a render status failure or non-finite output even after successful offline preparation.

PR81 handles this in two layers.

Realtime:

1. mark that live stage faulted;
2. emit the slot's already-computed latency-matched dry path for the same callback;
3. permanently keep that stage on latency-matched dry for the remainder of the session;
4. atomically latch slot index, failure reason, status, and fault count.

Control plane:

1. a utility-queue timer observes the lock-free latch;
2. the host quarantines the component;
3. saved rack state is forced to bypass according to the existing quarantine contract.

The audio callback never dispatches a task, logs, serializes state, or mutates model/UI state.

A catastrophic rack invariant failure that prevents even the prepared fallback from running zeros the callback instead of emitting structurally invalid audio.

## Realtime rules

Notch Sixty code in the audio callback does not:

- allocate or free memory;
- instantiate Audio Units;
- discover components;
- restore/capture state;
- allocate/deallocate render resources;
- create tasks or dispatch work;
- acquire blocking locks;
- log;
- perform file/network I/O;
- rebuild the DSP graph.

Third-party Audio Unit code is opaque and can have its own implementation behavior; PR80/PR81 validate the host contract but cannot prove a vendor's internal implementation is realtime-safe.

## Stereo split regression

PR81 splits `N60RenderKernelProcessStereoFrameInContext` into:

- `N60RenderKernelProcessStereoPlaybackFrameInContext`;
- `N60RenderKernelProcessStereoSystemFrameInContext`.

The legacy wrapper remains and calls those two functions directly with no rack between them.

A regression test compares the wrapper against the explicit split path to ensure the no-rack signal path remains numerically equivalent.

## Canonical multichannel identity

The semantic rack always operates after Core Audio stream order has been mapped to canonical semantic program order.

The rack therefore sees semantic 5.1 / 7.1 / 7.1.4 / 9.1.6 channels rather than physical device ordering.

It runs before bass management and physical mapping, so:

- native LFE remains a program channel;
- Sub N remains a later physical-output concept;
- the rack cannot accidentally target physical speaker indices.

No stereo-only plug-in is silently inserted into a surround path.

## Production startup

`ProductController.startProcessing()` now:

1. asks `AudioIOEngine` for the exact next-start rack format;
2. scans the installed Audio Unit catalog;
3. re-runs PR80 offline preparation for active saved slots when current evidence is absent or stale;
4. builds the immutable live rack;
5. stages it in the engine;
6. starts the selected Core Audio transport.

This is required because live preparation evidence is intentionally not persisted across application launches.

## Recovery and format changes

The staged runtime may be reused for same-format output recovery while its exact sample rate/channel layout remains valid.

A sample-rate or semantic-layout change cannot mutate/reformat a live rack in place.

If automatic transport reconstruction encounters a rack-format mismatch it fails closed. A fresh product-level prepare/start must build new AU instances for the new format.

PR81 does not instantiate Audio Units from automatic recovery callbacks.

## UI boundary

Extensions -> Plug-ins now reports **LIVE HOST READY**.

The signal-chain card marks the rack active.

PR81 does not yet add rack-editing UX:

- Add Plug-in remains disabled;
- reorder remains unavailable;
- live bypass/wet-dry controls remain unavailable;
- vendor/custom plug-in windows remain unavailable;
- parameter editing remains unavailable.

Those controls require a separate rebuild/transition policy and are intentionally deferred.

## Validation

PR81 tests cover:

- exact latency-matched dry delay;
- serial bypass latency accumulation;
- callback-quantum fail-closed behavior;
- real Apple Low Pass offline-prepared -> fresh live instance -> production-style render;
- stereo split equivalence without a rack.

Structural CI proves:

- Audio Unit instantiation/resource allocation stays in Swift control-plane builders;
- callbacks contain no host-side allocation, locks, dispatch, tasks, logging, discovery, or state serialization;
- stereo ordering is Playback prefix -> rack -> System suffix;
- semantic ordering is canonical program -> rack -> System render core;
- Virtual Speakers ordering is semantic program -> rack -> binaural -> headphone correction -> protection;
- transport sessions retain live rack ownership through IOProc destruction;
- production start goes through PR80 preparation before activation;
- Add Plug-in/vendor UI remain deferred.

## Deferred work

A follow-on product UX PR can add:

- Add/Remove;
- reorder;
- bypass and wet/dry edits;
- vendor UI;
- parameter/preset editing;
- controlled rack rebuild/crossfade for latency-changing edits;
- tail-preserving user bypass/removal.

Runtime failure bypass in PR81 prioritizes safety and continuity over preserving the tail of a plug-in that has already failed.

## Provenance

PR81 uses Apple's public Audio Unit / AVFAudio APIs and clean-room proprietary realtime bridge/runtime code.

It adds no third-party library, private API, driver, helper process, entitlement, or network dependency.
