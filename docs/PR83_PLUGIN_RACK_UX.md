# PR83 — Transactional Plug-in Rack UX

## Purpose

PR83 turns the PR79–82 Audio Unit host substrate into a complete user-facing Playback Plug-in Rack without weakening the realtime or rollback guarantees established by PR80–82.

The rack remains **Content Preset state** and remains upstream of System correction, routing, bass management, and final protection.

## Rack workspace

Extensions → Plug-ins now supports:

- searchable installed Audio Unit browser;
- compatibility, prepared, and quarantine filters;
- manufacturer filtering;
- add into an empty slot or append new slots up to the eight-slot bound;
- remove;
- reorder;
- per-slot bypass;
- per-slot wet/dry;
- preparation/quarantine state;
- per-slot latency and tail badges;
- total rack latency;
- explicit quarantine clearing followed by mandatory fresh preparation.

All audio-affecting edits call the single PR82 transaction surface:

`ProductController.mutateAudioUnitRack(...)`

The UI does not directly mutate live Audio Unit instances.

## Vendor / custom editor safety

Opening a plug-in editor creates a **detached Audio Unit copy** on the control plane.

The detached copy:

1. restores the slot's persisted full state;
2. presents the vendor custom view when available;
3. otherwise presents host-visible Audio Unit parameters;
4. captures `fullStateForDocument` / `fullState` only when the user chooses Apply.

Apply then submits the serialized state through PR82's `setOpaqueFullState` mutation. PR80 offline preparation is rerun before a new live generation can be published.

Cancel simply discards the detached copy. A vendor UI therefore cannot mutate the currently rendering Audio Unit behind the transaction barrier.

## Content Preset recall

PR83 closes a state-coherency gap in preset recall.

Previously, a Content Preset could replace the host's saved rack model while live processing remained on the previous PR81 rack. PR83 makes product-level Content Preset selection asynchronous and transactional:

1. resolve the target preset;
2. build and offline-prepare a whole-rack PR82 candidate when the rack differs;
3. apply the non-rack Playback state;
4. activate the candidate through PR82;
5. commit host rack state;
6. only then commit/persist the selected Content Preset ID.

Candidate failure leaves the existing live rack and selected preset intact.

## Tail / removal policy

PR83 keeps PR82's bounded transition policy for remove and bypass.

It deliberately does **not** keep an old arbitrary third-party rack additively audible for its complete declared tail. A generic tail may be as long as the host's 120-second bound and may contain correlated or nonlinear output. Summing it with the replacement generation can increase level unpredictably and consume downstream headroom.

Instead, remove/bypass uses the bounded click-safe PR82 crossfade (or the controlled restart path if latency changes), after which the old generation is retired. Final System protection remains downstream.

The removal UI states this policy explicitly.

## Mutation extensions

PR83 adds two control-plane mutation forms to make the UX and preset recall use the same transaction engine:

- `append(component:initiallyBypassed:)`
- `replaceConfiguration(_:)`

The former preserves the eight-slot rack bound. The latter is used for atomic whole-rack Content Preset recall.

## Validation

PR83 adds:

- XCTest coverage for transactional append, the eight-slot limit, and whole-rack replacement deferring commit;
- a structural guard proving the production workspace routes all edits through PR82;
- a guard proving detached vendor UI has no live-rack runtime/render-resource access;
- inherited PR82 lock-free exchange validation;
- arm64 application build;
- retained PR79–82 targeted tests;
- full retained XCTest suite.
