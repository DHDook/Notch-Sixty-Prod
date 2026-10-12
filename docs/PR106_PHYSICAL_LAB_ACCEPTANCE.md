# PR106 — Physical Lab Acceptance and Commissioning Runbook

**Status:** Prepared for hardware commissioning; **no physical acceptance is claimed**.

**Branch/stack:** `feature/pr106-advanced-speaker-measurement-lab` → PR105 → PR104 → PR103.  
**Software checkpoint:** `a06d3b0281bc1a2db59e4683e09d73a59a656cf9` (remote software closure).  
**Related:** [PR106 scope](PR106_ADVANCED_SPEAKER_MEASUREMENT_LAB.md), [PR106 software closure](PR106_SOFTWARE_CLOSURE.md), [PR103 physical baseline](PR103_PHYSICAL_HANDOFF.md), [PR105 characterization/verification](PR105_SPEAKER_CHARACTERIZATION_AND_VERIFICATION.md).

## 1. Acceptance principle

The complete Lab is a **measurement-only diagnostic**, not an automatic DSP correction or deployment system. An Apple Silicon Debug build, deterministic tests, and simulated measurements cannot certify real acoustic results, amplifier/driver safety, or coherent DAC/ADC behavior. Report each row as `PASS`, `FAIL`, `BLOCKED`, or `NOT APPLICABLE`; never silently turn a skipped hardware-dependent test into a pass.

A physical campaign may have a limited scope. For example, a conventional passive two-way speaker plus a line-level subwoofer can validate whole-speaker, subwoofer near-field, and (with suitable measurement hardware) coherent Main/Sub workflows **without** claiming protected individual-driver acceptance. Real bi-amp/tri-amp driver tests are a separate, higher-risk commissioning gate.

## 2. Before the first sweep

Record the exact app commit/build, macOS version, DSP profile/Playback System identity, physical output-device UID, input-device UID, sample rate, channel mapping, active bass-management/crossover and driver-limiter state, amplifier/speaker/subwoofer models, room geometry, microphone make/serial/calibration-file identity, and any electrical reference routing.

- Use a known compatible measurement microphone with a stable stand; verify permissions, input channel, calibration and sample-rate compatibility. Keep the microphone **stationary during every three-repeat group**.
- Stop normal program playback and disable unrelated sources/automatic output switching. Verify which output(s) are driven before each change in protocol, device, or route.
- Begin with the amplifier/subwoofer gain conservatively low. Digital dBFS is **not** a calibrated acoustic SPL; never assume a nominal sweep level is safe for a particular loudspeaker.
- First verify whole-speaker source isolation at a safe level; confirm non-target speakers/drivers remain silent, meters do not clip, and the Lab reports the expected route and microphone. Stop on any unexpected acoustic output, hot driver, audible strain, clipping, routing mismatch, or protection alarm.
- Retain the original system/preset state and exported evidence before experimenting. The Lab should never mutate PEQ/FIR/crossover/delay/polarity/limiter state; any such change is an immediate **FAIL**.
- Use the app's validation and quality gates; don't bypass a blocked protocol by raw-routing a sweep to a physical output.

## 3. Ordered physical commissioning matrix

| ID | Test and exact setup | Evidence / acceptance | Status |
| --- | --- | --- | --- |
| P0 | Environment preflight and low-level source isolation; exact output/input identities and 3-repeat capability | Correct source only, no clipping, unexpected output or DSP mutation. Capture full provenance. | Pending |
| P1 | Whole-speaker on-axis: one installed speaker at a time; start at **1.0 m**, 0° H/0° V; **three fixed-mic repeats** per source | On-axis geometry accepted; sweeps meet built-in SNR, clipping, repeatability, arrival and phase gates. Session/export target IDs match. | Pending |
| P2 | Same speaker **off-axis** (example **30° H**) at the **same 1.0 m radius**; three repeats per angle, with repositioning only between groups | Directivity comparison is matched to same source/radius; relative off-axis minus on-axis traces and angles are sensible. No free-field, power-response, spinorama or beamwidth claim. | Pending |
| P3 | Whole-speaker quasi-anechoic analysis using P1/P2 impulse evidence; inspect actual early reflections and choose a defensible user-entered window | Document arrival and first-reflection assumption; report trust-band lower limit; short-window LF is not accepted as loudspeaker LF behavior, and gated phase is not crossover evidence. | Pending |
| P4 | Subwoofer near-field, measuring radiator then any accessible port/passive radiator as **separate protocols**, e.g. nominal **0.05 m**, three repeats each | Accept component-specific LF magnitude/phase only if qualified. Do not add dB magnitudes or invent a far-field composite. Keep listening-position integration separate. | Pending |
| P5 | Level dependence: two **whole-speaker on-axis** groups at exactly the same geometry, each three repeats; bounded 6–18 dB digital difference, starting at demonstrably safe acoustic levels | Report high-minus-low normalized transfer, shape shift and limitations. No calibrated SPL threshold, THD/IMD or intrinsic speaker compression claim from uncontrolled playback gain. | Pending |
| P6 | Protected-driver bus (only if actual Bi-Amp/Tri-Amp routing exists, each exact Low/Mid/High driver path has the production crossover and **enabled limiter**, and physical setup is independently judged safe) | One and only one intended physical route active; explicit sweep no hotter than **-24 dBFS**; crossover/limiter provenance preserved. On missing protection or state drift, acquisition must refuse to start. | Pending |
| P7 | Coherent Main/Sub timing with a safely wired **line-level** electrical reference, same physical input device/ADC for mic + reference, and same reference output device for both Main and Sub | Linked Main/Sub protocols, matched geometry and sweep level, at least three repeats per leg, reference-path qualification across legs, stable relative delay/phase near the crossover. No independent multi-DAC clock claim. | Pending |
| P8 | Session resume, cancellation/retry, history, compact JSON/CSV export and measurement-only protection | Identity mismatches block unsafe resume; only intended repeat is retried; provenance/limitations retained; no Lab Apply or DSP deployment authority. | Pending |

**Mode geometry contracts:** whole-speaker on-axis/off-axis **0.5–5 m**; on-axis within ±10°, off-axis ≥10° and ≤90°; near-field **0.01–0.50 m**; coherent **0.5–10 m**. All protocols require **3–10 repeats**. These are software validity limits, not guarantees of physically meaningful microphone placement.

## 4. Specific risk gates

### Protected drivers: never improvise a direct output

The normal PR103 physical-lane sweep is **not** an alternative driver-measurement path. PR106's dedicated protected path renders excitation through the *production* Bi-Amp/Tri-Amp crossover and driver EQ/trim/polarity/delay/limiter, then binds the resulting waveform to exactly one output route.

- On a passive speaker connected through a conventional single amplifier channel, mark P6 **NOT APPLICABLE**; do **not** connect a tweeter or midrange directly to the amplifier just to exercise P6.
- Before any P6 hardware execution, independently verify wiring, crossover topology, limiter values, amplifier channels, speaker-driver capabilities and routing at the lowest safe level. Software limiting cannot guarantee physical driver thermal/excursion safety.
- Verify **missing limiter**, **wrong route**, **wrong bus**, or **crossover change** refusal using non-energized hardware/fixtures when practical; **do not** deliberately bypass protections while a vulnerable driver is attached.
- Treat acoustic driver response as including the active crossover/driver chain; it is not a bare-drive-unit anechoic specification.

### Coherent timing: preserve a real electrical reference

P7 is optional until the right input/output hardware is available. Both acoustic and electrical reference inputs must be captured simultaneously on different channels of the **same physical ADC**. Both source legs must use the **same output-device clock domain** and the **same stable reference path**.

**Never connect amplifier speaker terminals or other power outputs directly to a microphone or line input.** Use a known safe, appropriately isolated/attenuated **line-level** reference tap and suitable capture interface; if a correct connection cannot be established, mark P7 **BLOCKED**. A soundcard loopback connected to an unrelated output device is not proof of coherent cross-source timing.

The measured result is relative Main/Sub arrival/phase under this reference setup, **not** absolute DAC/ADC latency, multi-device clock synchronization, or authorization to deploy polarity/delay changes.

### Installed-room/reflection limits

The default roughly 6 ms gated post-arrival window implies an approximate 333 Hz two-cycle low-frequency trust boundary, **only if** that much uncontaminated early-arrival time physically exists. Reflections may arrive sooner. Do not label a gated response anechoic or extrapolate the curve below the computed trust boundary.

## 5. Evidence package and go/no-go rules

For each completed row retain:

1. Test ID and `PASS/FAIL/BLOCKED/NOT APPLICABLE` with a short reason and tester/date.
2. Exact build/commit; Playback System/routing/output/input identities; sample rate; mic/calibration identity.
3. Protocol mode, acoustic source or driver bus, microphone distance/angles, repeat count, explicit sweep level when used, and reference topology when relevant.
4. Final quality gates, blockers/warnings, screenshots of meaningful plots, report JSON/CSV, and session identity. Keep sensitive user/environment information out of public PR attachments unless intentionally redacted.
5. Unexpected output, near-clipping, gain changes, early-reflection assumptions, level-dependence drift, or other anomaly and the reproduction steps.

**Immediate STOP / FAIL:** unexplained output from a non-target driver, microphone/ADC clipping, a requested sweep becoming hotter than its approved bound, missing protected crossover or limiter, route/identity drift that starts playing instead of blocking, failed electrical-reference qualification that still publishes coherent phase, or *any* Lab-originated DSP modification.

**Minimum claim for partial acceptance:** P0, P1, P2, P3, P4, P5 and P8 each assessed on real equipment; P6 and P7 explicitly labeled BLOCKED or NOT APPLICABLE unless physically executed with proper hardware. **Full PR106 physical acceptance** requires P6 and P7 on a suitable representative rig, not merely on a passive stereo rig. All relevant regressions and exact-head CI must still pass before changing the draft/merge disposition.

## 6. Commissioning record

- **Date / tester:**
- **Git SHA / app build / macOS:**
- **Playback System / output / input / clock / sample rate:**
- **Mic, calibration and reference signal path:**
- **Speakers, sub, amplifier, routing and protection:**
- **Results P0–P8 (each with evidence link):**
- **Open defects, safety blockers and retest scope:**
- **Physical scope attained:** none / passive stereo + sub / protected bi-amp or tri-amp / coherent Main/Sub
- **Final disposition:** physical acceptance pending / partial hardware acceptance / full hardware acceptance

Do **not** mark PR106 ready to merge solely because this runbook exists or because software CI is green. A merge without physical acceptance requires a separate explicit user decision, with the pending limitations clearly disclosed.
