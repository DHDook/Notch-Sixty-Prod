# PR99 — Physical ANC Verification (remote-only software foundation)

## Scope and current evidence

This roadmap PR is stacked on PR98. It introduces a **read-only, instrument-data
analysis campaign** and reproducibility tests. It is NOT physical acoustic
verification; all supplied data and synthetic XCTest fixtures remain untrusted
until tested on real hardware and reviewed independently.

PR98 already checks one fixed listener's OFF–TEST–OFF low-frequency measured
power spectrum and five externally witnessed emergency fault probes. PR99
adds **three separate visits with one microphone**:

1. Primary listening position (A), one complete independent OFF–TEST–OFF run
2. Adjacent observer seat (B), another complete independent run
3. Return to the same primary position (A), a third independent run

Each visit requires a unique session and three source launches plus five
distinct, externally witnessed fault launches (24 globally unique launch IDs).
An unchanged microphone channel, DAC route/lease, nominal sample rate,
cross-calibrated clock, controlled source identity and instrument calibration
must be reported across all visits. The same coherent 20–150 Hz grid is used.

The analyzer **re-runs PR98's full raw measurement and fault validation** at
every visit; it does not accept a caller's favorable summary Bool. It then
checks that all four OFF baselines at A agree within 1.5 dB in EACH frequency
band, and the integrated measured improvement on returning to A agrees within
1.5 dB. The B visit must independently meet the existing PR98 narrowband
numeric gate and no-regression limits.

No interpolated time-of-flight, automatic compensation, realtime output or
new speaker routing is added. A successful numerical report explicitly
retains false instrument authentication, physical attenuation verification,
hardware mute verification, output connection and live ANC qualification.

## Hardware-dependent acceptance still missing

- Calibrated source/acoustic timestamps and four physical latency stages
- Physical A/B/A source geometry across one moved microphone and route
- Actual externally instrumented listener OFF–TEST–OFF acoustic measurement
- Certified analog mute/fade for input, clock, output and headroom faults
- Validated speaker-to-microphone leakage and nonlinear feedback bounds
- Real measurements of reduction/coherence at several seats and with
  changing environmental conditions
- Independent report signing/authentication, provenance and engineering review

The provisional PR98 thresholds are bench design starting points, not a
promise of speech cancellation or a live deployment qualification.

## CI

Run the PR99 portable validator, inherited PR98 disconnected-output audit,
macOS arm64 application build, targeted PR99/PR98 XCTest, and complete
application regression on the exact commit. All PR99 gates are diagnostic
only. PR99 remains draft until physical evidence is independently reviewed.
