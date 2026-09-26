# PR33 Final Dynamics / Conditioning Parity Audit

This audit closes the residual dynamics inventory identified after PR32. “Closed” means every known observable legacy capability is either implemented/improved in the commercial engine or explicitly assigned to a later milestone/product-scope decision; it does **not** claim that routing-, measurement-, or output-format-dependent work has been prematurely implemented.

## Implemented / improved in PR25–PR33

- Compressor: threshold/ratio/knee/attack/release/makeup, feed-forward/feed-back, program-dependent release, sidechain HPF.
- Downward Expander.
- Pause Gate with Attack=fade-out, Release=fade-in, threshold/hold/hysteresis.
- Soft Clipper, including curve selection, drive/threshold/knee, auto gain compensation, and PR33 ±3 dB asymmetry trim.
- Look-ahead Limiter and explicit PR33 True-Peak Guard semantics.
- 1x/2x/4x oversampling and true-peak detection.
- Dynamic Gain Rider / sustained-limiter auto-headroom.
- Predictive EQ/DSP automatic headroom compensation.
- De-Esser with ratio/range/Q/attack/release and Dynamic-EQ mode.
- Three-band multiband compressor with independent crossover slopes and per-band ratio/timing/knee/sidechain/makeup.
- General Dynamic EQ integrated into the normal EQ-band model, with cut/boost/both, Peak/RMS detection, RMS window, timing and bounded range. Commercial capacity is 64 supported dynamic Peak bands (improving the verified 16-band legacy state limit).
- LUFS Loudness Match and Dialogue Gate.
- Dialogue-Relative Leveler with optional voice-confidence gate.
- Volume-aware loudness contour, superseded by PR33 Per-Band Loudness Compensation with reference phons, boost/cut caps, and System Volume / Integrated source.
- De-Harsh high-frequency tilt/conditioning.
- Stereo / Wide Mono / True Mono and three-band M/S widener.
- DC offset filtering, infrasonic filtering, mains-hum notch/detection/tracking, and stationary spectral denoising.

## Explicit later milestones — not silent omissions

- Infrasonic sub-output-only / both routing: Active Crossover / physical-route milestone.
- Independent sub phase/timing and multi-driver alignment: routing + room-correction milestones.
- Excess/mixed-phase correction: room-correction milestone because it requires phase-resolved measurement data.
- Dither / final output-format behavior, if still applicable: output/hardening milestone once the final device/output architecture is fixed.
- Active Crossover Matrix: dedicated post-room-correction parity milestone per current roadmap.

## Explicitly out of current product scope

- Headphone-only spatial/crossfeed/crosstalk features.
- Arbitrary multichannel processing beyond the planned speaker/sub routing model.

## PR33 exit condition

After dedicated engineering validation UI, full CI, provenance review, and focused hardware/listening acceptance, the legacy dynamics/conditioning inventory has no unexplained item remaining. The project can then enter the bounded DSP optimization/enhancement pass without carrying an unknown dynamics-parity debt.
