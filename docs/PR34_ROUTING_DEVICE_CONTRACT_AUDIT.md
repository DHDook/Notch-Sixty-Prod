# PR34 Legacy Routing / Device Contract Audit

Status: **SOURCE/TEST AUDIT CONTINUATION — supplements `PR34_LEGACY_SOURCE_PARITY_AUDIT.md`.**

This audit separates current stereo-device behavior from legacy capabilities that only become meaningful once the commercial Active Crossover / physical multi-output graph exists.

## 1. Current commercial stereo device lifecycle already covers the core single-output contract

The commercial rewrite already has a first-party stereo output lifecycle with:

- output-device enumeration and explicit selected-output UID,
- startup state-machine coverage through output open/start/run,
- sample-rate change monitoring and transport rebuild,
- selected-output disappearance recovery,
- selected-output return/recovery,
- master-volume capability inspection and synchronization,
- device volume/mute writes when the selected device exposes them,
- software-gain fallback when hardware volume is unavailable,
- external volume-state propagation back into the app,
- deterministic lifecycle/recovery tests.

The commercial tests also explicitly exercise startup/reconfiguration/recovery state-machine paths and unity DSP behavior through 384 kHz.

**Classification: IMPLEMENTED / IMPROVED for the current single physical stereo output scope.**

The legacy driver-specific orchestration is not itself a parity requirement where the commercial capture/output architecture provides the same observable end-user behavior through a clean first-party implementation.

---

## 2. Automatic vs Manual legacy routing is partly architectural, partly product behavior

Legacy routing had two orchestration modes:

- **Automatic**: follow macOS/default-device behavior, maintain the legacy capture driver as the system default, pre-synchronize volume, synchronize driver/output sample rate, and recover from output changes.
- **Manual**: use user-selected devices and suppress automatic output switching/replacement policies.

Several details are tightly coupled to the retired legacy virtual-driver architecture and therefore should not be copied mechanically into the commercial app.

The user-observable behaviors that remain relevant are:

- explicit output selection,
- stable selected-device identity by UID,
- predictable response to default-device changes,
- graceful missing-device recovery,
- no surprise automatic switching when the user has explicitly pinned a device,
- sample-rate change recovery,
- volume/mute synchronization.

The commercial stereo engine already covers most of those primitives. Final production UI policy for “follow system output” vs “pin this output” can be expressed independently without reproducing the old driver choreography.

**Classification: IMPLEMENTED / IMPROVED foundation; final route-selection policy belongs to production UI/persistence.**

Headphone plug-specific auto-switch policy is **OUT OF CURRENT PRODUCT SCOPE** because the commercial product is speaker-focused and headphone-only behavior was explicitly excluded from the rewrite.

---

## 3. Explicit legacy SRC is a real capability

Legacy source contains an audio-thread SRC processor used for arbitrary rate conversion up to 384 kHz and for continuously variable fractional rate correction. Its observable responsibilities include:

- conversion when input/output rates differ materially,
- transparent same-rate pass-through,
- stereo processing,
- bounded preallocated realtime storage,
- support for continuous small rate correction without resetting filter/delay state,
- operation through rate pairs up to 384 kHz.

This capability is not currently needed merely to drive one selected commercial stereo output, because the commercial transport graph negotiates/rebuilds around the selected device's hardware format.

**Classification: LATER MILESTONE — physical multi-device output / Active Crossover Matrix.**

If explicit commercial SRC is required there, it should be independently designed and benchmarked; the legacy polyphase implementation is evidence of behavior, not an implementation source.

---

## 4. Multi-device synchronisation has two confirmed reachable modes

Legacy `OutputDeviceRouter` exposes two real routing modes whenever enabled matrix channels target more than one physical device:

### Aggregate Device

- CoreAudio aggregate device combines physical devices into one logical multi-channel output.
- user can select an explicit clock-master UID,
- if the selected master is no longer an enabled target, channel 0's physical device is the fallback master,
- aggregate lifetime is tied to routing lifetime/reconfiguration,
- slave paths can carry additional CoreAudio SRC latency and therefore require per-output latency/alignment awareness.

### Software PLL

- user can select an explicit primary physical device,
- every secondary physical device gets its own output writer and clock loop,
- channels on one physical secondary share that device's clock correction,
- the primary render callback feeds per-secondary ring buffers,
- each secondary AUHAL callback drains its own physical output,
- the clock loop continuously nudges SRC rate without resetting SRC state,
- UI-observable lock/drift state exists.

This is confirmed executable routing infrastructure, not a dormant enum.

**Classification: LATER MILESTONE — Active Crossover Matrix / physical multi-device routing.**

The current commercial stereo product must not grow Aggregate/PLL complexity before it has multiple independently routed physical outputs. Once that milestone begins, both modes should be treated as legacy-parity requirements unless the product explicitly elects a single superior synchronization strategy and proves it covers the same user workflows.

---

## 5. Software PLL observable contract

The legacy software clock loop establishes a behavioral envelope rather than an implementation mandate:

- one synchronization loop per secondary physical device,
- default loop bandwidth approximately 0.5 Hz,
- default damping approximately 0.707,
- correction bounded to approximately ±200 ppm,
- startup lock-in period before active correction,
- correction factor centered at 1.0,
- drift telemetry in ppm,
- lock indication when residual drift is sufficiently small,
- rate nudging does not clear SRC phase/history.

**Classification: LATER MILESTONE acceptance contract.**

A new implementation may use a different estimator/controller if it is at least as stable, realtime-safe and phase-accurate.

---

## 6. Aggregate-device observable contract

Legacy aggregate-device behavior establishes:

- only enabled matrix target devices participate,
- unique physical devices are combined once each,
- one user-selectable clock master,
- sequential physical channel map across member devices,
- private aggregate lifetime owned by the app,
- aggregate is destroyed when no longer needed,
- slave-device latency must be exposed/compensated rather than assumed equal to the master path.

**Classification: LATER MILESTONE acceptance contract.**

The legacy helper used a coarse fallback latency estimate in one path; that estimate itself is not a parity target. The commercial version should query/measure actual transport latency robustly.

---

## 7. Device disappearance / reconnection contract

Legacy device orchestration tracks selected-output disappearance and has history-aware replacement behavior. The commercial rewrite already has an explicit `recoveringOutput` lifecycle state and rebuilds transport when the selected output returns.

For the speaker-focused commercial product, the stronger behavior is:

- preserve the user's selected output UID when it temporarily disappears,
- stop/fade safely rather than silently sending processed audio to an arbitrary replacement,
- recover automatically when the selected device returns,
- allow an explicit user route change to choose a different device.

This is safer and more deterministic than blindly reproducing the legacy history/fallback switch policy.

**Classification: IMPLEMENTED / IMPROVED for current stereo scope.**

When multi-output routing arrives, the same principle must extend per physical target: report missing matrix targets clearly and do not silently remap speaker/driver channels onto unrelated hardware.

---

## 8. Sample-rate change contract

Legacy routing listens to physical output sample-rate changes and rebuilds/re-synchronizes its route. The commercial engine likewise monitors the selected output's rate and rebuilds its transport/graph through an explicit reconfiguration state.

**Classification: IMPLEMENTED / IMPROVED for current stereo scope.**

Later multi-device routing must additionally define what happens when member devices expose incompatible supported rates and whether the selected synchronization mode can resolve that mismatch.

---

## 9. Volume and mute synchronization

The legacy app synchronized physical-output volume with its capture/driver route and listened for external device changes. The commercial rewrite has a cleaner capability-driven model:

- inspect whether device volume/mute are available,
- write hardware volume/mute when supported,
- otherwise retain software gain,
- monitor the selected device and reflect external changes in UI state.

**Classification: IMPLEMENTED / IMPROVED.**

This resolves the old master-volume synchronization parity concern at the architecture level; production UI acceptance still needs direct hardware testing across controllable and fixed-volume DACs.

---

# 10. PR34 routing/device disposition

Current stereo scope:

- output enumeration/selection -> **IMPLEMENTED / IMPROVED**
- sample-rate-change rebuild -> **IMPLEMENTED / IMPROVED**
- selected-output loss/recovery -> **IMPLEMENTED / IMPROVED**
- volume/mute synchronization + software fallback -> **IMPLEMENTED / IMPROVED**
- legacy headphone auto-switch policy -> **OUT OF CURRENT PRODUCT SCOPE**
- “follow system” vs explicitly pinned output UI policy -> **production UI/persistence follow-up**, not a DSP blocker

Physical multi-output scope:

- output-channel/device matrix -> **LATER MILESTONE: Active Crossover Matrix**
- Aggregate Device synchronization -> **LATER MILESTONE**
- Software PLL synchronization -> **LATER MILESTONE**
- explicit arbitrary/fractional SRC -> **LATER MILESTONE**
- per-device lock/drift/latency telemetry -> **LATER MILESTONE**
- missing-device behavior per output target -> **LATER MILESTONE**

No current stereo DSP implementation is missing merely because the commercial app does not yet instantiate multi-device synchronization infrastructure. Optimization may treat the current stereo transport as the baseline, while reserving explicit extension points for the later output-matrix graph.
