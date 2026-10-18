# PR39 production analysis UI status

The first complete production Meters / RTA / Analysis surface is now integrated.

## Pages

- **Levels** — Input / Post-EQ / Output stereo Peak + RMS, over-range counts, authoritative Input and Output True Peak, and processing sample-rate / latency context.
- **Spectrum** — simultaneous Input / Output 96-band logarithmic RTA, trace visibility controls, approximately one-second peak hold, and explicit reset.
- **Stereo** — normalized Output phase correlation plus a bounded-history 45-degree goniometer.
- **Dynamics** — existing authoritative gain-reduction / attenuation, loudness, dialogue, denoiser, and protection telemetry without enabling the detailed level-meter accumulator.

## Demand behavior

- Levels acquires the existing full render-meter demand only while its production page is visible and processing is running.
- Spectrum requests only `N60_ANALYSIS_DEMAND_SPECTRUM` while visible.
- Stereo requests only `N60_ANALYSIS_DEMAND_STEREO` while visible.
- Leaving Spectrum or Stereo explicitly clears analysis demand.
- The Dashboard signature VUs remain on their existing separate output-only bridge path.
- The Spectrum and Stereo SwiftUI views render immutable worker snapshots; they do not drain realtime capture themselves.

## Signal semantics

- Spectrum Input uses the established raw render-input signal location.
- Spectrum Output, phase correlation, and goniometer use the established final DSP-output location before the bridge startup/transition fade.
- True Peak continues to use the existing protection estimator rather than a second conflicting implementation.

The next gate is the normal exact-head macOS build / Release build / XCTest suite, followed by focused production hardware/UI/CPU validation.
