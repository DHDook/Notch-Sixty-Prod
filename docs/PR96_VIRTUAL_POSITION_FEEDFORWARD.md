# PR96 — Virtual-Position Feed-Forward ANC

## Objective
Use **one movable USB measurement microphone**:
1. Measure the virtual listener position.
2. Move the mic upstream toward the hallway/doorway.
3. Return to the listener for clock/source repeatability.
4. Leave the mic upstream when a verified low-latency control path becomes available.

This is **not the same system** as PR95's sequential stationary-tone feedback ANC.
PR96 must model arrival-time preview for disturbances from a specified source region,
speaker/seat acoustic delay, input/DSP/output latency and worst-case uncertainty.

## Implementation in the first PR96 integration slice
- `QuietZoneFeedForwardCalibration`: project-scoped provenance; one movable
  mic and the virtual-listener position; read-only relative timing records.
- `QuietZoneFeedForwardBudgetAnalyzer`: validates a controlled-source
  listener → upstream → listener timing survey with matching clock, trigger,
  microphone and route, adequate SNR and return-to-listener repeatability.
- Measured **acoustic preview**, conservative uncertainty-adjusted preview,
  measured reference acquisition + processing + output-to-seat latency,
  and a conservative **causality reserve**.
- Clear labels for missing, noncausal, marginal and physically plausible timing.
- Session expires after 24 h; incompatible microphone/project/route/clock fails.
- `QuietZoneFeedForwardStore`: atomic project-local sidecar, never a Content Preset
  or Playback System setting.
- Active Acoustics → Quiet Zone → Virtual-Position Feed-Forward ANC:
  guided one-mic workflow, read-only budget metrics and hard **Diagnostics**
  status. There is deliberately **no feed-forward Arm switch**.
- A calibrated `QuietZoneFeedForwardProbeDetector` that extracts coded-probe
  arrival from a synchronized controlled-source recording, using normalized
  matched filtering and a pre-event SNR gate. It refuses uncorrelated,
  clipped or unclocked recordings; it **cannot itself** supply clock sync.
- Synthetic probe-delay, causality, clock drift, route, clipping, stale-data and
  independent persistence tests.

## Important physical constraints
An A/B/A pair of ordinary Room Correction sweeps **cannot** establish true
disturbance propagation delay if the timing reference is not shared or
cross-calibrated. A mobile phone speaker triggered by hand cannot provide
trusted source→listener and source→hallway arrival timestamps.

The timing-survey input therefore explicitly requires repeatable
source-triggered captures with sample-clock or timestamp provenance and
bounded uncertainty. The existing PR90 input analysis is polled about every
250 ms, and its large window is too slow for unpredictable feed-forward ANC.
A positive preview margin is a necessary condition but **not sufficient** for
stable cancellation. It does not establish noise-field coherence,
virtual-error transfer accuracy, control bandwidth or real acoustic reduction.

No generic 35–250 Hz or "5.8 dB reduction" claim is made without measured
conditions and independent validation. The existing PR90 stationary-tone
control remains unchanged and does not automatically switch to feed-forward.

## Work needed to complete live operation
- Implement clock-qualified controlled-source probe capture using an external
  speaker with repeatable shared launch timestamps or calibrated loopback.
- Measure Core Audio / DAC / microphone round trip and jitter using the actual
  deployed low-latency control configuration, not a room-IR peak alone.
- Add a dedicated low-latency reference→anti-noise transport, echo cancellation
  of own program/anti-noise, robust disturbance transfer and virtual-error
  estimation, model-staleness monitoring, per-band coherence/safety,
  listener-seat physical A/B validation, and fault-fade to bypass.
- Keep the single-mic upstream workflow as the default and a simultaneous
  listener error mic as an optional advanced upgrade.

The current PR96 diagnostics can be verified without activating potentially
unsafe live feed-forward processing.


## Second PR96 implementation slice — controlled survey and native reference stream

- `QuietZoneFeedForwardSurveySession` coordinates the actual order **listener →
  upstream → listener**, refusing incomplete, incorrectly timed, incompatible
  microphone/source/clock/route recordings. It explicitly takes a
  `QuietZoneFeedForwardProbeCapture` from a separately *instrumented*
  calibrated trigger; the survey coordinator does not pretend a smartphone or
  an ordinary sweep offers synchronized timing.
- An unrepeatable listener-return arrival invalidates the entire survey.
  Sound samples remain transient; only the arrival metadata can be saved.
- `N60FeedForwardReferenceBridge` is a new native realtime-safe HAL
  **input-only** timestamped SPSC ring. It retains physical input host time,
  sample time and callback-relative frame offset; rejects missing timestamps,
  non-finite samples, unsupported buffers and FIFO overflow. No callback
  allocation, blocking, logging, or DAC output is permitted.
- `FeedForwardReferenceTransport` creates/starts/stops the independent
  timestamped microphone callback. Its ring can be drained in smaller frame
  batches without waiting for PR90's ambient FFT/polling cycle.
- New deterministic Swift and native-bridge XCTest cases cover capture order,
  return-drift failure, unsynchronized clocks, FIFO ordering, overflow and
  invalid timestamps.

**Still missing:** instrumented external-source playback controller with
cross-device clock calibration; measured reference-to-DAC latency and jitter;
causal native reference-to-output anti-noise; disturbance field and virtual
seat model; leakage control; hardware sign-off. This input-only substrate
does not itself make ANC operational and must not enable an Arm control.


## Third PR96 slice — offline virtual-listener model and bounded FIR dry-run

- `QuietZoneVirtualSeatDesigner` accepts **measured phase-referenced complex
  source→upstream and source→listener transfer**, independent left/right
  loudspeaker→listener secondary paths, loudspeaker→upstream leakage paths,
  and repeated-measurement coherence.
- The offline regularized stereo least-squares candidate is only considered
  for LF bands supported by PR90; low coherence, noncausal timing, weak
  actuator authority, excessive upstream reference contamination, non-finite
  transfer values or unhelpful candidate reduction all fail closed.
- Applies a conservative *global* magnitude budget across modeled bands, not
  a separate unlimited filter at every bin. Modeled reduction is not presented
  as a real-world measurement.
- `N60FeedForwardPreviewFIR` is a separate native, allocation-free
  **dry-run-only** two-channel causal FIR executor (max 256 taps). Each side
  has strict -24 dBFS L1 gain bound, nonfinite input flushing, and an output
  limiter. It starts unconfigured/silent, with no route to actual loudspeakers.
- Swift/C XCTest covers coherent and incoherent transfer models, causal
  budget, leakage, headroom, FIR time-domain impulse response, invalid taps,
  nonfinite reference samples and default silence.

The per-bin ideal transfer targets are **not a physically deployable causal
FIR**. A subsequent stable FIR compilation with actual latency/phase limits
is needed, together with live echo control, clock synchronization, reference
input→output scheduling and physical verification. The current project
continues to refuse live feed-forward arming.
