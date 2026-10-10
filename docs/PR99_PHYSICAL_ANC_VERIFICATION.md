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


## Slice 2 — frequency-by-frequency report and canonical evidence manifest

\`QuietZonePhysicalSpectralEvidenceAnalyzer\` first **re-runs all three
PR99 raw acceptance visits** and only then constructs a frequency-resolved
analysis for each fixed matched 20–150 Hz bin. It preserves three separate
measured benefits (listener A, neighboring seat B, returned listener A),
their worst result, the per-frequency repeat difference, and the four
independent primary OFF-baseline span. Every OFF baseline uses a mean
of **linear acoustic power**, never averaged dB.

A second independent **per-frequency** repeat gate rejects any A-to-A-return
reduction difference exceeding 1.5 dB, even when positive and negative
frequency excursions cancel in the **integrated** reduction. This provides
a stricter physical reproducibility review than PR99 slice 1 alone.
Frequency ranges and coherent data quality remain governed by the PR98
numerical acceptance protocol; no processing outside the captured coherent
bass grid is predicted.

The \`QuietZonePhysicalEvidencePackage\` is a reproducible UTF-8 JSON array
of string-token records. It embeds a version marker and **all fields in the
underlying source and physical-fault records**: calibration-rig project ID,
microphone/channel, DAC/route, sample rate and clock, fixture, three
session IDs, exact timestamps, individual source launch IDs, seat and
instrument identifiers, coherence, meter SPL, measured DAC stereo peaks,
each narrowband frequency and level, plus every hardware fault witness
with its measured time and analog residual/no-auto-rearm flag. Doubles
are represented as canonical 16-digit IEEE-754 hex bit patterns to avoid
locale/precision ambiguity, and JSON encodes strings without delimiter
collisions. The SHA-256 digest detects accidental alterations and can be
recomputed from the manifest. The numerical review time is **excluded**
from the manifest so a later engineer re-reviewing identical source and
fault records obtains the same fingerprint; record capture timestamps
and the source rig identity remain included. Any noncanonical or digest-mismatched
payload fails integrity review.

**A self-contained SHA-256 digest is NOT an instrument signature**, a
trusted time service, or provenance attestation; a malicious recorder
can rewrite data and recompute its digest. Therefore authenticated
instrument, genuine acoustic reduction, analog emergency mute, speaker
connection and live ANC qualification remain unconditionally false.

Seven new XCTest cases cover power-correct per-bin comparison, weak B
seat, deterministic manifest digest, changed acoustic data, an aggregate
masking per-band divergence, tamper detection, JSON-escaped instrument
names, and raw preflight rejection. This slice remains software-only;
actual acoustic evidence and independently authenticated instrument
capture remain future hardware commissioning steps.
