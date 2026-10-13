# PR113B — World-Class Product Finish

Status: **IN PROGRESS — SLICES 1–6 IMPLEMENTED REMOTELY**

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
- imported binaural/HRTF profile assets; and
- portable app preferences: appearance, Dock/Menu Bar presence and volume-key
  resolution.

Launch at Login and macOS permission grants are intentionally excluded because
they are OS-level registration/consent decisions. Physical hardware-acceptance
campaigns are also excluded from the general product backup; their dedicated
acceptance packets remain the authoritative archival/export path.

### Integrity and restore transaction

The manifest records a SHA-256 digest and byte count for each canonical
sorted-key portable domain: profiles, Room Correction projects, Measurement
Lab sessions, binaural assets and preferences. Inspection and restore recompute
the complete manifest before any local state is changed.

Restore requires the audio engine to be idle. The full payload is decoded and
structurally validated before writes begin. Existing profile state,
colliding Room Correction projects, colliding Measurement Lab sessions and
colliding binaural assets are retained for rollback. Preferences are returned
to the UI only after product-data restore succeeds. If a later write fails,
new records are removed and retained records are restored.

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

The general `.n60backup` format does **not** contain hardware-acceptance
campaigns and has no acceptance-store dependency. PR112 acceptance evidence
continues to use its dedicated export packets and review workflow. A product
backup therefore cannot recreate, promote or authenticate physical acceptance
on another installation.

### Production Preferences

Preferences & Reference → General now includes **Backup & Restore** with
**Save Backup…** and **Restore Backup…**. Restore has an explicit confirmation
dialog describing replacement scope, hardware remapping and the reference-only
acceptance-evidence rule.


---

## Slice 4 — Full-fidelity Measurement Lab export

Slice 4 adds a detailed interoperability path alongside the existing compact
report export. The compact JSON/CSV contract is unchanged and continues to
exclude raw arrays.

### Full JSON

**Export Full JSON** serializes a versioned
\`SpeakerMeasurementLabFullFidelityExportEnvelope\` containing the complete
persisted Lab session. This preserves:

- every raw impulse-response sample;
- every transfer-function frequency / magnitude / optional phase bin;
- exact capture and protocol identities;
- repeat index and timestamps;
- Playback-System and routing signature;
- microphone identity and calibration;
- excitation level and measurement quality;
- protected-driver capture provenance; and
- shared-clock reference configuration/evidence where present.

The envelope explicitly persists \`measurementOnly=true\`,
\`canDeploy=false\`, \`containsRawImpulseData=true\` and
\`containsFullTransferFunctionData=true\`.

### Interoperability exports

The Lab can also export:

- **Transfer CSV** — one lossless row per capture/frequency bin, including phase
  in degrees when measured;
- **Impulse CSV** — one lossless row per capture/sample with exact sample index,
  time and amplitude;
- **Capture FRD** — a selected capture's transfer grid in FRD-compatible text;
  the header explicitly labels the magnitude domain as transfer-function dB,
  **not absolute SPL**; and
- **Impulse WAV** — a selected capture's raw impulse response as mono
  **32-bit IEEE-float WAV** at the capture's actual sample rate, including the
  non-PCM `fact` chunk for broad reader compatibility.

CSV and FRD numeric formatting is pinned to the POSIX decimal point for
locale-independent interoperability.

No averaging, smoothing or response compaction is introduced by the export
layer.

### Product UI and authority boundary

Analysis & Export now separates **Compact Report** from **Full-Fidelity Data**
so a user can choose between a human-sized report and the actual measurement
evidence.

Detailed export is read-only. It cannot mutate DSP, Apply a candidate, Deploy a
design, promote confidence, satisfy PR112 physical acceptance, or create
release authority.


---

## Slice 5 — Safe Launch / Recovery Mode

Slice 5 adds a machine-local recovery layer around the existing idle-by-default
audio lifecycle. It does not create a second audio engine and does not
automatically start processing.

### Recovery evidence and launch sentinel

\`ProductRecoveryController\` persists a versioned
\`recovery-state.json\` under Application Support / Notch Sixty / Recovery.
This state is intentionally machine-local and is **not** part of
\`.n60backup\`.

The record tracks:

- whether the previous launch session was closed cleanly;
- consecutive audio-start failures;
- consecutive plug-in preparation/build failures;
- the last failure kind, description and timestamp; and
- the profile snapshot from the most recent successful **normal** processing
  start.

Safe Launch is requested when the prior launch was unclean, when either
start-failure counter reaches two, or when the recovery record itself cannot be
trusted.

### Explicit recovery choices

When recovery evidence exists, the main window presents a non-dismissible
**Safe Launch** sheet while processing remains stopped. The user may choose:

- **Open Normally** — apply the currently saved selected Playback System and
  Content Preset, then continue normally;
- **Open with Plug-ins Bypassed This Launch** — apply the saved product layers
  but stage no Audio Unit runtime for this launch; the saved rack is not edited;
- **Restore Last Known Good** — transactionally restore the saved profile
  snapshot from the most recent successful normal start, then explicitly apply
  its selected layers; or
- **Copy Diagnostics** — copy the same shared diagnostic report used by
  Preferences & Reference, including recovery state.

Restore Last Known Good rolls profile persistence back to the pre-recovery
snapshot if selected-layer application fails. It also refuses to complete if
any restored Playback System references unavailable hardware; the user must
reconnect or remap that hardware rather than accepting a silent substitute.

### Last-known-good authority

A successful normal start records the current saved product-profile snapshot as
Last Known Good and resets failure counters. A start with plug-ins bypassed, or
with an enabled active-rack Audio Unit component quarantined, may prove the core
audio path works but **cannot overwrite Last Known Good**. Quarantined
components that are unrelated to the enabled active rack do not block a healthy
configuration from becoming Last Known Good.

The plug-in-bypassed choice is transient for the current launch and is never
persisted as a saved rack edit or next-launch preference. If the recovery record
itself is unreadable, Safe Launch fails closed and retains the original read
error in diagnostics even after writing a clean replacement record.

Recovery bookkeeping failures are diagnostic only; they do not turn an
otherwise successful audio start into a playback failure.

### Unified processing start

All production Start controls now route through
\`ProductController.startProcessing()\`. The main toolbar no longer calls
\`AudioIOEngine.start()\` directly, so Audio Unit preparation, quarantine,
recovery accounting and safe-launch gating cannot be bypassed by choosing a
different UI surface.

An engine left in \`.failed\` after a start attempt is normalized back to idle
before an explicit recovery action or retry.

### Authority boundary

Recovery state contains no physical-acceptance, release, merge or live
feed-forward ANC authority. A machine-local recovery record cannot satisfy
PR112 evidence requirements or promote the stacked PRs.

---

## Slice 6 — Headroom Assistant

Slice 6 adds an advisory gain-structure assistant on **Meters & Analysis →
Dynamics**. It consumes existing protection telemetry and introduces no new
realtime DSP stage, detector or automatic gain loop.

### Observation evidence

The assistant observes a representative loud program passage while processing
is running. A recommendation requires at least **10 seconds** and 10 valid
true-peak samples; **30 seconds** is recommended in the UI.

The evidence model retains:

- measured protection-input true peak;
- a reconstructed **pre-Gain-Rider true peak** by adding the current Gain Rider
  attenuation back to the detector reading;
- protection-output true peak;
- peak and sustained limiter gain reduction;
- the maximum Gain Rider attenuation;
- the delta of cumulative limiter safety-clamp samples; and
- confirmation that the authoritative limiter **True Peak Guard** was active.

The default target is **−1.0 dBTP**, adjustable from −6.0 to −0.5 dBTP.

### Conservative recommendation

The assistant can recommend **additional** Headroom Attenuation only. It never
reclaims or reduces attenuation from a finite observation.

The recommendation compares two independent indicators of missing reserve:

1. pre-rider true peak above the selected target; and
2. sustained limiter gain reduction above a 0.5 dB tolerance.

Because those indicators describe the same underlying reserve deficit, the
assistant uses the larger value rather than summing them. If the limiter's
final safety clamp fired during the observation, it adds a further 0.5 dB
reserve. The result is rounded upward to 0.1 dB and bounded by the existing
−48...0 dB Headroom Attenuation range.

If the required reserve exceeds that range, the result is explicitly marked
**range limited** rather than reported as fully solved.

### State boundary and Apply

Every observation pins the selected Content Preset identity, selected Playback
System identity and their exact current states. Content or system drift
invalidates the observation and requires a new one.

Headroom Assistant is also isolated from live A/B audition. It refuses to start
while an A/B session is open and invalidates an observation if A/B begins
mid-run, so temporary loudness-match attenuation cannot contaminate static
headroom evidence.

Apply is always explicit. `HeadroomAssistantController.applyRecommendation()`
is the only assistant mutation path and calls the existing
`AudioIOEngine.transitionHeadroomAttenuationDB` silent-boundary graph
transition. No background auto-adjustment is permitted.

For immutable semantic N-channel / virtual-speaker transports, the existing
restart-required transport rule remains authoritative; the assistant does not
bypass it.

Applying a recommendation changes the **live content state only**. It does not
silently overwrite the selected Content Preset. The user keeps normal preset
save/update authority.

### Product UI

The Headroom Assistant card shows:

- observation progress;
- target true peak;
- current → recommended Headroom Attenuation;
- reconstructed pre-rider true peak;
- sustained and peak limiter reduction;
- safety-clamp count;
- explanation of insufficient/sufficient/range-limited evidence; and
- explicit Observe / Stop & Review / Apply / Clear controls.

The UI states that short observations cannot prove worst-case program headroom
and that the assistant never removes existing headroom.

### Authority boundary

Headroom Assistant evidence is program/gain-structure guidance only. It is not
hardware acceptance, speaker-safety acceptance, release acceptance or
permission to merge the stacked PRs.


---

## Regression coverage

`ProductionInformationArchitectureTests` verifies:

- level matching attenuates only the louder measured capture;
- level matching is bounded and rejects missing/invalid low-level evidence;
- captured LUFS metadata does not broaden the four-field safe audition payload;
- unavailable imported hardware produces a persisted Needs Mapping gate;
- known hardware can remain eligible without a remapping gate;
- only the safe application-preference keys round-trip; and
- backup inspection rejects domain tampering when a SHA-256 manifest entry no
  longer matches;
- full Lab JSON round-trips the complete raw session while retaining
  measurement-only/no-deploy flags;
- transfer and impulse CSV retain the raw grids/samples;
- FRD preserves measured phase and labels transfer-function dB honestly; and
- WAV export is mono 32-bit IEEE float at the capture sample rate;
- unclean launches and clean termination are distinguished persistently;
- repeated audio and plug-in failures trigger Safe Launch independently;
- bypassed or active-rack-quarantined plug-in starts cannot overwrite Last
  Known Good;
- unavailable Last Known Good hardware fails closed instead of silently
  rebinding;
- unreadable machine-local recovery state forces Safe Launch and preserves the
  read error in diagnostics;
- plug-in bypass is transient across a clean relaunch; and
- recovery state carries no physical/release/merge authority;

- Gain Rider attenuation is reconstructed into the pre-rider true-peak estimate;
- existing Headroom Attenuation is never reclaimed from a finite observation;
- peak/limiter reserve uses the larger need plus explicit safety-clamp reserve;
- insufficient or non-authoritative observations cannot produce an applicable recommendation;
- the −48 dB range limit fails conservatively and is reported explicitly; and
- Content/Playback state drift invalidates Headroom Assistant evidence;

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
