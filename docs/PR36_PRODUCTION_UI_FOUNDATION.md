# PR36 Production UI Foundation

Status: IMPLEMENTATION COMPLETE — awaiting exact-head CI and hardware UI/audio smoke test

## Purpose

PR36 transitions Notch Sixty from the engineering-validation shell to the first shipping macOS 27 interface. It establishes the production information architecture, Liquid Glass visual language, signature VU presentation, and performance-aware meter lifecycle without changing accepted DSP behavior.

## Product requirements

1. Target macOS 27 and current SwiftUI APIs.
2. Use the current Liquid Glass design language intentionally rather than reproducing the historical app shell.
3. Keep the stereo analog VU meters as a signature focal point of the main interface.
4. Keep Room Correction and Active Crossover off the main dashboard in a dedicated Speaker Setup section.
5. Preserve engineering-validation surfaces during the production-UI migration instead of deleting them prematurely.
6. Treat expensive meters/analyzers as explicit user-requested work and park them when disabled or hidden.
7. After PR36 merges, update the project handoff document before beginning the next PR.

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
2. Physical output selection, sample rate, processing state, and output refresh.
3. Master volume / mute and global DSP state.
4. Compact read-only EQ, Dynamics, and Speaker Setup summaries.

The persistent sidebar is the authoritative navigation mechanism. Dashboard summary cards therefore do not duplicate it with `Open` jump buttons.

The former minimal Audio route has been removed. Its useful day-to-day controls belong on Dashboard: physical output selection and refresh are directly available there, while start/stop remains in the always-visible toolbar and sample-rate/processing state remain visible in the dashboard/toolbar status surfaces.

Room Correction and Active Crossover do not appear as dashboard control panels.

### Equalizer

Dedicated production editor for static/dynamic EQ, phase mode and channel domain. PR36 establishes the route and summary surface; detailed production editing is intentionally migrated from Engineering Validation in a focused follow-up PR.

### Dynamics

Dedicated production editor for compressor/expander/gate/protection/noise tools. PR36 establishes the route and summary surface; dense editing remains a focused follow-up.

### Meters

Dedicated production workspace for detailed signal and analysis telemetry. The Dashboard retains only the signature stereo VUs. The Meters workspace is the intended home for detailed peak/RMS/true-peak, gain-reduction, loudness, protection, spectrum/RTA, and related views as they are migrated.

High-cost analyzers must remain explicitly opt-in. Merely having the Meters route in the application must not make hidden analysis run.

### Speaker Setup

Dedicated speaker-system section containing:
- Active Crossover / bass management;
- Room Correction;
- later speaker/IR and alignment workflows where they belong conceptually.

The purpose is to keep system-calibration workflows separate from day-to-day playback controls.

## Application scene contract

The first declared scene is now the production `WindowGroup`, whose root is `ProductionRootView`. This is the normal launch experience.

The historical Main/PR27/PR28/PR30/PR31 validation surfaces are retained together in a separate `Engineering Validation` window. Both windows share the same `ProductController` and `AudioIOEngine`; opening engineering tools does not create a second transport or DSP engine. The production toolbar provides an explicit Engineering Validation button, and the validation window remains secondary rather than appearing in shipping navigation.

The wrench/screwdriver button is therefore a temporary engineering-migration affordance, not the intended shipping location of Equalizer, Dynamics, or Speaker Setup controls. Those controls migrate into their matching production routes; the engineering window is retained only until that migration and validation are complete.

## Liquid Glass rules

- Use native `NavigationSplitView`, toolbar and system controls so macOS 27 supplies platform-correct Liquid Glass automatically.
- Use custom `GlassEffectContainer` / `glassEffect` only for compact control clusters that float above content.
- Do not put glass behind every content card or meter face.
- Prefer semantic system colors for the application shell; the VU face may use a deliberate warm instrument treatment as a product identity element.
- Use glass button styles for custom floating actions rather than applying raw glass behind a normal button.

## VU contract

The Dashboard uses two large analog meters, Left and Right.

Visual contract:
- the scale is an upper arc above the needle pivot, matching the intended 1970s analog-instrument character;
- the needle sweeps left-to-right across that upper arc rather than occupying only one side of the face;
- the warm meter face remains a deliberate product-identity element.

Signal contract:
- output RMS drives the mechanical-style needle;
- output peak is available as a supporting numeric readout;
- 0 VU is referenced to -18 dBFS for display mapping;
- the display range is -20 VU through +3 VU;
- UI-side ballistics smooth the diagnostic samples so the needle behaves like an instrument rather than a sample-peak meter.

The retained PR36 validator checks the calibration points and clamps, including -18 dBFS = 0 VU, -38 dBFS = -20 VU, and -15 dBFS = +3 VU, plus the upper-arc needle geometry.

This mapping is a UI presentation contract, not a change to DSP gain staging.

## Meter performance contract

PR35 established that user-visible analysis must be explicitly gated. PR36 preserves that rule and adds an explicit user-facing VU switch:

- graph metering defaults OFF;
- the Dashboard contains a persisted `VU Meters` toggle;
- a visible, running Dashboard acquires a metering-demand token only when that toggle is ON;
- turning VU Meters OFF cancels the production meter loop, releases the demand token, resets the displayed needles, and parks render-kernel meter accumulation;
- leaving Dashboard or stopping transport likewise releases the token;
- demand is reference-counted so multiple production windows cannot disable a meter still needed by another visible Dashboard;
- the bridge injects the current demand bit only at DSP graph publication, avoiding a new meter-demand atomic read in the physical-output per-sample loop;
- later EQ, Dynamics, gain, crossover, or other graph publications automatically preserve the current requested-meter state;
- Swift diagnostics expose the actual published `meteringEnabled` state before the Dashboard consumes meter values;
- one production meter loop polls a compact diagnostics snapshot at approximately 30 Hz;
- no hidden production page owns an independent high-frequency timer;
- the validation-shell polling loops remain separate from the production UI and are not used as the production meter source.

When the last active Dashboard meter request disappears, PR36 republishes the current graph through a neutral control-plane path so PR35 meter accumulation returns to its parked state. The meter-demand getter is guarded by CI against accidental use in `N60OutputIOProc`.

The VU toggle is also the intended hardware A/B tool for the observed CPU increase during live playback. Before attributing the increase to metering, hardware validation should compare the same program material with VU Meters ON versus OFF. If a material delta remains, the next optimization step is to split the Dashboard's output-only VU demand from future full input/post-EQ/output analysis rather than leaving all detailed meter taps active for the signature VUs.

## Engineering validation access

The existing Main/PR27/PR28/PR30/PR31 validation tabs remain available in the separate `Engineering Validation` window during the UI migration. The shipping window no longer presents those tabs as its primary navigation.

## Retained PR36 CI guard

`ci/validate_pr36_ui_foundation.py` protects the structural contract introduced here:
- macOS 27 deployment target;
- production launch scene before the engineering scene;
- all legacy validation surfaces retained in the engineering window;
- `NavigationSplitView` and selective Liquid Glass usage;
- dual signature VUs, calibration constants/mapping, and upper-arc geometry;
- explicit VU enable/disable control plus visible-only meter-demand acquisition/release;
- graph-publication meter injection with no demand read in the realtime output callback;
- Dashboard ownership of physical output selection/refresh and removal of the redundant Audio route;
- authoritative sidebar navigation with no redundant Dashboard `Open` buttons;
- dedicated Meters route for future detailed/opt-in analysis;
- Speaker Setup ownership of Active Crossover and Room Correction;
- post-merge handoff-document requirement.

## PR36 acceptance

- macOS deployment target is 27.0;
- production window uses the new navigation shell and is the normal launch scene;
- Dashboard contains the new clean-room stereo VU deck as its focal point;
- VU scale/needle geometry reads as an upper-arc 1970s analog instrument;
- VUs are fed by explicitly gated current-engine metering rather than synthetic animation;
- VU Meters can be explicitly disabled, returning production metering to its computationally parked state;
- output selection/refresh, start/stop, sample-rate/processing status, volume, mute, and global bypass are available without a separate minimal Audio page;
- sidebar navigation is authoritative and Dashboard summary cards do not duplicate it with jump buttons;
- a dedicated Meters route exists for later detailed telemetry/analyzers;
- Room Correction and Active Crossover are contained in Speaker Setup;
- engineering validation remains reachable in a separate shared-engine window;
- no DSP algorithm or accepted sonic behavior changes;
- retained PR34/PR35/PR36 validators, Debug build, Release build and XCTest remain green on the exact closing head;
- hardware smoke test confirms launch layout, Engineering Validation access, UI responsiveness, VU behavior, VU ON/OFF CPU comparison, and no new audio dropouts;
- handoff document is updated after merge.
