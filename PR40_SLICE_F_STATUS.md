# PR40 Slice F validation checkpoint

Slice F begins from the completed measurement, project, target, preview and minimum-phase FIR design workflow.

Deployment foundation:
- each generated design snapshots its contributing position IDs/weights, exact target curve and effective correction range;
- the sidecar retains the original unscaled FIR for reproducibility;
- deployment creates a deterministic copy of the FIR with the design's recommended safety headroom embedded directly in the room-owned filter taps;
- Content Preset headroom attenuation is never modified by Room Correction deployment;
- deployed filter metadata, sample rate and intentional latency are preserved while taps are scaled by `10^(-recommendedHeadroomDB / 20)`;
- the project controller derives the lightweight Playback System calibration summary from design provenance rather than current edited project state;
- ProductProfileController has a dedicated transactional room-correction replacement path that updates only the selected Playback System's room-correction configuration + calibration summary;
- profile persistence is available as a throwing operation for deployment rollback;
- if profile persistence fails after the engine accepted a filter, both the engine and in-memory Playback System profile are rolled back;
- enabled/bypassed room-correction state is persisted through the same narrow Playback System transaction rather than overwriting unrelated system settings;
- deployed FIR + summary remain embedded in `profiles-v1.json`, so already deployed playback does not depend on the room project sidecar being available.

Production UI:
- the selected generated design has an explicit Deploy action; generating/selecting/editing a candidate never changes daily playback implicitly;
- deployment uses the design's headroom-scaled `deploymentFilter()` plus its provenance-derived calibration summary through the transactional Playback System API;
- the Daily Playback enable/bypass toggle persists through the selected Playback System instead of mutating only live engine state;
- the Daily Playback card reads deployed filter + calibration metadata from the selected Playback System profile as the authoritative state;
- the deployed summary surfaces target, contributing-position count, effective correction range, embedded safety attenuation, measurement/design dates, and algorithm version;
- project edits or Content Preset changes cannot masquerade as a deployment change;
- the UI explicitly states that room-owned safety attenuation is embedded in the FIR and does not modify Content Preset preamp/headroom.

Deployment foundation and UI are green on both exact-head CI lanes.

Final software regression gate in this checkpoint adds direct coverage for:
- the dedicated room-correction convolution slot in Processed, latency-matched Reference, and Delta audition modes;
- raw Global Bypass overriding an attached room-correction FIR and Delta audition while retaining only the independent master-volume gain contract;
- room-correction FIR preparation remaining active for Processed/Reference/Delta, parking only during raw Global Bypass, and restoring after bypass exits;
- persistent room-correction enable/disable retaining the deployed FIR and calibration provenance while leaving Content Preset state unchanged;
- profile reload preserving the re-enabled deployed configuration and provenance.

This direct checkpoint exists so the normal PR workflows validate the exact regression-integrated tree rather than the preceding bot-authored helper commit.

If both exact-head CI lanes pass, PR40's automated software gate is complete. The remaining acceptance step is a focused real-Mac acoustic workflow check with actual output hardware and measurement microphone: capture Left/Right sweeps, retain multiple positions, design, deploy, audition Processed/Reference/Delta, exercise raw Global Bypass, restart the app, and confirm the Playback System restores the deployed correction independently of Content Preset selection.
