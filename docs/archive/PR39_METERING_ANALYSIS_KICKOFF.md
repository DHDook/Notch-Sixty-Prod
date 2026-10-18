# PR39 — Production Meters / RTA / Analysis kickoff

## Anchor

PR39 starts from the PR38 squash-merge anchor:

`4036ac341d86b0e62f437efbadb48c09df46d581`

PR38 exact substantive source accepted on hardware/UI before merge:

`9d92223e49fcba4d5208996bcfeda0961375fb15`

The PR38 full macOS workflow and Hardware Test DMG workflow both passed on that exact source before merge.

## Goal

Replace the production **Meters** placeholder with a shipping metering and analysis workspace while preserving the accepted realtime behavior, the PR35 strict demand/parking contract, and the PR36 lightweight Dashboard-VU isolation.

PR39 is a product-surface and analysis milestone. It must not make hidden analysis a permanent render cost.

## Existing commercial baseline

The commercial engine already provides:

- input, post-EQ, and DSP-output stereo peak readings;
- input, post-EQ, and DSP-output stereo RMS readings;
- cumulative over-range sample counts at those three points;
- authoritative input/output true-peak telemetry from protection;
- compressor, expander, Pause Gate, De-Esser, multiband, limiter, Gain Rider, loudness, dialogue, denoiser, and mains telemetry through render diagnostics;
- a full render-kernel metering demand switch;
- a separate output-only Dashboard VU demand path.

The Dashboard VU path remains independent. PR39 must not turn the full detailed-meter stack on merely because the Dashboard VUs are visible.

## Verified observable behavior to preserve or improve

The clean-room behavior audits establish these product requirements without reusing historical DSP implementation:

### Level meters

- display scale: -60 to 0 dBFS;
- principal marks at 0, -3, -6, -12, -18, -24, -30, -36, -48, and -60 dBFS;
- peak and RMS must be mathematically honest and explicitly labeled;
- peak hold approximately one second;
- clipping/over-range indication approximately 0.5 second hold;
- presentation cadence up to approximately 60 Hz is acceptable;
- meter work must be demand-gated and must stop when no visible consumer requires it.

### Spectrum / RTA

- simultaneous Input and Output spectrum comparison is required;
- useful display range is approximately -80 to 0 dBFS;
- silence must settle near the floor;
- a full-scale 1 kHz sine should land within a few dB of 0 dBFS in the corresponding analysis band;
- peak hold and bounded decay behavior are required;
- analysis must remain finite and stable at 44.1, 48, 88.2, 96, 176.4, 192, 352.8, and 384 kHz;
- exact historical FFT sizes or internal multi-lane implementation are not parity requirements.

### Stereo analysis

- phase correlation range: -1 to +1;
- +1 = in phase, 0 = uncorrelated, -1 = anti-phase;
- correlation must identify its signal location and averaging behavior;
- goniometer semantics use the standard 45-degree stereo rotation and bounded recent history;
- exact historical phosphor styling is not a parity requirement.

### Gain / protection analysis

- expose useful stage reduction/attenuation telemetry where it already exists;
- true peak must use the authoritative commercial protection estimator rather than a second conflicting implementation;
- do not reproduce the historical misleading "ISP" label that was driven by ordinary sample peak;
- do not reproduce the historical fake 24-bit "Bit Stream" visualization;
- do not label a simple peak/RMS ratio as a formal "DR Factor" standard.

### Processing information

If nominal transport information is shown, label it honestly as processing format / PCM data rate rather than source-media bit rate.

## Production information architecture

The first production layout will use four clear analysis pages inside the Meters workspace:

1. **Levels**
   - Input / Post-EQ / Output stereo Peak + RMS
   - over-range state
   - output True Peak
   - compact processing latency / sample-rate context where useful

2. **Spectrum**
   - dual Input / Output RTA on one frequency axis
   - independent trace visibility
   - peak-hold / reset controls
   - analyzer runs only while this surface is visible and enabled

3. **Stereo**
   - output phase correlation
   - output goniometer
   - clearly identified signal location
   - bounded history only while visible and enabled

4. **Dynamics**
   - gain-structure / attenuation overview using the already-validated render telemetry
   - compressor, expander, De-Esser, multiband, limiter, Gain Rider, and other meaningful active-stage indicators
   - loudness / dialogue status where it improves diagnosis without duplicating the Dynamics editor

Primary controls stay visible. No essential analysis control will be hidden behind a generic settings menu.

## Demand architecture

PR39 will preserve the PR35 rule that user-visible OFF or hidden work must park.

Demand will be split by actual consumer rather than one global "analysis on" switch:

- **Level demand** enables the existing render-kernel input/post-EQ/output meter accumulation only while a detailed level consumer is visible.
- **Spectrum demand** captures only the bounded audio data required for the visible Input/Output spectrum and performs FFT analysis off the realtime callback.
- **Stereo demand** captures only the bounded output stereo data required for correlation/goniometer analysis.
- **Dashboard VU demand** remains its existing separate output-only bridge path.

Realtime capture must remain fixed/preallocated, lock-free, logging-free, and bounded. FFT/windowing/display preparation must not be introduced into the physical-output callback.

## Signal-location contract

For PR39:

- **Input** = the established render-kernel Input meter point;
- **Post-EQ** = the established render-kernel Post-EQ meter point;
- **Output** = the established final DSP Output meter point;
- **Spectrum Input** uses the matching commercial input signal location;
- **Spectrum Output**, phase correlation, and goniometer use the matching final DSP output location.

If implementation discovery shows a signal location cannot be captured without violating the established audition/bypass graph semantics, stop and document the discrepancy rather than silently changing the label.

## Implementation slices

### Slice 1 — production Levels / Dynamics / processing information

- replace the placeholder with the real production workspace shell;
- expose existing diagnostics without adding a second telemetry state model;
- introduce scoped/reference-counted full-meter demand for visible detailed meter consumers;
- preserve Dashboard VU independence;
- add UI/contract guards.

### Slice 2 — realtime-safe analysis capture

- add bounded preallocated Input/Output analysis capture to the commercial realtime bridge;
- expose explicit demand bits / counters rather than unconditional sample copying;
- make hidden Spectrum/Stereo capture park completely;
- add deterministic capture/demand tests.

### Slice 3 — RTA and stereo analyzers

- independently authored commercial RTA implementation using the verified observable contract;
- phase correlation and goniometer derived from the commercial output capture;
- off-callback FFT / analyzer work;
- high-rate validity through 384 kHz;
- deterministic synthetic-signal tests.

### Slice 4 — production polish and hardware acceptance

- exact-head Debug / Release builds and full XCTest;
- retained PR34/35/36/37/38 validators;
- hardware/UI pass with audio playing;
- CPU comparison with Meters hidden vs Levels vs Spectrum vs Stereo;
- confirm Dashboard VUs remain independently parked when disabled/not visible.

## Acceptance

PR39 is complete only when:

- the production Meters workspace covers the verified current-stereo meter/RTA/analytics behavior that remains product-relevant;
- misleading historical analytics are omitted or relabeled rather than reproduced;
- Input / Post-EQ / Output level locations are explicit and correct;
- dual Input/Output spectrum is stable through 384 kHz;
- phase correlation and goniometer are correct and bounded;
- true peak shares the existing authoritative protection telemetry;
- hidden/off analyzers and their capture/FFT work are parked;
- Dashboard VUs remain isolated from the detailed-meter pipeline;
- no realtime allocation, locks, logging, UI/device/file access, or FFT design work is introduced into the callback;
- retained validators, exact-head arm64 Debug/Release builds, and XCTest are green;
- focused hardware/UI/CPU validation is accepted.

## Clean-room note

Legacy UI/configuration/docs may be consulted only to establish observable product behavior, labels, ranges, defaults, and semantics. Historical DSP implementation and historical tests are not implementation templates for the commercial analyzers.
