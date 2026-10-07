# PR93 — Room Geometry & Placement Optimizer

## Purpose

PR93 extends the Room Advisor with an optional rectangular-room model that
predicts where acoustic problems are likely to occur and then compares those
predictions with PR92's measured evidence.

The core principle is:

**geometry predicts → measurement confirms → placement recommendation remains
a hypothesis until re-measured.**

PR93 does not change Content Presets, Playback Systems, the live DSP graph, or
Room Correction deployment.

## Scope

### Optional project-scoped room model

Each Room Correction measurement project may have an Advisor-owned geometry
record stored separately from playback/profile state.

The initial model supports:
- room width, length and height;
- listener position (x, y, z);
- left/right speaker positions (x, y, z);
- coordinate convention:
  - x = left wall → right wall;
  - y = front wall → rear wall;
  - z = floor → ceiling.

The model must validate that dimensions are finite/positive and every point is
inside the modeled room.

### Geometry predictions

PR93 computes:

1. **Room modes**
   - rectangular-room axial, tangential and oblique modes;
   - low-frequency modes are ranked for relevance;
   - a geometry mode is not called a measured resonance unless PR92 evidence is
     near the predicted frequency.

2. **First-order reflection paths**
   - image-source prediction for left/right/front/rear/floor/ceiling;
   - path-length excess and delay relative to direct sound;
   - reflection point on the modeled surface when physically valid;
   - measured PR92 early-reflection delay may confirm a candidate surface, but
     geometry alone does not claim that a surface is acoustically strong.

3. **Boundary/SBIR candidates**
   - image-source boundary path excess for each speaker/surface pair;
   - first destructive-interference candidate frequency from the path
     difference;
   - candidates are matched to PR92 deep-null / boundary-interference evidence.

### Measurement corroboration

PR93 may promote a geometry hypothesis only when measured evidence is compatible:
- mode frequency ↔ PR92 low-frequency ringing;
- boundary notch ↔ PR92 deep cancellation / SBIR candidate;
- reflection delay ↔ PR92 measured early reflection.

The UI distinguishes:
- **Predicted** — geometry only;
- **Supported** — compatible measured evidence exists;
- **Unconfirmed** — prediction lacks matching measurement;
- **Conflicted** — measurement and geometry materially disagree.

### Placement optimization

The initial optimizer explores practical nearby alternatives rather than
pretending to solve an arbitrary room globally.

It searches:
- listener x/y moves around the entered position;
- stereo speaker pair front/back translation;
- stereo speaker spacing changes while preserving left/right ordering.

Candidate scoring uses:
- coupling to low-frequency axial modes;
- proximity of predicted boundary notches to PR92 measured problem
  frequencies;
- very-early reflection timing penalties;
- movement distance / practicality penalty.

The result is a short ranked list of **predicted placement experiments**.

No candidate is applied automatically. The workflow explicitly asks the user to
move the speaker/listener, repeat a measurement with the same microphone, and
verify the result.

## UI

Room Advisor remains under TOOLS.

PR93 adds a **Geometry & Placement** section after measurement readiness:
- room dimensions;
- listener and stereo speaker coordinates;
- save / clear model;
- top-down room sketch;
- strongest mode / reflection / boundary predictions;
- measurement corroboration badges;
- ranked placement experiments with expected direction of improvement;
- explicit “Prediction — verify with measurement” labeling.

Geometry is occasional-use analysis data. It never appears in Content Preset or
Playback System selectors.

## Guardrails

- rectangular rooms only in PR93;
- irregular rooms/openings are not silently approximated as exact;
- no claim that a predicted room mode is actually excited without measurement;
- no claim that an image-source reflection has meaningful amplitude without
  measurement;
- no large-EQ recommendation from geometry;
- placement recommendations are predictions until re-measured;
- coordinates or dimensions outside the modeled room fail validation;
- no automatic movement, filter deployment, profile mutation or DSP change.

## Follow-on

PR94 consumes PR92 + PR93 evidence to model treatment placement/effectiveness and
guide verified before/after treatment measurements.
