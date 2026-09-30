# PR40 Slice F validation checkpoint

Slice F begins from the completed measurement, project, target, preview and minimum-phase FIR design workflow.

Deployment foundation in this checkpoint:
- each generated design snapshots its contributing position IDs/weights, exact target curve and effective correction range;
- the sidecar retains the original unscaled FIR for reproducibility;
- deployment creates a deterministic copy of the FIR with the design's recommended safety headroom embedded directly in the room-owned filter taps;
- Content Preset headroom attenuation is never modified by Room Correction deployment;
- deployed filter metadata, sample rate and intentional latency are preserved while taps are scaled by `10^(-recommendedHeadroomDB / 20)`;
- the project controller can derive the lightweight Playback System calibration summary from design provenance rather than current edited project state;
- ProductProfileController now has a dedicated transactional room-correction replacement path that updates only the selected Playback System's room-correction configuration + calibration summary;
- profile persistence is now available as a throwing operation for deployment rollback;
- if profile persistence fails after the engine accepted a filter, both the engine and in-memory Playback System profile are rolled back;
- enabled/bypassed room-correction state can be persisted through the same narrow Playback System transaction rather than overwriting unrelated system settings;
- deployed FIR + summary remain embedded in `profiles-v1.json`, so already deployed playback does not depend on the room project sidecar being available.

Deterministic tests in this checkpoint cover:
- deployment tap normalization without mutating the reproducible design asset;
- source-position/effective-range provenance and calibration-summary generation;
- deployment changing only room-owned Playback System state while preserving Content Preset state;
- profile reload restoring a deployed FIR and metadata without requiring a sidecar project;
- forced profile-persistence failure rolling back both engine and profile state.

The first Hardware XCTest attempt reached the new test target and exposed only two optional-value assertion compile errors in the provenance test; production Slice F source compiled successfully. Those assertions now unwrap the optional effective-range values explicitly, and this checkpoint reruns the exact deployment foundation after that test-only correction.

After this exact tree is green, the next Slice F step is the explicit Deploy UI, persistent enable/bypass control, and Daily Playback calibration/design summary. The final PR40 gate remains Processed/Reference/Delta + raw Global Bypass regression coverage and focused real-Mac acoustic acceptance.
