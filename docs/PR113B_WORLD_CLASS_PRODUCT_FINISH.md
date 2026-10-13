# PR113B — World-Class Product Finish

Status: **IN PROGRESS — SLICES 1–3 IMPLEMENTED REMOTELY**

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

## Slice 2 — Click-free, measured-level A/B audition

Slice 2 adds live audition without broadening Slice 1's authority.

### Atomic click-free transition

\`AudioIOEngine.transitionContentAuditionState\` constructs one complete
candidate DSP graph from the A/B-safe content payload while reusing the current
Playback-System-owned bass management, Room Correction, Speaker IR, output
gain, routing and Audio Unit latency.

The candidate is published through the existing
\`CoreAudioTransportSession.transitionDSPGraph\` path. That path performs the
production 8 ms sample-domain fade to a silent boundary, atomically publishes
the newest complete graph, then fades back up. A/B therefore does not perform
three independent EQ/dynamics/gain mutations and does not introduce an
instantaneous coefficient discontinuity.

Linear-phase/FIR EQ candidates prepare an inactive FIR program before the
transition. UI switching remains locked for 25 ms so repeated A/B clicks cannot
race the in-flight FIR program ownership window.

Semantic N-channel / Virtual Speaker transports retain their existing immutable
live-configuration rule. A/B cannot use this feature to bypass a
restart-required transport contract.

### Measured level matching

Each A/B capture may retain the already-available 3-second K-weighted
short-term LUFS telemetry when:

- audio is running;
- the reading is finite; and
- signal is above the existing -60 LUFS measurement gate.

Level matching becomes available only when both A and B have valid captured
references.

The match is deliberately attenuation-only:

- the quieter measured side becomes the reference;
- only the louder side is attenuated;
- neither side is ever boosted;
- correction is bounded to 12 dB; and
- the adjustment is temporary and is not written into the captured snapshot.

Because the two readings are captured at different moments, the UI explicitly
instructs the user to capture A and B during the same program passage when
measured matching is desired. It is an audition aid, not an EBU loudness
certification.

### Session restore

The first live audition retains the exact pre-A/B content state and the current
Playback System boundary. **Exit A/B and Restore** transitions back to that
content state only if the same Playback System identity and exact system state
are still present.

If the Playback System changed during comparison, restoration fails closed
rather than mutating system state to recreate the old environment.

### Production UI

The production profile toolbar now contains:

- an **A/B** management menu;
- **Capture Current as A**;
- **Capture Current as B**;
- direct **A** and **B** audition buttons;
- optional **Measured Level Match**;
- measured attenuation readout when available;
- **Swap A / B**;
- **Exit A/B and Restore**; and
- **Clear A/B**.

Capture is disabled during an active audition session so temporary
level-matching attenuation cannot accidentally become a new source snapshot.


---

## Slice 3 — Full Notch Sixty backup & restore

Slice 3 adds a versioned \`.n60backup\` bundle for disaster recovery and
Mac-to-Mac migration without turning a file import into hardware authority.

### Bundle contents

The bundle is human-inspectable JSON with a schema-versioned manifest and
payload. It includes:

- Content Presets, including Audio Unit rack configuration references;
- Playback Systems and their DSP/calibration state;
- Room Correction projects, including captured measurements and designs;
- Advanced Speaker Measurement Lab sessions;
- safe app preferences: appearance, Dock/Menu Bar presence and volume-key
  resolution; and
- hardware-acceptance campaigns as **reference-only evidence**.

Launch at Login is intentionally excluded because it is an OS-level
registration/consent decision.

### Integrity and restore transaction

The manifest records a SHA-256 digest of the canonical sorted-key payload.
Inspection and restore recompute that digest before any local state is changed.

Restore requires the audio engine to be idle. The full payload is decoded and
structurally validated before writes begin. Existing profile state,
preferences, colliding Room Correction projects and colliding Measurement Lab
sessions are retained for rollback. If a later write fails, new records are
removed and retained records are restored.

### Hardware portability

A restored Playback System retains its DSP, crossover, alignment, correction
and calibration data. Notch Sixty never guesses that a different Core Audio
device is equivalent to an imported stable UID.

Every device UID referenced by the restored system is compared with currently
available outputs. A system with unavailable bindings is persisted as
**Needs Mapping**:

- it may be selected for inspection;
- its imported hardware-domain state is not activated;
- automatic startup restore cannot activate it; and
- the production Playback System menu exposes the Needs Mapping status until
  the user reviews/remaps the hardware.

### Acceptance authority

Hardware-acceptance campaigns are included in a backup so the user's records
are not lost. They are deliberately **not written into the live acceptance
store during restore**. A backup therefore cannot recreate, promote or
authenticate PR112 physical acceptance on another installation.

### Production Preferences

Preferences & Reference → General now includes **Backup & Restore** with
**Save Backup…** and **Restore Backup…**. Restore has an explicit confirmation
dialog describing replacement scope, hardware remapping and the reference-only
acceptance-evidence rule.


---

## Regression coverage

`ProductionInformationArchitectureTests` verifies:

- level matching attenuates only the louder measured capture;
- level matching is bounded and rejects missing/invalid low-level evidence;
- captured LUFS metadata does not broaden the four-field safe audition payload;
- unavailable imported hardware produces a persisted Needs Mapping gate;
- known hardware can remain eligible without a remapping gate;
- only the safe application-preference keys round-trip; and
- backup inspection rejects payload tampering when the SHA-256 digest changes;

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
