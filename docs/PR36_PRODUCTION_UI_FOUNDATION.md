# PR36 Production UI Foundation

Status: IMPLEMENTATION COMPLETE — awaiting exact-head CI and final VU-on hardware CPU/UI smoke test

## Purpose

PR36 transitions Notch Sixty from the engineering-validation shell to the first shipping macOS 27 interface. It establishes the production information architecture, Liquid Glass visual language, signature VU presentation, and performance-aware meter lifecycle without changing accepted DSP behavior.

## Product requirements

1. Target macOS 27 and current SwiftUI APIs.
2. Use the current Liquid Glass design language intentionally rather than reproducing the historical app shell.
3. Keep the stereo analog VU meters as a signature focal point of the main interface.
4. Keep Room Correction and Active Crossover off the main dashboard in a dedicated Speaker Setup section.
5. Preserve engineering-validation surfaces during the production-UI migration instead of deleting them prematurely.
6. Treat expensive meters/analyzers as explicit user-requested work and park them when disabled or hidden.
7. Production meters use independent meter pipelines unless one meter is intentionally derived from another. CPU cost should therefore scale with the meters/analyzers actually requested by visible UI.
8. After PR36 merges, update the project handoff document before beginning the next PR.

## Clean-room / provenance

The production UI is a new implementation. The historical GPL Notch Sixty / Equaliser source is not a coding or layout reference for this work.

The VU meters are implemented from the owner-specified product requirement that stereo analog VUs are a signature element. PR36 does not copy historical VU source expression, assets, geometry, or resources. The new VU component is drawn in SwiftUI from first principles and is driven by current clean-room audio telemetry.

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

Production meter widgets follow the independent-pipeline rule: a visible meter requests only the telemetry pipeline it actually consumes, unless its design explicitly derives from another already-requested meter. An input-level meter does not implicitly start post-EQ or output metering; an output VU does not implicitly start input/post-EQ metering; an RTA does not run merely because another level meter is visible. High-cost analyzers remain explicitly opt-in. Merely having the Meters route in the application must not make hidden analysis run.

The pre-existing render-kernel all-stage meter path remains available for Engineering Validation and compatibility while the production meter workspace is migrated. It is not the architectural model for new production widgets.

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
- the warm meter face remains a deliberate product-identity element;
- static face/tick/label drawing is separated from the dynamic needle so the full face is not intentionally redrawn for every telemetry update.

Signal contract:
- final physical-output RMS drives the mechanical-style needle;
- final physical-output peak is available as a supporting numeric readout;
- 0 VU is referenced to -18 dBFS for display mapping;
- the display range is -20 VU through +3 VU;
- UI-side ballistics smooth the telemetry so the needle behaves like an instrument rather than a sample-peak meter;
- the UI refresh cadence is approximately 20 Hz, while realtime audio accumulation remains callback-local.

The retained PR36 validator checks the calibration points and clamps, including -18 dBFS = 0 VU, -38 dBFS = -20 VU, and -15 dBFS = +3 VU, plus the upper-arc needle geometry and static-face split.

This mapping is a UI presentation contract, not a change to DSP gain staging.

## Independent meter pipeline architecture

PR35 established that user-visible analysis must be explicitly gated. PR36 extends that principle into independent meter pipelines for production UI.

### Dashboard output VU pipeline

The signature VUs no longer enable the render kernel's full input + post-EQ + output meter stack.

Instead:
- `N60RealtimeAudioBridgeSetOutputVUMeterDemand` owns a dedicated output-VU demand state;
- a visible, running Dashboard acquires that demand only when the persisted `VU Meters` toggle is ON;
- the demand state is read once per physical-output callback, not once per sample;
- when requested, peak/RMS accumulation runs only on the final stereo samples actually written to the physical output after DSP, master/output gain, startup fade, and transition gain;
- accumulation stays in callback-local variables and publishes one bounded atomic snapshot per callback;
- turning VU Meters OFF cancels UI polling, releases the output-VU demand, resets the needles, and stops that accumulation;
- multiple visible production windows are reference-counted so one Dashboard cannot disable another Dashboard's requested VUs;
- the Dashboard does not republish the DSP graph merely to toggle its VUs.

### Full engineering/detail meter path

The existing render-kernel `meteringEnabled` path remains separately gated and separately default-OFF. It currently provides input, post-EQ, and output readings used by Engineering Validation and existing diagnostics. Dashboard output VUs no longer request it.

As production detailed meters are implemented, they should receive dedicated requestable pipelines/taps rather than making one visible widget activate unrelated telemetry. Shared computation is allowed only when one meter is intentionally derived from another or when a mandatory processor already computes the required telemetry by design.

### UI rendering cost

The first production hardware pass also showed that the VU subsystem's cost included both realtime metering and SwiftUI presentation work. PR36 therefore splits the meter face from the dynamic needle/readout and reduces production VU polling from roughly 30 Hz to roughly 20 Hz, with adjusted ballistics to preserve the intended mechanical feel.

## Hardware performance observations

First hardware production-UI pass at the user's normal setup showed approximately:
- processing ON + program audio + VU Meters ON using the original all-stage meter path: ~40% CPU;
- same processing/program audio with VU Meters OFF: ~1.1% CPU.

The ~1.1% result is effectively in line with the legacy app and confirms that the rewritten transport/DSP engine itself is no longer the source of the production-UI CPU regression. The remaining VU-specific cost is therefore being isolated rather than accepted as normal overhead.

The final PR36 hardware acceptance test must repeat the same program material with the new independent output-only VU path ON and OFF. The desired result is a small incremental cost with VUs ON, not a return to the original ~40% behavior.

## Engineering validation access

The existing Main/PR27/PR28/PR30/PR31 validation tabs remain available in the separate `Engineering Validation` window during the UI migration. The shipping window no longer presents those tabs as its primary navigation.

## Retained PR36 CI guard

`ci/validate_pr36_ui_foundation.py` protects the structural contract introduced here:
- macOS 27 deployment target;
- production launch scene before the engineering scene;
- all legacy validation surfaces retained in the engineering window;
- `NavigationSplitView` and selective Liquid Glass usage;
- dual signature VUs, calibration constants/mapping, upper-arc geometry, and static-face separation;
- explicit VU enable/disable control plus visible-only output-VU demand acquisition/release;
- Dashboard prohibition against enabling the full render-kernel meter stack;
- output-VU demand latched at callback granularity with no demand lookup in the rendered-frame loop;
- full engineering meter demand remains a separate graph-level gate;
- Dashboard ownership of physical output selection/refresh and removal of the redundant Audio route;
- authoritative sidebar navigation with no redundant Dashboard `Open` buttons;
- dedicated Meters route and independent-meter-pipeline requirement for future production telemetry;
- Speaker Setup ownership of Active Crossover and Room Correction;
- post-merge handoff-document requirement.

The bridge performance benchmark separately compares the same 96 kHz / 512-frame realtime workload with output VUs OFF and with the output-only VU pipeline ON, and verifies that the requested VU snapshot publishes non-zero readings.

## PR36 acceptance

- macOS deployment target is 27.0;
- production window uses the new navigation shell and is the normal launch scene;
- Dashboard contains the new clean-room stereo VU deck as its focal point;
- VU scale/needle geometry reads as an upper-arc 1970s analog instrument;
- Dashboard VUs are fed by the dedicated final-output pipeline rather than synthetic animation or the full engineering meter stack;
- VU Meters can be explicitly disabled, returning their production telemetry and UI polling to the parked state;
- output selection/refresh, start/stop, sample-rate/processing status, volume, mute, and global bypass are available without a separate minimal Audio page;
- sidebar navigation is authoritative and Dashboard summary cards do not duplicate it with jump buttons;
- a dedicated Meters route exists for later detailed telemetry/analyzers using independent meter pipelines;
- Room Correction and Active Crossover are contained in Speaker Setup;
- engineering validation remains reachable in a separate shared-engine window;
- no DSP algorithm or accepted sonic behavior changes;
- retained PR34/PR35/PR36 validators, Debug build, Release build and XCTest remain green on the exact closing head;
- hardware smoke test confirms launch layout, Engineering Validation access, UI responsiveness, operational VUs, acceptable VU-ON incremental CPU cost, and no new audio dropouts;
- handoff document is updated after merge.
