# Protection, Oversampling, and True-Peak Runtime

PR #27 adds the first production overload-protection layer above the PR #26 dynamics foundation.

## Scope

The stage provides:

- selectable 1× / 2× / 4× oversampling infrastructure;
- strict unity-gain behavior when nonlinear protection is inactive;
- true-peak observation from the oversampled path;
- linked-stereo soft clipping;
- linked-stereo look-ahead limiter behavior;
- protection/gain-reduction telemetry;
- explicit latency contribution to the shared DSP graph contract.

The implementation is portable C and lives in `N60Protection.c/.h`. Product-facing configuration is represented in the Swift dynamics/protection model and persisted through product-state schema version 5.

## Signal-chain contract

Protection operates on the processed path after the PR #26 compressor/expander dynamics contribution and before final audition/master-output handling. Global Bypass remains the raw escape path.

The graph latency reported by protection is added to the existing shared `latencyFrames` contract. Reference/Delta audition therefore continues to use one latency authority rather than maintaining protection-specific comparison timing.

## Oversampling contract

Oversampling is not allowed to change nominal level by itself.

Deterministic validation requires both 2× and 4× unity paths to remain within 0.01 dB of the delayed input reference, with residual error below -45 dB for the validation signal. This is a release-blocking regression requirement because the historical 4× implementation caused severe output attenuation.

Current deterministic engine latency for oversampling-only validation is:

- 1×: no oversampling latency;
- 2×: 32 frames;
- 4×: 48 frames.

Any future filter/backend replacement must preserve explicit gain and latency accounting and must re-pass the unity tests rather than relying on subjective listening alone.

## True-peak contract

True-peak observation uses the oversampled representation so intersample excursions can be detected even when base-rate samples do not show the same peak. Limiter operation forces the high-resolution protection path required for true-peak control.

Telemetry exposes true-peak and limiter gain-reduction information at control/diagnostic cadence; no UI state is touched from the realtime callback.

## Soft clipper

The soft clipper is a bounded nonlinear stage with product configuration for drive/ceiling/shape behavior. Stereo processing is linked so overload protection does not independently shift image position between channels.

Bypass must not introduce a gain jump. Enabling/disabling protection must not cut transport or recreate the historical dynamics-toggle failures.

## Look-ahead limiter

The limiter uses preallocated runtime state and contributes its look-ahead delay to graph latency. The deterministic limiter test verifies:

- 4× effective protection processing;
- output true peak does not exceed the configured ceiling within numeric tolerance;
- base-rate output remains bounded by the ceiling tolerance;
- gain-reduction telemetry becomes active when deliberately overdriven;
- no safety-clamp activity is required in the nominal validation case.

## Realtime contract

The protection callback path follows `docs/REALTIME_RULES.md`:

- no allocation/free;
- no blocking locks;
- no logging;
- no disk/network/device/UI access;
- no filter design or configuration construction;
- fixed/preallocated state only.

Configuration and coefficient/state preparation happen on the control plane and are published as immutable/precomputed state.

## Clean-room / provenance

This implementation is independently authored for the commercial repository from current product behavior requirements, standard multirate/true-peak/waveshaping/limiter concepts, and the proprietary PR #12–26 render/latency architecture.

Legacy Notch Sixty behavior and UI naming may be used to establish parity requirements, but historical GPL/inherited processor source, tests, or implementation expression are not implementation references. See `docs/PROVENANCE.md`.

## Automated release gates

PR #27 must retain deterministic coverage for:

- 2× unity gain;
- 4× unity gain;
- true-peak intersample detection;
- limiter ceiling and gain reduction;
- bounded soft-clipper output;
- graph latency propagation;
- existing EQ/FIR/room-correction/audition/dynamics/master-volume regression behavior.

The 4× attenuation defect is a release blocker if it ever reappears.

## Hardware acceptance

Before merge, perform a focused hardware pass at a safe receiver level:

1. all protection disabled — no unintended gain change or coloration;
2. 2× and 4× — no audible level loss;
3. soft clipper — controlled overload behavior, no click/cutout/bypass level jump;
4. limiter/true peak — expected ceiling control and telemetry without unstable transitions;
5. Processed / Reference / Delta — comparison remains latency aligned;
6. Global Bypass — remains raw;
7. master volume/mute — remain authoritative;
8. transport diagnostics — no new underrun/overrun/recovery instability.

Temporary engineering UI cosmetics are not a separate acceptance gate.

## Deferred

PR #27 does not close the entire legacy Dynamics parity inventory. Advanced dynamics processors and product UX remain tracked separately and must be classified/implemented in later parity slices.
