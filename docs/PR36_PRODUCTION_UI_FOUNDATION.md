# PR36 Production UI Foundation

Status: IN PROGRESS

## Purpose

PR36 begins the transition from the engineering-validation shell to the shipping Notch Sixty interface. It establishes the production information architecture, macOS 27 visual language, signature VU presentation, and performance-aware meter lifecycle without changing accepted DSP behavior.

## Product requirements

1. Target macOS 27 and current SwiftUI APIs.
2. Use the current Liquid Glass design language intentionally rather than reproducing the historical app shell.
3. Keep the stereo analog VU meters as a signature focal point of the main interface.
4. Keep Room Correction and Active Crossover off the main dashboard in a dedicated Speaker Setup section.
5. Preserve engineering-validation surfaces during the production-UI migration instead of deleting them prematurely.
6. After PR36 merges, update the project handoff document before beginning the next PR.

## Clean-room / provenance

The production UI is a new implementation. The historical GPL Notch Sixty / Equaliser source is not a coding or layout reference for this work.

The VU meters are implemented from the owner-specified product requirement that stereo analog VUs are a signature element. PR36 does not copy historical VU source expression, assets, geometry, or resources. The new VU component is drawn in SwiftUI from first principles and is driven by the current clean-room metering diagnostics.

Public design/API source of truth:
- Apple SwiftUI `Glass`, `glassEffect`, `GlassEffectContainer`, and glass button APIs.
- Apple macOS/SwiftUI guidance that Liquid Glass belongs primarily in the navigation/control layer and should be used selectively in static content.

## Information architecture

### Dashboard

The production landing page is intentionally focused rather than exposing every DSP control at once.

Primary hierarchy:
1. Stereo VU deck — largest visual element and signature identity.
2. Transport/output state — selected physical output, sample rate, processing state.
3. Master volume / mute.
4. Compact EQ and Dynamics summaries with navigation into their editors.

Room Correction and Active Crossover do not appear as dashboard control panels.

### Equalizer

Dedicated production editor for static/dynamic EQ, phase mode and channel domain. PR36 establishes the route and summary surface; detailed production editing is allowed to land in a focused follow-up PR.

### Dynamics

Dedicated production editor for compressor/expander/gate/protection/noise tools. PR36 establishes the route and summary surface; dense editing remains a focused follow-up.

### Speaker Setup

Dedicated speaker-system section containing:
- Active Crossover / bass management;
- Room Correction;
- later speaker/IR and alignment workflows where they belong conceptually.

The purpose is to keep system-calibration workflows separate from day-to-day playback controls.

### Audio

Output-device selection, processing transport state, sample-rate/status information and app-level audio configuration.

## Liquid Glass rules

- Use native `NavigationSplitView`, toolbar and system controls so macOS 27 supplies platform-correct Liquid Glass automatically.
- Use custom `GlassEffectContainer` / `glassEffect` only for compact control clusters that float above content.
- Do not put glass behind every content card or meter face.
- Prefer semantic system colors for the application shell; the VU face may use a deliberate warm instrument treatment as a product identity element.
- Use glass button styles for custom floating actions rather than applying raw glass behind a normal button.

## VU contract

The Dashboard uses two large analog meters, Left and Right.

Initial signal source:
- output RMS drives the mechanical-style needle;
- output peak is available as a supporting numeric readout;
- 0 VU is initially referenced to -18 dBFS for display mapping;
- the display range is -20 VU through +3 VU;
- UI-side ballistics smooth the diagnostic samples so the needle behaves like an instrument rather than a sample-peak meter.

This mapping is a UI presentation contract, not a change to DSP gain staging.

## Meter performance contract

PR35 established that user-visible analysis must be explicitly gated. PR36 preserves that rule:

- graph metering defaults OFF;
- entering a visible, running Dashboard enables the meter gate;
- leaving Dashboard or stopping transport disables it;
- one production meter loop polls a compact diagnostics snapshot;
- no hidden production page owns an independent high-frequency timer;
- the validation-shell polling loops remain separate from the production UI and are not used as the production meter source.

The initial production meter cadence is bounded to approximately 30 Hz and exists only while the Dashboard is visible and transport is running. It is subject to production profiling once the UI workload is representative.

## Engineering validation access

The existing Main/PR27/PR28/PR30/PR31 validation tabs remain available in a separate `Engineering Validation` window during the UI migration. The shipping window no longer presents those tabs as its primary navigation.

## PR36 acceptance

- macOS deployment target is 27.0;
- production window uses the new navigation shell;
- Dashboard contains the new clean-room stereo VU deck as its focal point;
- VUs are fed by explicitly gated current-engine metering rather than synthetic animation;
- start/stop, output selection, volume and mute are available from production surfaces;
- Room Correction and Active Crossover are contained in Speaker Setup;
- engineering validation remains reachable in a separate window;
- no DSP algorithm or accepted sonic behavior changes;
- Debug build, Release build and XCTest remain green;
- hardware smoke test confirms UI responsiveness, meter behavior and no new audio dropouts;
- handoff document is updated after merge.
