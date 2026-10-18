# PR78 — Production UI Information Architecture

## Purpose

PR78 reorganizes the production UI around the product model that now exists after the multichannel, headphone, ambient-analysis, and active-room-treatment work.

This PR changes **information architecture and presentation only**. It does not add DSP, change the realtime render graph, arm room treatment, or host Audio Units.

## Sidebar

The production sidebar is now:

```text
Dashboard

PLAYBACK
  Equalizer
  Dynamics
  Meters

SYSTEM
  Speakers
  Headphones
  Speaker Calibration
  Room Correction
  Active Acoustics

EXTENSIONS
  Plug-ins
```

Dashboard is intentionally a standalone top-level item. It summarizes the whole application rather than belonging to Playback or System.

### Playback

Playback contains content-facing daily processing and observation:

- Equalizer
- Dynamics
- Meters

### System

System contains hardware-, transducer-, calibration-, and acoustic-environment-specific configuration:

- Speakers
- Headphones
- Speaker Calibration
- Room Correction
- Active Acoustics

### Extensions

Extensions is reserved for optional third-party or ecosystem functionality. PR78 establishes the Plug-ins entry point, but Audio Unit hosting is not implemented here.

## Speakers

The old **Active Crossover** navigation item is renamed **Speakers**.

The existing proven crossover/routing implementation is retained. The broader page name reflects what it already owns:

- speaker topology;
- bass management;
- crossover design;
- sub alignment;
- physical Core Audio routing;
- driver trim/delay/polarity/EQ;
- verification monitoring.

No duplicate speaker-routing page is introduced.

## Dashboard

Dashboard is renamed from "Listening Dashboard" to simply **Dashboard** and remains above every sidebar category.

Its system summary cards now include:

- Playback Path
- Equalizer
- Dynamics
- Speakers
- Room Correction
- Active Acoustics

The Active Acoustics card reports only real state:

- active / transitioning / faulted PR77 treatment telemetry when present;
- staged hardware-gated treatment when present;
- otherwise the passive Ambient Analysis / unstaged state.

No synthetic acoustic measurements are shown.

## Active Acoustics

PR78 adds a new System workspace with two tabs:

### Ambient Analysis

The UI exposes the PR72 product concept and explicitly identifies the current limitation: the passive analysis engine exists, but continuous calibrated microphone monitoring is not yet connected to the production path.

Until that live worker exists:

- level and confidence are shown as unavailable;
- the UI describes the available passive metrics;
- no fake environmental values are generated;
- no anti-noise control is exposed.

### Room Treatment

The UI exposes the PR73–77 state as **status and readiness only**:

- treatment band;
- source count when live;
- added latency;
- protection clamp/failure telemetry;
- MIMO design readiness;
- FIR realization readiness;
- repeat-measurement / hardware-gate state;
- active / transitioning / bypass / fault status when a PR77 runtime exists.

PR78 deliberately contains **no Arm, Bypass, Stage, or Apply control** for room treatment.

The underlying PR77 staged-treatment state remains private/default-off and hardware-gated.

## Plug-ins

The Extensions → Plug-ins page establishes the future product shape:

- bounded ordered rack;
- four visible empty slots;
- explicit signal-chain placement;
- third-party effects upstream of System correction/routing/protection.

The Add Plug-in control is visibly disabled.

PR78 does not:

- enumerate Audio Units;
- instantiate Audio Units;
- save plug-in state;
- negotiate AU channel layouts;
- add AU latency;
- alter audio routing.

Those belong to the next AU-host implementation PR.

## Safety and product truthfulness

PR78 follows two UI rules:

1. do not expose controls for a backend feature that has not passed its safety gate;
2. do not display invented measurements or imply an unimplemented feature is active.

Accordingly:

- Ambient Analysis is described honestly as passive-foundation-ready but not continuously monitored;
- Room Treatment is status-only;
- Plug-ins are visibly not active;
- adaptive SRC remains automatic infrastructure surfaced through Transport diagnostics rather than a settings toggle.

## Validation

PR78 adds unit and structural checks for:

- Dashboard remaining outside all sidebar groups;
- exact Playback / System / Extensions membership;
- Speakers replacing Active Crossover in navigation;
- Active Acoustics and Plug-ins routing to real workspaces;
- absence of room-treatment arm/bypass/stage calls in the UI;
- disabled Plug-in Add control;
- new UI files included in the app target;
- navigation tests included in the XCTest target.

CI also retains the PR77 hardware-gated live-integration validation, builds the arm64 app, runs PR78 navigation tests, and runs the complete retained XCTest suite.

## Manual visual acceptance

A real Mac is still required to judge:

- sidebar density and section-header spacing;
- Dashboard balance at supported window sizes;
- Active Acoustics card layout;
- accessibility / VoiceOver order;
- Liquid Glass behavior and hover states;
- Plug-in rack visual proportions.

PR78 can be software-complete before that visual acceptance, but should remain draft with the rest of the hardware-dependent stack until the UI has been reviewed on macOS.

## Provenance

PR78 is clean-room proprietary SwiftUI product work. It adds no third-party dependency, entitlement, private API, driver, helper process, or network dependency.
