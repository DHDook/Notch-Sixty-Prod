# PR42 — Final Commercial Capability Disposition Matrix

Status: **CLOSURE LEDGER — NO UNEXPLAINED LEGACY OMISSIONS**

This ledger is the controlling PR42 parity/provenance disposition. It reconciles the observable legacy product inventory recorded by PR34 with the proprietary PR35–PR42 product tree.

A disposition describes the commercial product decision; it is not a claim that historical implementation structure was reproduced.

Allowed final dispositions:

- **PARITY** — equivalent user-observable capability exists.
- **IMPROVED** — capability exists with intentionally stronger behavior/architecture.
- **PORT VERIFIED** — owner-authored clean code was deliberately reused after provenance review.
- **SUPERSEDED** — the historical behavior is intentionally not reproduced because the commercial product uses a different mechanism or deliberately narrower 1.0 workflow.
- **BLOCKED** — release-blocking gap. PR42 cannot close while any row has this disposition.

For rows marked **SUPERSEDED**, the rationale states the replacement or deliberate 1.0 boundary. Some remain post-1.0 enhancement candidates; that does not mean the legacy capability exists today.

## Transport, device lifecycle, and playback

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| Explicit stereo output selection by stable device identity | IMPROVED | First-party Core Audio lifecycle uses stable UID selection and explicit activation/recovery. |
| Selected-output disappearance and return | IMPROVED | Commercial lifecycle preserves the pinned route and recovers it rather than silently remapping speakers. |
| Sample-rate change handling | IMPROVED | Explicit reconfiguration/rebuild state with graph regeneration. |
| Hardware volume/mute synchronization | IMPROVED | Capability-driven HAL control where writable with software master fallback on fixed-output devices. |
| Fixed-output keyboard volume | IMPROVED | Listen-only macOS auxiliary-control event path updates the commercial software master without input suppression/reposting. |
| Legacy virtual-driver choreography | SUPERSEDED | Replaced by first-party process-tap/Core Audio transport; historical driver implementation is not required or imported. |
| Legacy automatic headphone switching | SUPERSEDED | Headphone-only policy is outside the approved speaker-focused product definition. |
| Software PLL multi-device synchronization | SUPERSEDED | PR41 uses a private Core Audio Aggregate Device with explicit reference clock and HAL drift compensation. |
| Explicit fractional SRC used by the Software PLL | SUPERSEDED | The commercial Aggregate Device strategy uses a shared HAL clock domain/common supported rate instead of recreating the retired PLL/SRC topology. |
| Hardware Sync Buffer state | SUPERSEDED | Audited legacy no-op state is not reproduced. |
| Music/Movie latency-mode state | SUPERSEDED | Audited legacy no-op state is not reproduced; actual graph latency is published and Reference/Delta are latency matched. |
| Processed / Reference / Delta audition | IMPROVED | Dedicated latency-matched reference lane plus true raw Global Bypass. |

## Equalization, phase, FIR, dynamics, and protection

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| Parametric Peak / Low Shelf / High Shelf / LP / HP / Band Pass / Notch / All-Pass | IMPROVED | Proprietary EQ supports the audited shapes with deterministic coefficient design and validation. |
| Constant-Q parametric EQ | IMPROVED | Independently implemented and integrated with the commercial EQ model. |
| Linkwitz Transform | IMPROVED | Typed commercial f0/Q0/fp/Qp model and independently authored implementation. |
| 6–96 dB/oct filter slopes | IMPROVED | Bounded compiled multi-section EQ program. |
| Tilt EQ | IMPROVED | One logical band compiles to complementary shelf sections. |
| Linked / Independent L-R / Mid-Side EQ | IMPROVED | Explicit commercial channel model; static M/S encode/decode is distinct from linked physical-stereo dynamics. |
| Minimum Phase EQ | PARITY | Commercial biquad path. |
| Linear Phase EQ | IMPROVED | Dedicated commercial FIR design/runtime with explicit latency accounting. |
| Mixed Phase EQ | IMPROVED | Dedicated bounded all-pass correction distinct from Room Correction excess-phase work. |
| Per-band FIR | IMPROVED | Resource-backed EQ-band convolution integrated with the commercial graph. |
| Global Speaker IR | IMPROVED | Dedicated independent convolution slot, separate from EQ FIR and Room Correction. |
| Compressor / Expander / Pause Gate | IMPROVED | Proprietary dynamics core; Pause Gate deliberately standardizes Attack=fade-out and Release=fade-in. |
| De-Esser / Multiband Compressor / Dialogue Relative Leveler | IMPROVED | Independent commercial processors with expanded production controls. |
| Dynamic EQ on ordinary EQ bands | IMPROVED | Integrated into the main EQ ownership model rather than a duplicate user-facing band bank. |
| Dynamic Gain Rider / automatic headroom | IMPROVED | Commercial bounded gain-management stages and explicit headroom policy. |
| Per-band loudness / De-Harsh | IMPROVED | Independent commercial implementations. |
| Mains Hum suppression and tracking | IMPROVED | Independent fixed/re-tunable harmonic-notch system with realtime-safe control-plane design. |
| Spectral denoiser | IMPROVED | Independently authored WOLA/spectral processor with explicit quality modes and bounded learning/capture. |
| 1x/2x/4x oversampling | IMPROVED | Commercial protection runtime includes unity-gain regression coverage, specifically guarding the historical 4x attenuation defect. |
| True-peak guard / limiter / soft clipper | IMPROVED | Commercial protection path has explicit true-peak telemetry, look-ahead limiting and bounded clipping. |
| Legacy 24-bit realtime Dither control | SUPERSEDED | Current realtime graph remains Float32; Notch Sixty does not add a gratuitous fixed-point quantizer. Dither belongs only at a future app-owned fixed-bit-depth export/terminal conversion. |

## Metering and analysis

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| Peak/RMS/VU level metering | IMPROVED | Production demand-gated metering surfaces. |
| True-peak / dBTP display | IMPROVED | Uses the commercial true-peak path rather than the historical sample-peak ISP mislabel. |
| RTA | IMPROVED | Input/output production RTA with high-rate-safe worker-plane analysis. |
| Phase correlation | PARITY | Production analysis view. |
| Stereo goniometer | PARITY | Production analysis view. |
| Legacy DR Factor / Bit Stream / Bit Rate analytics labels | SUPERSEDED | Audited legacy metrics overclaimed their measurement basis and are intentionally not recreated. |

## Persistence and interchange

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| Native listening/music preset persistence | IMPROVED | Versioned Content Presets are separated from physical Playback System state. |
| Physical playback-system persistence | IMPROVED | Versioned Playback System Profiles own output association, crossover/routing, correction and speaker state. |
| Session-only Global Bypass / Reference / Delta | IMPROVED | Explicitly transient rather than accidentally serialized into content presets. |
| Legacy `.eqpreset` v1 migration | PARITY | PR42 one-way migration imports shared-bank state into the proprietary model with warnings for unrecoverable fields. |
| Legacy `.eqpreset` v2 migration | PARITY | PR42 migrates channel mode/banks and supported processing/dynamics state. |
| Legacy Pause Gate timing migration | IMPROVED | Semantic translation preserves behavior while moving to the commercial Attack=fade-out/Release=fade-in convention. |
| REW filter-text import/export | PARITY | Audited representable subset has explicit import/export and warnings for unsupported shapes. |
| EasyEffects equalizer import/export | PARITY | Audited EQ subset plus L/R split and input gain; Playback-System output trim is intentionally protected from Content-Preset import. |
| CamillaDSP content-EQ/FIR export | PARITY | Current proprietary EQ graph exports deterministic CamillaDSP YAML for representable IIR/FIR content state. |
| Legacy full CamillaDSP physical-device/matrix writer | SUPERSEDED | The commercial product does not serialize its private HAL Aggregate Device topology into a foreign runtime. PR42 exports portable content DSP and keeps machine-specific Playback System routing authoritative inside Notch Sixty. A richer cross-runtime speaker export remains an optional post-1.0 enhancement. |
| AutoEQ headphone workflow | SUPERSEDED | Headphone-specific workflow remains outside the approved speaker product scope. |
| Resource-backed Room Correction projects | IMPROVED | PR40 uses versioned project storage with deployed-filter independence and recoverable sidecar failure semantics. |

## Room Correction

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| User-initiated microphone permission/device selection | IMPROVED | Dedicated calibration workflow; permission is not requested merely because the app launches. |
| 20 Hz–20 kHz swept-sine measurement | IMPROVED | Independently derived ESS measurement path with bounded calibration-session transport. |
| Multi-sweep / multi-position capture | IMPROVED | Named weighted positions, inclusion/exclusion, preserved individual measurements and three-seat-first UX without hard-coding exactly three. |
| Measurement SNR/quality reporting | IMPROVED | Quality metrics/flags are first-class and poor measurements are retained for review rather than silently discarded. |
| Microphone calibration | IMPROVED | User-selected calibration text is normalized, validated and log-frequency interpolated for analysis. |
| Legacy hybrid free-field/diffuse-field calibration mode | SUPERSEDED | 1.0 uses an explicit user-provided calibration curve rather than silently synthesizing a hybrid calibration assumption. More specialized calibration models remain optional future work. |
| Reflection/time-window analysis controls | SUPERSEDED | 1.0 prioritizes preserved raw IR, confidence/usable-range analysis and conservative correction instead of presenting a legacy “reflection-free” mode as physically absolute. Advanced gating remains optional post-1.0 analysis work. |
| Spatial averaging | IMPROVED | Commercial design averages weighted magnitudes robustly across seats while retaining per-position phase/timing rather than raw-complex cancellation between unrelated seats. |
| Built-in/custom target design | IMPROVED | Editable versioned target points with explicit correction range, smoothing and boost/cut limits. |
| Minimum-phase FIR room correction | IMPROVED | Bounded independently designed FIR with headroom accounting and dedicated runtime ownership. |
| Automatic IIR room-correction fitter | SUPERSEDED | 1.0 intentionally has one reproducible automatic correction-design path (bounded minimum-phase FIR). The main EQ remains available for user-authored low-latency IIR correction; automatic IIR fitting is retained only as a possible post-1.0 enhancement. |
| Measurement-derived automatic excess-phase inversion | SUPERSEDED | 1.0 deliberately avoids aggressive automatic phase inversion without a stronger confidence/verification contract; existing All-Pass/Mixed-Phase tools remain explicit user-controlled mechanisms. |
| Legacy individual-vs-predicted-combined verification mode | SUPERSEDED | PR40 preserves individual position data and supports repeat whole-system measurement after design/deployment; PR42 does not recreate the legacy prediction-overlay workflow as a release requirement. |
| IR / Step / Energy-decay / Group-delay dedicated legacy pages | SUPERSEDED | 1.0 exposes the response, phase/timing and quality information needed to make/deploy correction while preserving raw project data. Dedicated advanced acoustic-diagnostic pages remain post-1.0 analysis enhancements. |
| Measurement/correction persistence | IMPROVED | Versioned project assets and lightweight deployed profile metadata remain separate from Content Presets. |

## Physical routing and Active Crossover

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| 2–8 physical output routes | IMPROVED | Persistent Playback-System-owned logical speaker buses mapped to Core Audio device channels. |
| Same-device multichannel output | IMPROVED | Direct physical channel map on one hardware clock. |
| Multi-device output | IMPROVED | Private Aggregate Device with explicit reference device and HAL drift compensation. |
| Full Range / Low / Mid / High / Sub logical buses | IMPROVED | Typed commercial speaker-bus model. |
| Mains+Sub / Bi-Amp / Tri-Amp crossover | IMPROVED | Dedicated physical speaker splitter after shared processing. |
| LR24 / LR48 lower and upper crossover | PARITY | Commercial Linkwitz-Riley crossover choices with independently designed coefficients. |
| Sub gain / polarity / all-pass phase alignment | IMPROVED | Explicit topology-owned controls and runtime. |
| Mandatory driver-safe crossover under Global Bypass | IMPROVED | Raw DSP bypass cannot accidentally send full-range energy to split drivers. |
| Arbitrary per-output EQ | SUPERSEDED | Not part of the deliberately bounded 1.0 speaker-routing product. Shared EQ + Room Correction remain upstream; driver-specific EQ is retained as a post-1.0 speaker-optimization enhancement rather than silently claimed. |
| Arbitrary per-output gain / polarity / broadband delay | SUPERSEDED | 1.0 exposes the topology-specific controls required by the current Mains+Sub path and stable crossover routing; general driver trims/alignment remain a post-1.0 speaker-optimization enhancement. |
| Per-output limiter/protection | SUPERSEDED | 1.0 uses the shared validated protection stage plus mandatory crossover safety. Driver-specific protection remains post-1.0. |
| Per-output meters | SUPERSEDED | 1.0 uses shared production output metering; driver-bus telemetry remains post-1.0. |
| Group-delay crossover analysis/correction | SUPERSEDED | 1.0 favors explicit crossover settings plus Room Correction measurement/phase information; automated per-driver group-delay correction remains post-1.0. |
| Predicted acoustic summation overlay | SUPERSEDED | 1.0 prioritizes direct acoustic measurement over simplified geometry prediction; measured driver/summation analysis remains post-1.0. |
| Automatic crossover-frequency optimization | SUPERSEDED | 1.0 keeps crossover choices explicit/reviewable rather than running the legacy optimizer. A new optimizer, if added, must use unambiguous candidate-state semantics. |
| Automatic per-output EQ optimization | SUPERSEDED | Same 1.0 decision as crossover optimization; no reproduction of the legacy ambiguous delta-vs-absolute Apply-All behavior. |
| Legacy optimize-slope toggle | SUPERSEDED | Audited no-op; not recreated. |
| Legacy optimize-delay toggle | SUPERSEDED | Audited no-op; not recreated. |
| Broadband driver arrival-time alignment | SUPERSEDED | General automatic per-driver alignment is a post-1.0 speaker-optimization enhancement; current 1.0 does not claim it. |
| Automatic polarity/acoustic-center diagnosis | SUPERSEDED | Measurement-assisted driver diagnosis is retained as post-1.0 work rather than silently acting on a single measurement. |
| Baffle-step recommendation | SUPERSEDED | Specialized driver-design assistant is outside the bounded 1.0 routing/crossover workflow; remains optional post-1.0. |
| Diaphragm-resonance recommendation | SUPERSEDED | Measurement-assisted per-driver EQ assistant remains post-1.0. |
| Automated combined-system crossover verification | SUPERSEDED | 1.0 supports direct Room Correction measurement and manual remeasurement; dedicated speaker-optimizer verification remains post-1.0. |

## Production UI and commercial provenance

| Capability | Disposition | Commercial evidence / rationale |
| --- | --- | --- |
| Production navigation/workspaces | IMPROVED | PR36–PR41 replaced engineering validation surfaces with the commercial shell. |
| Production Equalizer | IMPROVED | Current native SwiftUI editor reflects the commercial EQ model rather than historical UI structure. |
| Production Dynamics | IMPROVED | PR38 capability surface plus PR42 semantic LabeledContent/adaptive-material editor cleanup. |
| Menu bar preset / processing / quit controls | IMPROVED | Fresh production SwiftUI MenuBarExtra exposes the selected Content Preset, start/stop processing through the existing AudioIOEngine lifecycle, main-window access, Settings, and orderly quit without importing legacy implementation code. |
| Legacy owner-controlled tray icon artwork | PORT VERIFIED | Reuses only the project-owner-controlled vector TrayIcon artwork as a template-rendered asset; production behavior is independently implemented. |
| App identity/icon assets | PORT VERIFIED | PR39 records that the analog-meter artwork is user-authored; production light/dark derivatives are owner-approved and retained with vector sources. |
| Third-party production dependencies | PARITY | None are linked into the production application; Apple platform frameworks and public specifications are not bundled third-party code. |

## Post-1.0 enhancement register

The following are intentionally **not claims of current implementation**. They remain useful future product opportunities after commercial 1.0 hardening:

- automatic low-latency IIR Room Correction fitting;
- validated measurement-derived excess-phase correction;
- dedicated IR / Step / Energy Decay / Group Delay acoustic-analysis pages;
- arbitrary per-driver EQ, trim, polarity, fractional delay, protection and metering;
- measured driver group-delay/summation visualization;
- measurement-assisted crossover and per-driver EQ optimization;
- automatic driver arrival/polarity/acoustic-center diagnosis;
- baffle-step and diaphragm-resonance assistants;
- richer cross-runtime CamillaDSP speaker-matrix export;
- app-owned fixed-bit-depth export with technically appropriate dither.

These items are excluded from PR42's release gate because the 1.0 product has an explicit narrower replacement/ownership model. They may become separately scoped milestones without reopening the clean-room provenance decision.

## Closure result

Every legacy capability identified by the PR34 audits now has an explicit final commercial disposition. There are no unresolved release-blocking rows in this matrix.
