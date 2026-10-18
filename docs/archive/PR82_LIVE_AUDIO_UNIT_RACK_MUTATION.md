# PR82 — Transactional Live Audio Unit Rack Mutation

## Purpose

PR82 makes the PR81 live Audio Unit rack safely mutable without exposing rack-editing UI yet.

The product-level contract is now:

```text
request mutation
  -> build candidate configuration without touching current state
  -> reuse exact PR80 evidence when still valid
  -> re-run PR80 preparation for changed active state
  -> build fresh immutable PR81 live runtime
  -> choose activation policy
       same total latency -> lock-free live crossfade
       changed latency    -> controlled transport restart
  -> wait for rendered-generation acknowledgement
  -> commit model / Content Preset-facing rack state
```

If candidate preparation, live construction, crossfade, or restart fails, the current rack configuration is not committed.

## Supported mutation model

The internal PR82 mutation API supports:

- install/replace a component in a slot;
- remove a component;
- reorder slots;
- bypass/un-bypass;
- wet/dry changes;
- opaque full-state changes.

PR83 can expose these operations in the Plug-ins UI without inventing its own audio lifecycle rules.

## Transactional candidate preparation

`AudioUnitHostController.makeMutationCandidate(...)` works on a local copy of `AudioUnitRackConfiguration`.

The current `rackConfiguration` remains untouched while PR82:

- validates slot bounds/state-size limits;
- resolves installed component metadata;
- reuses an existing slot report only when:
  - slot UUID matches;
  - component identity matches;
  - rack format matches;
  - opaque state matches exactly;
- runs PR80 offline preparation for changed active state;
- constructs a new execution plan;
- creates fresh PR81 live Audio Unit instances.

A failed candidate does **not** quarantine or alter the currently playing instance.

The host commits the candidate only after the engine reports a successful activation.

## Slot identity and reorder

Preparation evidence follows stable slot UUIDs rather than visual position.

Reordering moves the complete slot object, including its UUID and state.

This means moving an unchanged plug-in from slot 1 to slot 3 does not invalidate its state-specific PR80 preparation merely because the UI position changed.

## Same-latency live mutation

When the candidate rack has the same:

- sample rate;
- semantic channel count;
- maximum render quantum;
- total validated rack latency,

PR82 keeps Core Audio running.

`AudioUnitLiveRackSwitchboard` owns a fixed `N60AudioUnitRackExchange` created before callbacks start.

The exchange contains:

- three fixed processor slots;
- lock-free per-slot reader counts;
- active/requested slot atomics;
- published/rendered generation counters;
- a transition-failure counter;
- two preallocated full-rack scratch buffers.

The current and candidate racks render the same input during the transition.

PR82 applies a bounded **linear crossfade**:

```text
output = old * (1 - alpha) + new * alpha
```

Linear rather than equal-power crossfade is intentional: when old/new outputs are highly correlated, it avoids a +3 dB midpoint gain increase.

Default transition length is 2,048 frames.

## Lifetime safety

The Core Audio session retains the switchboard, not an individual rack runtime.

Swift retains every runtime associated with an exchange slot.

A retired Swift runtime is released only when the C exchange reports that its slot:

- is not active;
- is not requested;
- has zero realtime readers.

Audio Units and render resources therefore cannot be deallocated while a callback can still observe their processor context.

All reclamation and AU teardown happens off realtime.

## Candidate failure during crossfade

If the candidate processor reports a catastrophic rack-level failure during crossfade while the old processor is still healthy:

- the output remains the old rack for that callback;
- the transition is cancelled;
- the old generation stays active;
- the transition failure count is incremented;
- the candidate generation is not acknowledged.

The ProductController therefore does not commit the candidate rack.

Individual PR81 plug-in render faults still use their per-slot latency-matched dry fallback and lock-free fault latch.

## Latency-changing mutation

A total rack-latency change cannot safely be hidden inside an in-place crossfade because:

- stereo Reference/Delta delay must change;
- product latency reporting must change;
- downstream transport timing assumptions must remain coherent.

PR82 therefore uses a controlled transport restart for any latency-changing candidate.

The engine:

1. retains the current switchboard;
2. constructs the replacement switchboard completely off realtime;
3. stops the current transport through the existing fade-out path;
4. starts the same route with the replacement rack;
5. uses the normal startup gate/fade-in;
6. if startup fails, restores and restarts the prior switchboard.

Only after successful restart does the host commit the candidate configuration.

## Empty-rack transitions

If no rack processor is currently configured, adding the first live rack uses the controlled restart path so the callbacks receive a valid session-owned switchboard.

If an existing zero-latency switchboard transitions to an empty rack, the exchange can crossfade to its built-in passthrough generation without restarting.

Removing a non-zero-latency rack necessarily changes total latency and therefore uses the controlled restart path.

## Reconfiguration/recovery exclusion

Mutation is accepted only while the audio lifecycle is:

- `idle`; or
- `running`.

It is rejected during:

- permission/startup;
- sample-rate reconfiguration;
- output-device recovery;
- stopping;
- failed state.

PR82 never competes with the existing Core Audio recovery/reconfiguration state machine.

## Tail policy

PR82 guarantees click-safe bounded crossfade when a same-latency generation changes.

It intentionally does **not** keep a retired rack additively audible for its complete declared delay/reverb tail after the crossfade.

Doing that generically can:

- raise aggregate level;
- interact unpredictably with nonlinear effects;
- double correlated content;
- extend CPU load for up to the PR79 120-second tail bound.

Full user-facing tail-drain semantics for bypass/remove are deferred to PR83, where the UI operation and protection policy can be designed together.

Runtime failure remains safety-first: failed plug-ins switch to latency-matched dry immediately.

## Persistence boundary

`ProductController.mutateAudioUnitRack(...)` is the single mutation transaction entry point.

It:

1. resolves the exact current/next rack format;
2. asks the host for a candidate;
3. asks the engine to activate the candidate;
4. commits the host rack only after activation succeeds.

The existing Content Preset layer observes the committed host rack; PR82 does not add new persistence schema.

## UI boundary

PR82 does not enable rack editing UI.

The existing Plug-ins page remains live-host capable but:

- Add Plug-in stays disabled;
- remove/reorder controls are not exposed;
- wet/dry/bypass controls are not exposed;
- vendor UI remains unavailable.

PR83 can now add those controls on top of one transactional backend API.

## Validation

Portable C validation covers:

- required exchange atomics are lock-free;
- initial generation processing;
- exact four-frame crossfade math;
- rendered-generation acknowledgement;
- retired-slot reclamation;
- failed candidate keeps the old generation active;
- transition failure counter;
- crossfade to passthrough;
- in-place latency mismatch rejection.

Swift XCTest covers:

- switchboard equal-latency crossfade;
- switchboard latency-change rejection;
- candidate state does not commit early;
- reorder preserves slot UUID/preparation identity;
- failed candidate preparation leaves current rack untouched and does not quarantine the current component.

CI also retains:

- PR77 realtime safety simulation;
- PR79 host tests;
- PR80 real/offline preparation tests;
- PR81 live-rack tests;
- complete XCTest suite.

## Realtime boundary

The exchange render function does not:

- allocate/free;
- acquire blocking locks;
- dispatch;
- create tasks;
- log;
- discover components;
- serialize state;
- instantiate Audio Units;
- allocate/deallocate render resources.

It only:

- reads/writes lock-free atomics;
- calls already-prepared processor function pointers;
- copies/mixes preallocated buffers;
- advances bounded transition counters.

## Next layer

PR83 can now implement the complete Plug-in Rack UX:

- Add/Remove;
- reorder;
- bypass;
- wet/dry;
- preset/state selection;
- quarantine recovery;
- latency badges;
- vendor/custom AU windows.

Every audible edit should call `ProductController.mutateAudioUnitRack(...)` rather than mutating live AU instances directly.

## Provenance

PR82 uses C11 atomics and Apple's public Audio Unit host APIs inherited from PR79–81.

It adds no third-party dependency, private API, driver, helper process, entitlement, or network dependency.
