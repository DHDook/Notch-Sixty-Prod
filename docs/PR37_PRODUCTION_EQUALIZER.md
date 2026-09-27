# PR37 — Production Equalizer Workspace

## Purpose
Replace the production Equalizer placeholder introduced by PR36 with the shipping macOS 27 Equalizer workspace while preserving the accepted PR34/PR35 DSP and realtime architecture.

## Product contract
- The production UI is a client of the existing `AudioIOEngine` EQ state; it must not create a second EQ model.
- Dynamic EQ remains a property of an ordinary EQ band rather than a separate user-facing bank.
- Expose only domain / phase / filter combinations supported by the validated commercial DSP contract.
- Graph interaction must preserve click-safe/coalesced realtime graph publication.
- Engineering Validation remains available until production EQ parity is accepted.

## Initial layout
- Large logarithmic frequency-response graph as the workspace focal point.
- Channel-domain and phase-mode controls above the graph.
- Selected-band inspector plus band list below/alongside the graph.
- Add-band menu with supported filter types.
- Direct graph handles for frequency/gain manipulation where meaningful.
- Precise numeric editing for frequency, gain, Q, slope, and type-specific parameters.
- Per-band Dynamic toggle with contextual Dynamic controls.

## PR36 validation carried forward
The PR37 hardware build will also verify the final PR36 presentation refinements:
- consolidated stereo VU deck and centered branding;
- useful needle movement across the extended −30…+3 VU display range;
- VU ON/OFF CPU after view-state isolation;
- VU work parks when hidden/disabled;
- Active Crossover and Room Correction remain separate sidebar workspaces.

## Acceptance
- production Equalizer reaches functional parity with the currently validated EQ control plane;
- interactive edits are responsive and click-safe during playback;
- drag-time updates do not flood graph publication;
- retained PR34/35/36 validators remain green;
- arm64 Debug/Release builds and full XCTest pass on the exact closing head;
- focused hardware/UI validation accepted;
- handoff document regenerated after merge before PR38 starts.
