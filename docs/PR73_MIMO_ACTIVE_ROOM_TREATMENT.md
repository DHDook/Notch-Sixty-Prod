# PR73 — MIMO Active Room Treatment Designer / Simulator

## Purpose

PR73 turns the experimental PR59 regularized MIMO math into a **bounded offline room-treatment candidate designer and simulator**.

It still does **not** put an adaptive controller or anti-noise signal on the live audio path. The goal of this PR is to prove the spatial-control policy, safety bounds, measurement integration, and deterministic verification before any future runtime compiler can touch speakers or subwoofers.

Initial product scope is intentionally conservative: **20–150 Hz**.

## Inputs

The product-facing `MIMORoomTreatmentDesigner` consumes the existing PR58/PR64 calibration products:

- selected physical/semantic speaker and subwoofer sources;
- included weighted seats;
- one complex source → seat transfer measurement for every selected source/seat pair;
- one common native sample rate;
- a bounded low-frequency analysis grid.

Native LFE remains program content, not a physical acoustic actuator. A future product workflow will choose which physical speakers/subwoofers are eligible actuators.

## Core solver

PR73 reuses the independently authored PR59 solver:

`C = (Hᴴ W H + λI)⁻¹ Hᴴ W D`

where:

- `H` is the measured complex acoustic transfer matrix;
- `W` contains seat weights;
- `D` is a conservative spatial target defined by PR73;
- `λ` is mandatory Tikhonov regularization;
- `C` is the source-domain correction matrix.

PR73 does not weaken PR59's regularization or coefficient scaling.

## Spatial target policy

For each physical source and frequency:

1. compute the weighted geometric mean of measured source magnitude across included seats;
2. optionally apply bounded target headroom (default **0 dB**);
3. preserve each seat's measured acoustic phase;
4. solve for a MIMO source matrix that moves the room toward that common magnitude field.

This deliberately avoids a trivial "improvement" from simply turning the room down. With default 0 dB target headroom, a spatially uniform field is already on target and returns exact identity.

The target also avoids asking the solver to flatten propagation phase or blindly invert deep spatial nulls.

## Safety / source-effort bounds

PR73 applies three independent frequency-domain bounds after the regularized solve:

1. **Per-coefficient gain**
   - default maximum: 0 dB;
   - inherited PR59 column-preserving safety scaling.

2. **Per-target aggregate source power**
   - bounds `sum_s |C[s,t]|²`;
   - default maximum: unity power gain (0 dB).

3. **Per-physical-source effort**
   - bounds `sum_t |C[s,t]|²`;
   - default maximum: unity power gain (0 dB);
   - if exceeded, the complete matrix at that frequency is uniformly scaled so spatial relationships/null directions are not corrupted.

The per-source metric is an **excursion/thermal proxy**, not a claim of physical driver protection. A later hardware-aware compiler must tighten these limits using actual subwoofer/speaker excursion, thermal and protection models before live deployment.

## Robustness gate

Every candidate frequency bin is tested against four deterministic plant perturbations.

Default perturbation envelope:

- ±10% transfer magnitude;
- ±5° transfer phase.

For each perturbed room, PR73 compares treated error with the untreated field against the same spatial target.

A bin is accepted only if all configured gates pass:

- minimum nominal predicted improvement;
- maximum worst-case relative degradation under perturbation;
- minimum retained safety scale.

Rejected bins are replaced with **exact identity** in the returned correction matrix. The untrusted candidate metrics remain available for diagnostics, but a future compiler cannot accidentally deploy the rejected coefficients.

## No-op behavior

If the untreated field already matches the spatial target within numerical tolerance:

- the bin is not marked accepted;
- correction is exact identity;
- no artificial attenuation or mixing is introduced.

## Product-facing plan

`MIMORoomTreatmentPlan` exposes:

- selected source identities;
- seat IDs;
- frequency grid;
- accepted/rejected status per frequency;
- untreated and candidate residual power;
- predicted improvement in dB;
- worst-case perturbation degradation;
- maximum coefficient magnitude;
- maximum per-target column power;
- maximum per-source effort power;
- minimum applied safety scale;
- complete safe frequency-domain correction matrix.

The plan is explicitly `simulationOnly == true`.

There is **no apply/deploy method** in PR73.

## Memory / realtime boundary

The PR59 fixed-capacity matrices can approach megabyte scale. PR73 therefore provides control-plane heap allocation helpers for transfer/design storage rather than copying those matrices through Swift stack values.

The large target workspace is also heap allocated.

None of these allocation/design APIs are legal on an audio callback.

PR73:

- owns no Core Audio IOProc;
- creates no live FIR/IIR bank;
- changes no playback graph;
- publishes no realtime coefficients;
- performs no continuous adaptation.

## Deterministic validation

Portable C simulation covers:

- spatially uneven two-source / two-seat low-frequency fields;
- regularized MIMO improvement;
- coefficient gain bounds;
- per-target aggregate power bounds;
- per-source effort bounds;
- robustness gating;
- exact-identity fallback for rejected bins;
- exact no-op behavior for an already-uniform field;
- singular/highly correlated acoustic paths remaining finite and bounded;
- invalid settings failing closed.

Swift/XCTest integration covers:

- construction from real `MultichannelCalibrationMeasurement` models;
- 20–150 Hz product grid;
- complex magnitude/phase interpolation;
- bounded candidate materialization;
- rejected-bin identity behavior;
- spatially uniform no-op behavior;
- missing source×seat measurements failing closed;
- missing phase data failing closed;
- duplicate actuators failing closed.

CI also retains the PR59 MIMO validation, PR72 passive ambient-analysis validation, arm64 app build and full XCTest suite.

## Manual / hardware acceptance still required

Before any live deployment work:

- validate source identities and measured phase with real speakers/subs;
- compare predicted versus re-measured spatial magnitude improvement;
- verify no audible image instability or low-frequency pumping;
- validate 1–4 subs plus bass-capable mains;
- test multiple-seat weighting tradeoffs;
- characterize model drift when doors, furniture, people or sub placement change;
- establish real driver excursion/thermal limits;
- validate final limiter/protection ordering;
- measure latency/causality implications if treatment later becomes dynamic.

## Relationship to Ambient Analysis and ANC

PR72 estimates environmental residual sound.

PR73 instead targets the **room's response to Notch Sixty's own playback**—spatial modal unevenness and low-frequency acoustic field control.

A later MIMO Active Room Treatment runtime may use PR73-designed bounded filters. Active Quiet Zone / environmental ANC remains a separate future adaptive-control problem and will require reference/error microphones, secondary-path models, causality checks and filtered-x style control.

## Provenance / App Store

PR73 is clean-room proprietary work using the existing proprietary PR59 matrix solver and standard regularized least-squares / robust-control evaluation techniques. It adds no third-party DSP dependency, private API, driver, helper, entitlement or network dependency.
