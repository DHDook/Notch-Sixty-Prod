# PR80 — Audio Unit Offline Preparation and Validation

## Purpose

PR80 crosses exactly one boundary beyond PR79:

**real Audio Units may now be instantiated, configured, allocated, rendered, reset, state-restored, state-captured, and torn down — entirely off the realtime production path.**

PR80 still does **not** insert any third-party Audio Unit into live Notch Sixty playback.

The purpose of this PR is to create a deterministic airlock between arbitrary third-party plug-in code and the later realtime rack.

## Relationship to PR79

PR79 established:

- Audio Unit metadata discovery;
- rack and Content Preset ownership;
- layout compatibility policy;
- latency/tail bounds;
- quarantine;
- latency-matched bypass planning;
- no instantiation or render API.

PR80 keeps that architecture and implements the real preparation backend behind a new control-plane protocol:

`AudioUnitOfflinePreparing`.

The resulting evidence is an `AudioUnitOfflinePreparationReport`.

A later live-host PR may only use slots that carry valid state-specific preparation evidence.

## Real macOS preparation flow

For one rack slot PR80 performs:

```text
discovered component
    -> compatibility gate
    -> AVAudioUnit.instantiate off realtime
    -> verify exact Audio Component identity
    -> configure input/output format
    -> set bounded maximumFramesToRender
    -> restore slot opaque state when present
    -> allocate render resources
    -> direct deterministic offline render
    -> capture serializable full state
    -> AU reset
    -> second deterministic render
    -> verify prepared latency/tail remain stable
    -> deallocate render resources
    -> validate teardown
    -> publish preparation report
```

The instantiated `AVAudioUnit` / `AUAudioUnit` never escapes this operation.

PR80 stores only bounded serializable evidence and captured state.

## Audio format

The first preparation backend uses non-interleaved Float32 `AVAudioFormat` at the exact rack sample rate and symmetric channel count already accepted by PR79.

The same channel-count policy remains:

`N input channels -> Audio Unit -> N output channels`

for N = 1...32 when the component advertises support.

PR80 does not add:

- surround-to-stereo fallback;
- stereo expansion;
- semantic speaker-role remapping;
- LFE remapping;
- automatic format conversion inside the rack.

A component that cannot accept the exact current rack format fails the compatibility/preparation gate.

## Deterministic render exercise

PR80 calls the unit's real internal render block after render resources are allocated.

The pull-input block produces deterministic, bounded per-channel test content:

- a low-amplitude unique sine frequency for every channel;
- a low-amplitude channel-specific impulse.

This is not an audio-quality test.

The offline render proves:

- the unit can pull the exact configured channel count;
- the unit can render bounded frame requests;
- the output buffer layout is valid;
- every observed output sample is finite;
- the unit can render repeatedly;
- the unit can render again after `reset()`.

A plug-in is not rejected merely because it changes gain, phase, spectrum, or inter-channel content; those may be legitimate effects.

## Prepared latency and tail stability

Some Audio Units finalize latency or tail only after render resources are allocated.

PR80 therefore treats the post-allocation values as authoritative.

After deterministic rendering, the unit is reset and the reported latency/tail are read again.

Preparation fails closed if either prepared value changes across reset.

Current PR79 hard bounds remain:

- latency <= 10 seconds;
- tail <= 120 seconds.

A future live host must also detect dynamic latency changes caused by later parameter/preset changes and rebuild the rack outside realtime.

## Full-state handling

If a rack slot contains opaque state, PR80:

1. bounds it to the existing 8 MiB slot limit;
2. decodes it as a property-list dictionary;
3. restores it to `AUAudioUnit.fullState` before render-resource allocation.

After successful rendering PR80 captures the current `fullState` again when available and serializes it as a binary property list.

Captured state remains subject to:

- 8 MiB per slot;
- 32 MiB total rack state.

Malformed or unserializable state fails closed and maps to the PR79 state-restore quarantine reason.

## Per-slot preparation

PR79's early generic probe evidence was component-oriented.

PR80 makes live-readiness evidence **slot-specific**.

This is required because two instances of the same Audio Unit can carry different state and therefore different:

- latency;
- tail;
- parameters;
- internal topology.

The rack planner now prefers the prepared probe associated with that exact slot.

Changing a slot's opaque state:

- forces that slot to bypass;
- invalidates its slot-specific probe;
- invalidates its offline preparation report;
- requires fresh preparation before it can be enabled again.

Preparing or invalidating one slot does not erase valid preparation evidence for another instance of the same component.

## Controller lifecycle

`AudioUnitHostController.prepareSlotOffline(...)` is the real PR80 preparation entry point.

On success it records:

- exact slot-specific probe;
- offline preparation report;
- last-known latency;
- last-known tail;
- recaptured bounded full state;
- component lifecycle = prepared.

The slot remains **bypassed** after preparation.

A separate control-plane decision is still required to un-bypass it.

On preparation failure the existing quarantine machinery is used.

## Quarantine mapping

PR80 maps real preparation failures into the PR79 quarantine model.

Examples:

- state decode/restore/capture failure -> `stateRestoreFailure`;
- unstable latency -> `invalidLatency`;
- unstable tail -> `invalidTail`;
- resource allocation/teardown failure -> `renderResourceFailure`;
- render error or non-finite output -> `runtimeFailure`;
- instantiation / bus / format failure -> `instantiationFailed`.

Quarantine still:

- invalidates preparation evidence;
- forces matching slots to bypass;
- requires a fresh probe/preparation after quarantine is cleared.

## Resource teardown

Successful preparation requires proof that render resources are no longer allocated before the report is accepted.

The backend also uses a defensive deferred teardown path for thrown errors.

No prepared report is valid if render resources remain allocated.

The instantiated unit is then released by normal ARC when preparation returns.

## Real-system smoke validation

The macOS XCTest suite exercises the actual Apple Low Pass Audio Unit when it is registered on the runner.

The test covers:

- public metadata discovery;
- actual `AVAudioUnit` instantiation;
- stereo format configuration;
- real render-resource allocation;
- direct internal render-block execution;
- reset;
- finite output;
- teardown;
- full-state round trip when supported.

If that Apple component is unavailable on a particular runner, the real-system test skips rather than substituting a fake component.

Deterministic mock backends separately cover all fail-closed state transitions.

## Explicit realtime boundary

PR80 must not reference or modify:

- `N60RealtimeAudioBridge`;
- `N60LiveNChannelBridge`;
- `N60LiveNChannelRenderCore`;
- the PR77 physical-output treatment callback;
- production Core Audio IOProc callbacks.

No `AVAudioUnit`, `AUAudioUnit`, render block, or Audio Unit instance is stored in `AudioIOEngine`.

No third-party code executes from the realtime Notch Sixty callback in PR80.

## UI boundary

The Extensions -> Plug-ins page remains the PR79 control surface.

It may scan component metadata, but PR80 does not enable:

- Add Plug-in;
- vendor/custom plug-in UI;
- live bypass;
- live wet/dry;
- drag reordering;
- live parameter editing.

Real offline preparation is an internal/controller capability in PR80.

The rack remains visibly **NOT IN LIVE PATH**.

## Validation

PR80 adds XCTest coverage for:

- actual Apple Low Pass instantiation/render/reset/teardown;
- real captured-state round trip when available;
- same Audio Unit binary with different per-slot state and latency;
- state change invalidating only the affected slot;
- offline state-restore failure -> quarantine;
- nondeterministic latency rejection;
- leaked render-resource evidence rejection.

PR80 structural CI proves:

- instantiation occurs only in `AudioUnitOfflinePreparation.swift`;
- no Audio Unit object reaches the production render graph;
- no production callback references the host/preparer;
- slot-specific evidence is used by rack planning;
- state mutation invalidates slot preparation;
- Add Plug-in remains disabled;
- vendor UI remains absent.

CI also retains the PR77 realtime safety simulation and the PR79 host-foundation structural policy.

## Next live-host layer

A future PR81 can consume this substrate to build the first production rack runtime.

That PR will need to:

- instantiate each enabled prepared slot off realtime;
- restore the exact validated slot state;
- allocate all buffers and render resources before activation;
- construct immutable live slot objects;
- implement sample-aligned wet/dry;
- implement latency-matched bypass;
- publish total rack latency;
- handle dynamic latency changes with rebuild/fade;
- handle tails during bypass/removal;
- quarantine runtime failures;
- swap complete rack snapshots atomically;
- keep System correction / routing / protection downstream.

PR81 must separately prove that no allocation, locks, logging, discovery, state serialization, or unit construction occurs inside the production callback.

## Provenance

PR80 uses Apple's public Audio Unit / AVFAudio APIs plus clean-room proprietary preparation, validation, state, and quarantine logic.

It adds no third-party library, private API, driver, helper process, entitlement, or network dependency.
