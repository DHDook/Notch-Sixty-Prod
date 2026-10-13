# PR113B — World-Class Product Finish

Status: **IN PROGRESS — SLICE 1 IMPLEMENTED REMOTELY**

PR113B is stacked directly on the exact remotely-complete PR113 head
`f0a260336a0df7284a0c414f39a6e43b7d86ca1b`.

It adds the final product-level capabilities agreed before PR114 Commercial
Release Candidate without reopening the core DSP feature roadmap.

## Planned slices

1. **Safe A/B comparison foundation and snapshot boundary**
2. **Click-free / loudness-matched A/B audition UI**
3. **Full Notch Sixty backup & restore bundle**
4. **Full-fidelity Measurement Lab export**
5. **Safe Launch / Recovery Mode**
6. **Headroom Assistant**
7. **Getting Started guide refresh and cumulative closeout**

The previously discussed modal first-run assistant is intentionally not planned.
Onboarding remains non-intrusive and will be strengthened inside the existing
Getting Started User Guide article in Slice 7.

A Playback-System lock is also intentionally deferred.

---

## Slice 1 — Safe A/B comparison foundation

Slice 1 establishes the A/B data and safety contract before any live switching
is permitted.

### Safe audition payload

`ContentABAuditionState` contains only:

- stereo EQ / phase configuration;
- input preamp gain;
- headroom attenuation; and
- content dynamics.

It intentionally excludes:

- Audio Unit rack topology;
- output selection or stable device UID;
- Playback System output trim;
- bass management or crossover topology;
- physical output routing;
- speaker or headphone device profiles;
- speaker-driver processing;
- Room Correction;
- speaker IR / FIR ownership;
- physical alignment state;
- hardware-acceptance authority; and
- release authority.

The helper that reconstructs a content state overlays the A/B-safe fields on
the **current** `ContentPresetState`, preserving the current Audio Unit rack.

### Playback System boundary

Every `ContentABSnapshot` captures a `ContentABSystemBoundary` containing:

- selected Playback System identity; and
- exact current `PlaybackSystemState`.

Compatibility is fail-closed:

- a different selected Playback System produces
  `.playbackSystemChanged`;
- any state drift within the same Playback System produces
  `.playbackSystemStateChanged`;
- only an exact identity/state match produces `.ready`.

This means a later A/B executor cannot use a snapshot as authority to restore,
replace, or otherwise mutate routing, crossover, speaker-correction, output,
room-correction, or other hardware/system state.

### Session semantics

`ContentABComparisonController` provides only temporary in-memory comparison
state:

- capture A;
- capture B;
- clear either or both;
- swap A/B labels;
- report current compatibility; and
- report whether current content differs from a captured slot.

A/B snapshots are deliberately **not persisted** across app launches.

### No live mutation in Slice 1

Slice 1 contains no A/B Apply/audition/switch method and does not call engine
mutation APIs from the A/B controller.

Live click-free switching is reserved for Slice 2 after this boundary is
regression-locked. Slice 2 must preserve the exact same Playback System
boundary and must not broaden A/B authority merely to support UI convenience.

---

## Regression coverage

`ProductionInformationArchitectureTests` verifies:

- the A/B payload contains only the four allowed content-domain fields;
- Audio Unit rack state survives A/B-state reconstruction unchanged;
- Playback System identity drift fails closed;
- Playback System state drift fails closed; and
- A/B slot identity/opposite mapping is stable.

PR113B's portable CI contract additionally rejects hardware-domain tokens or
live-audio mutation authority from the Slice 1 A/B implementation.

---

## Authority boundary

PR113B does **not** establish or imply:

- PR112 physical H01–H08 acceptance;
- release acceptance;
- live feed-forward ANC authorization;
- protected-driver physical commissioning;
- App Store signing/notarization; or
- permission to merge the stacked PRs.

PR113B, PR113, PR112A and all ancestors remain **OPEN, DRAFT and UNMERGED**
while the owner is away from the Mac/audio system. `main` remains unchanged.
