# PR79 — Audio Unit Host Foundation

## Purpose

PR79 establishes the control-plane foundation for Notch Sixty's Playback Plug-in Rack.

It deliberately **does not** put third-party Audio Units in the realtime render graph yet.

The PR proves the product/state model, public component discovery, compatibility policy, state bounds, latency/tail planning, quarantine behavior, and fail-closed bypass rules before any external plug-in code can touch production audio.

## Signal-chain ownership

The intended product chain remains:

```text
Playback DSP
    -> Audio Unit Rack
    -> System correction
    -> bass management / routing
    -> physical protection
    -> output
```

The rack belongs to **Playback/content state**, not System state.

That means Content Presets can recall plug-in rack state without coupling third-party effects to a specific speaker, headphone, room-correction, or output-device profile.

PR79 adds `AudioUnitRackConfiguration` to `ContentPresetState`.

Existing saved Content Presets remain valid: the custom decoder maps archives that predate PR79 to an empty four-slot rack.

## Scope

PR79 supports registered Audio Unit:

- effects;
- music effects.

Generators and instruments are outside this rack because Notch Sixty is a playback processor rather than a source/instrument host.

Discovery uses the public `AVAudioUnitComponentManager` metadata API.

The catalog reads component information only. PR79 contains no:

- `AVAudioUnit.instantiate`;
- `AUAudioUnit.instantiate`;
- render-resource allocation;
- plug-in render block;
- custom plug-in view opening;
- realtime graph insertion.

## Rack model

The default rack contains **4 slots**.

The bounded maximum is **8 slots**.

Each occupied slot stores:

- stable Audio Component type / subtype / manufacturer identity;
- display-name and manufacturer snapshots;
- bypass state;
- wet/dry value;
- optional opaque full-state blob;
- last-known latency;
- last-known tail.

Opaque state is deliberately bounded:

- maximum 8 MiB per slot;
- maximum 32 MiB for the complete rack.

Malformed empty slots cannot carry orphaned plug-in state.

## Component discovery

`SystemAudioUnitComponentCatalog` asks macOS for registered effect and music-effect components.

For each component PR79 records:

- stable Audio Component identity;
- name;
- manufacturer;
- type name;
- version;
- custom-view capability;
- MIDI input/output flags;
- AU validation status;
- sandbox-safe status;
- supported symmetric input/output channel counts from 1 through 32.

No component is opened during discovery.

## Initial channel-layout policy

The first Notch Sixty AU rack uses **symmetric channel layouts only**:

```text
N input channels -> plug-in -> N output channels
```

for N = 1...32 when the component reports support.

This cleanly covers stereo and semantic multichannel layouts such as 5.1, 7.1, 7.1.4, and 9.1.6 when a plug-in actually supports those channel counts.

PR79 intentionally does not silently insert a stereo-only effect into a surround path.

There is no implicit:

- surround-to-stereo downmix;
- stereo duplication into surround;
- LFE reassignment;
- speaker-role remapping.

An unsupported layout is incompatible for that current rack format.

## Compatibility policy

A component is catalog-compatible for a given rack format only if:

- it is an effect or music effect;
- it reports passing AU validation;
- it reports sandbox safety for the current process;
- it reports symmetric support for the current channel count.

Catalog compatibility is still not permission to enter the live graph.

A future activation PR must first complete the off-realtime probe contract.

## Off-realtime probe contract

`AudioUnitHostProbeBackend` defines the future instantiation/preparation boundary.

A successful `AudioUnitProbeResult` must prove:

- exact sample-rate match;
- exact input/output channel-count match;
- sufficient `maximumFramesToRender`;
- finite non-negative latency;
- finite non-negative tail;
- bounded latency <= 10 seconds;
- bounded tail <= 120 seconds.

The probe also records whether the component supports host bypass and opaque full state.

PR79 tests this lifecycle through mock probe backends. It does not instantiate real Audio Units.

## Latency and tail planning

`AudioUnitRackPreparationPlanner` produces a bounded immutable execution plan.

For every active plug-in it calculates:

- plug-in latency in frames;
- tail in frames;
- per-slot dry compensation needed for wet/dry mixing.

The rack plan publishes:

- aggregate serial latency;
- aggregate bounded tail;
- whether latency-matched bypass is required.

Wet/dry paths must remain sample-aligned: a non-100% wet slot declares dry compensation equal to that plug-in's latency.

## Safe bypass

A missing, incompatible, quarantined, or user-bypassed component is never replaced with a zero-latency shortcut if doing so would change timing.

The planner uses **latency-matched dry bypass** whenever a trustworthy probe or persisted last-known latency is available.

If a failed/missing plug-in has no known safe bypass latency, live planning fails closed.

This prevents a future runtime from silently changing total rack latency because a third-party component disappeared or failed validation.

## Quarantine

`AudioUnitQuarantineRegistry` records component failures and reasons such as:

- AU validation failure;
- sandbox incompatibility;
- unsupported channel layout;
- instantiation failure;
- render-resource failure;
- invalid latency/tail;
- state-restore failure;
- runtime failure;
- manual quarantine.

A quarantined component cannot receive a process disposition from the execution planner.

If known latency exists it can only receive latency-matched dry bypass. Otherwise activation fails closed.

Quarantine can be explicitly cleared on the control plane.

## Host controller lifecycle

`AudioUnitHostController` owns:

- discovered metadata;
- Content Preset rack state;
- lifecycle state per component;
- successful probe results;
- quarantine state.

Lifecycle values are:

1. `discovered`
2. `probing`
3. `prepared`
4. `quarantined`

Installing a discovered component into a slot starts it **bypassed**.

A component cannot be un-bypassed at the model layer until it has a successful probe result.

This prevents UI/state code from manufacturing a live-ready state around an unprepared Audio Unit.

## UI

Extensions -> Plug-ins now has a real PR79 foundation surface.

It can:

- scan registered Audio Unit effects;
- show the current rack format;
- show discovered / compatible / prepared / quarantined counts;
- display catalog compatibility and component identity;
- show Content Preset rack slots.

It still cannot:

- add a component to the live graph;
- instantiate an Audio Unit;
- open a third-party UI;
- enable processing.

The Add Plug-in control remains disabled and the rack is labeled **NOT IN LIVE PATH**.

## Validation

PR79 XCTest covers:

- native macOS component metadata discovery;
- unique component identities;
- channel-count metadata bounds;
- rack JSON round trip;
- opaque state preservation;
- legacy Content Preset decoding to an empty rack;
- active serial latency/tail aggregation;
- wet/dry latency compensation;
- missing component -> known-latency bypass;
- missing component without known latency -> fail closed;
- stereo-only component in 12-channel path -> bypass/fail-closed policy;
- quarantined component cannot process;
- mock scan -> install -> probe -> prepare lifecycle;
- mock probe failure -> quarantine;
- bounded opaque plug-in state.

Structural CI also proves there is no Audio Unit instantiation or render API in the PR79 implementation.

## Realtime safety boundary

PR79 changes no C realtime callback and adds no new render stage.

Third-party code is not called by:

- `N60RealtimeAudioBridge`;
- `N60LiveNChannelBridge`;
- `N60LiveNChannelRenderCore`;
- the PR77 physical-output treatment stage.

The future live-host PR must define a bounded render architecture and prove callback behavior separately.

## Next activation layer

The natural next step is a live AU rack activation PR that:

- asynchronously instantiates prepared components off the audio callback;
- validates and allocates render resources off realtime;
- restores opaque state off realtime;
- obtains bounded render blocks;
- preallocates every audio buffer;
- implements sample-aligned wet/dry and bypass;
- publishes plug-in latency into total product latency;
- handles latency changes, resets, tails, and device/sample-rate rebuilds;
- isolates/quarantines failures;
- keeps System correction and final protection downstream.

That PR should use PR79's immutable execution plan rather than re-discovering or constructing plug-ins in the callback.

## Provenance

PR79 uses Apple's public Audio Unit discovery types plus clean-room proprietary host/state/planning code.

It adds no third-party library, private API, driver, helper process, new entitlement, or network dependency.
