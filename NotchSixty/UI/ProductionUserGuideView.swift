import SwiftUI

enum ProductionUserGuideCategory: String, CaseIterable, Identifiable, Hashable {
    case gettingStarted
    case playback
    case processing
    case measurement
    case acoustics
    case advanced
    case reference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .playback: return "Playback"
        case .processing: return "Processing"
        case .measurement: return "Measurement & Calibration"
        case .acoustics: return "Speakers & Acoustics"
        case .advanced: return "Advanced Tools"
        case .reference: return "Reference"
        }
    }

    var systemImage: String {
        switch self {
        case .gettingStarted: return "sparkles"
        case .playback: return "play.circle"
        case .processing: return "waveform.path.ecg"
        case .measurement: return "waveform.badge.magnifyingglass"
        case .acoustics: return "hifispeaker.2"
        case .advanced: return "wrench.and.screwdriver"
        case .reference: return "function"
        }
    }
}

enum ProductionUserGuideMathScope: String, Hashable {
    case coreEquation
    case implementationRelationship
    case diagnosticModel

    var title: String {
        switch self {
        case .coreEquation: return "Core equation"
        case .implementationRelationship: return "Implementation relationship"
        case .diagnosticModel: return "Diagnostic / model definition"
        }
    }

    var systemImage: String {
        switch self {
        case .coreEquation: return "equal.circle"
        case .implementationRelationship: return "point.3.connected.trianglepath.dotted"
        case .diagnosticModel: return "chart.xyaxis.line"
        }
    }
}

struct ProductionUserGuideFormula: Identifiable, Hashable {
    let id: String
    let title: String
    let expression: String
    let explanation: String
    let scope: ProductionUserGuideMathScope
}

struct ProductionUserGuideSection: Identifiable, Hashable {
    let id: String
    let title: String
    let paragraphs: [String]
}

struct ProductionUserGuideArticle: Identifiable, Hashable {
    let id: String
    let category: ProductionUserGuideCategory
    let title: String
    let summary: String
    let systemImage: String
    let keywords: [String]
    let sections: [ProductionUserGuideSection]
    let formulas: [ProductionUserGuideFormula]

    var searchableText: String {
        (
            [title, summary]
            + keywords
            + sections.flatMap { [$0.title] + $0.paragraphs }
            + formulas.flatMap {
                [$0.title, $0.expression, $0.explanation, $0.scope.title]
            }
        )
        .joined(separator: " ")
        .lowercased()
    }
}


enum ProductionWorkflowTerm: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case apply = "Apply"
    case verify = "Verify"
    case revert = "Revert"
    case rollback = "Rollback"
    case deploy = "Deploy"

    var id: String { rawValue }

    var definition: String {
        switch self {
        case .preview:
            return "Calculate or display a proposed result without changing saved or live playback state."
        case .apply:
            return "Make an explicit state change. In measurement-driven workflows, Apply can be provisional until fresh verification passes."
        case .verify:
            return "Collect or evaluate fresh evidence after a change to confirm that the intended result was actually achieved."
        case .revert:
            return "Discard uncommitted editor or draft changes and return to the previously saved value before a live Apply."
        case .rollback:
            return "Restore the exact retained pre-Apply state after a live or saved change has already occurred."
        case .deploy:
            return "Move a reviewed offline design into the selected Playback System so it becomes part of that system's playback configuration."
        }
    }
}

enum ProductionUserGuideCatalog {
    static let articles: [ProductionUserGuideArticle] = [
        article(
            id: "getting-started",
            category: .gettingStarted,
            title: "Getting Started",
            summary: "A non-intrusive first-session path from permissions and output selection to safe playback, optional measurement and your first Content Preset.",
            systemImage: "sparkles",
            keywords: [
                "first run", "first session", "permissions", "system audio",
                "microphone", "output", "safe level", "start processing",
                "preset", "playback system", "calibration", "backup",
                "safe launch"
            ],
            sections: [
                section(
                    "permissions",
                    "1. Grant only the permissions you need",
                    [
                        "Ordinary playback processing may cause macOS to request System Audio access. If you previously denied it and processing receives no system audio, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.",
                        "Measurement Microphone access is separate and is not required for ordinary listening. Request it only when you choose to measure or calibrate. A calibration-file workflow can identify microphone response, but it does not turn a microphone or measurement into hardware-acceptance evidence."
                    ]
                ),
                section(
                    "output-system",
                    "2. Choose the real output and Playback System",
                    [
                        "Select the physical output device you actually intend to use. Notch Sixty deliberately follows stable device identity rather than silently substituting the current macOS default output.",
                        "Choose the Playback System that describes the connected loudspeakers, subwoofers or headphones. A restored system marked Needs Mapping must be reviewed before activation; do not use a Content Preset to hide a hardware mismatch.",
                        "Before first sound, set the amplifier or downstream system to a conservative listening level and verify that the expected output, crossover and routing are selected."
                    ]
                ),
                section(
                    "first-sound",
                    "3. Make first sound deliberately",
                    [
                        "Start Processing only after routing and system state look correct. Processing never starts merely because Notch Sixty launches or because Launch at Login is enabled.",
                        "Use familiar program material at a conservative level. Confirm that the expected device is producing sound and that Dashboard or Meters activity follows the program. Global Bypass provides a fast processed-versus-unprocessed check without discarding configuration.",
                        "After basic playback is stable, Meters → Dynamics can show true-peak and gain-structure evidence. Headroom Assistant is optional: use a representative loud passage, not a quiet excerpt, and treat its result as an advisory reserve recommendation rather than a guarantee about every possible recording."
                    ]
                ),
                section(
                    "content",
                    "4. Choose or create your first Content Preset",
                    [
                        "Playback Systems describe the physical playback chain; Content Presets describe content-facing DSP such as EQ, gain and dynamics. Keep those roles separate so a music or cinema preset remains portable across listening sessions without silently changing physical routing.",
                        "Use A/B when comparing two content-DSP choices. Its snapshots cannot change the Playback System, and measured level matching only attenuates the louder captured side so loudness is less likely to bias the comparison."
                    ]
                ),
                section(
                    "optional-calibration",
                    "5. Add measurement and calibration only when useful",
                    [
                        "Speaker Calibration, Measurement Lab and Room Correction are optional next steps after ordinary playback works correctly. Use the measurement microphone and its calibration data when accuracy matters, and keep the documented microphone placement, routing and provenance with the evidence.",
                        "Preview measurement-derived changes before Apply, verify after Apply, and retain rollback where the workflow provides it. Software plausibility, confidence and CI results do not replace an acoustic verification or the separate PR112 physical hardware-acceptance process."
                    ]
                ),
                section(
                    "recovery-backup",
                    "6. Protect a good setup",
                    [
                        "Settings → Backup & Restore can save a .n60backup before major system changes. Restored hardware identities that are unavailable on a different Mac remain Needs Mapping rather than being silently rebound.",
                        "If a prior launch ended unexpectedly or repeated audio / plug-in starts fail, Safe Launch keeps audio idle and offers Open Normally, a temporary Plug-ins Bypassed launch, Restore Last Known Good and Copy Diagnostics. Recovery does not overwrite physical-acceptance authority.",
                        "Copy Diagnostics when troubleshooting or asking for support. Diagnostics are evidence about software/runtime state, not permission to deploy an unverified physical configuration."
                    ]
                ),
                section(
                    "signal-flow",
                    "How to think about Notch Sixty",
                    [
                        "Notch Sixty separates transport, Playback-System configuration, content-facing DSP and measurement workflows. That separation is intentional: measurement evidence should describe the actual system, while music or cinema presets can remain flexible.",
                        "Use the workflow vocabulary literally: Preview shows a proposal, Apply makes an explicit change, Verify collects fresh evidence, Revert discards uncommitted edits, Rollback restores retained pre-Apply state, and Deploy moves a reviewed offline design into the selected Playback System."
                    ]
                )
            ]
        ),
        article(
            id: "dashboard",
            category: .playback,
            title: "Dashboard",
            summary: "The daily status surface for output routing, VU meters, master level, bypass and major DSP stages.",
            systemImage: "gauge.with.dots.needle.50percent",
            keywords: ["dashboard", "master volume", "mute", "global bypass", "output", "VU"],
            sections: [
                section(
                    "daily-controls",
                    "Daily controls",
                    [
                        "Use the Dashboard for output selection, processing start/stop, software master volume, mute and Global Bypass. The summary cards report the current state of the major processing families without requiring you to open each editor.",
                        "The signature VU meters use RMS level referenced so that 0 VU corresponds to −18 dBFS. They are a monitoring aid, not a loudness standard or a substitute for true-peak protection."
                    ]
                )
            ],
            formulas: [
                formula(
                    "linear-db",
                    "Linear amplitude and decibels",
                    "dB = 20 · log₁₀(|x|)    and    x = 10^(dB/20)",
                    "Audio amplitude ratios are converted to decibels with 20·log₁₀. The Dashboard meter uses this relationship before applying the displayed VU reference.",
                    .coreEquation
                ),
                formula(
                    "vu-reference",
                    "Notch Sixty VU reference",
                    "VU = dBFS − (−18 dBFS)",
                    "The displayed working reference is 0 VU = −18 dBFS. The analog-style scale then uses a deliberately non-linear visual mapping so the region near 0 VU receives more angular resolution.",
                    .implementationRelationship
                )
            ]
        ),
        article(
            id: "equalizer",
            category: .processing,
            title: "Equalizer",
            summary: "Stereo-linked or channel-specific parametric EQ with minimum-phase and linear-phase processing.",
            systemImage: "slider.horizontal.3",
            keywords: ["EQ", "parametric", "biquad", "Q", "minimum phase", "linear phase", "FIR", "frequency"],
            sections: [
                section(
                    "when",
                    "When to use it",
                    [
                        "Use manual EQ for deliberate tonal shaping or narrowly scoped corrections you understand. Room Correction and Speaker Calibration are better choices when the change should be derived from measurements.",
                        "Minimum-phase EQ is the low-latency default for ordinary tone shaping. Linear-phase processing trades additional latency for a symmetric impulse response and phase behavior that can be useful in selected correction tasks."
                    ]
                ),
                section(
                    "controls",
                    "Controls and cautions",
                    [
                        "Frequency selects the band center or corner, gain sets boost/cut, and Q controls bandwidth. Higher Q is narrower. Avoid using large boosts to fill deep acoustic nulls; those often come from cancellation and consume headroom without solving the underlying geometry.",
                        "Processed / Reference and Delta monitoring are useful when judging whether an EQ change is solving the intended problem rather than simply becoming louder."
                    ]
                )
            ],
            formulas: [
                formula(
                    "biquad",
                    "Biquad transfer function",
                    "H(z) = (b₀ + b₁z⁻¹ + b₂z⁻²) / (1 + a₁z⁻¹ + a₂z⁻²)",
                    "Minimum-phase parametric bands are implemented as second-order IIR sections. Filter type, center/corner frequency, Q and gain determine the coefficients.",
                    .coreEquation
                ),
                formula(
                    "fir-convolution",
                    "FIR convolution",
                    "y[n] = Σₖ h[k] · x[n−k]",
                    "Linear-phase EQ is realized with FIR filtering. Notch Sixty uses partitioned convolution for realtime efficiency, but the underlying operation is still convolution by the filter impulse response.",
                    .coreEquation
                ),
                formula(
                    "linear-phase-delay",
                    "Symmetric FIR group delay",
                    "τ = (N−1) / (2fₛ)",
                    "For an odd/even symmetric linear-phase FIR of N taps, the filter's constant group delay is set by tap count and sample rate. Runtime latency also includes buffering and any other active latency-producing stage.",
                    .implementationRelationship
                )
            ]
        ),
        article(
            id: "dynamics",
            category: .processing,
            title: "Dynamics",
            summary: "Compression, expansion, pause gating, limiting, denoising and related level-dependent processing.",
            systemImage: "waveform.path.ecg",
            keywords: ["compressor", "expander", "gate", "pause gate", "limiter", "true peak", "oversampling", "denoiser"],
            sections: [
                section(
                    "order",
                    "Use dynamics deliberately",
                    [
                        "Dynamics processors react to signal level over time. Small changes in threshold, ratio and time constants can be more transparent than aggressive settings.",
                        "For the Pause Gate, Attack is the fade-out time and Release is the fade-in time. The interface keeps the conventional names while presenting fade-out before fade-in so the audible behavior is clear.",
                        "The true-peak limiter is the final protection stage for preventing peaks above its ceiling. Oversampling improves detection and non-linear processing around inter-sample peaks, but it should not create a material level change by itself."
                    ]
                )
            ],
            formulas: [
                formula(
                    "compressor-ratio",
                    "Compressor steady-state mapping",
                    "y_dB = T + (x_dB − T)/R    for x_dB > T",
                    "Above threshold T, a ratio R:1 reduces the amount by which output rises above threshold. Knee behavior and detector smoothing modify the transition, not this basic ratio relationship.",
                    .coreEquation
                ),
                formula(
                    "expander-ratio",
                    "Downward expansion relationship",
                    "y_dB = T + Rₑ(x_dB − T)    for x_dB < T",
                    "Below threshold, an expansion ratio Rₑ greater than 1 increases attenuation as the signal falls. The production processor adds time constants and bounded gain behavior around this relationship.",
                    .coreEquation
                ),
                formula(
                    "time-constant",
                    "Envelope smoothing coefficient",
                    "a = exp(−1 / (τ · fₛ))",
                    "Attack and release envelopes are one-pole smoothing processes parameterized by time constant τ and sample rate fₛ. Different stages can use separate attack and release coefficients.",
                    .implementationRelationship
                )
            ]
        ),
        article(
            id: "meters",
            category: .playback,
            title: "Meters",
            summary: "Peak/RMS, true peak, spectrum, phase correlation, crest factor and other production analysis.",
            systemImage: "chart.xyaxis.line",
            keywords: ["meters", "RMS", "peak", "true peak", "RTA", "spectrum", "phase correlation", "crest factor"],
            sections: [
                section(
                    "interpret",
                    "Interpreting the meters",
                    [
                        "Peak and true-peak meters answer different questions: sample peak reports stored sample magnitude, while true peak estimates the reconstructed waveform between samples.",
                        "RMS and spectrum views describe energy distribution. Phase correlation is most useful as a warning about stereo compatibility; it does not by itself tell you whether a mix sounds wide or natural."
                    ]
                )
            ],
            formulas: [
                formula(
                    "rms",
                    "RMS amplitude",
                    "RMS = √[(1/N) · Σₙ x[n]²]",
                    "RMS is the square root of mean signal power over the analysis window.",
                    .coreEquation
                ),
                formula(
                    "crest",
                    "Crest factor",
                    "Crest_dB = 20 · log₁₀(Peak / RMS)",
                    "Crest factor compares transient peak level with average energy over the same observation interval.",
                    .coreEquation
                ),
                formula(
                    "correlation",
                    "Stereo correlation",
                    "ρ = Σ(L·R) / √[ΣL² · ΣR²]",
                    "Normalized correlation approaches +1 for highly similar in-phase channels, 0 for weakly related channels and −1 for strongly anti-correlated channels.",
                    .coreEquation
                )
            ]
        ),
        article(
            id: "speakers",
            category: .acoustics,
            title: "Speakers",
            summary: "Playback-system routing, bass management, crossover protection, delay, polarity and loudspeaker topology.",
            systemImage: "hifispeaker.2.fill",
            keywords: ["speakers", "bass management", "crossover", "subwoofer", "delay", "polarity", "Linkwitz Riley", "LR24", "LR48"],
            sections: [
                section(
                    "topology",
                    "System topology comes first",
                    [
                        "Describe the real loudspeaker and subwoofer topology before applying correction. Bass management, channel routing, protected active-driver workflows and coherent Sub alignment all depend on that topology.",
                        "A passive two-way loudspeaker driven by one amplifier channel does not expose independent woofer and tweeter DSP lanes. Per-driver measurement and commissioning require genuinely independent, protected outputs."
                    ]
                ),
                section(
                    "bass",
                    "Bass management",
                    [
                        "The crossover separates low-frequency content routed to the Sub from content retained by the mains. LR24 and LR48 options are designed for complementary acoustic summation when the connected system behaves as assumed.",
                        "Delay and polarity should be changed from coherent measurements when possible, especially around the Main/Sub crossover region."
                    ]
                )
            ],
            formulas: [
                formula(
                    "linkwitz-riley",
                    "Linkwitz–Riley construction",
                    "H_LR,2m(s) = [H_BW,m(s)]²",
                    "An even-order Linkwitz–Riley crossover is formed by cascading identical Butterworth sections. This relationship describes the filter family; the implemented digital coefficients are calculated for the selected sample rate and crossover frequency.",
                    .implementationRelationship
                ),
                formula(
                    "delay-phase",
                    "Delay-to-phase relationship",
                    "φ(f) = 2πfΔt",
                    "A relative time offset Δt creates a frequency-dependent phase offset. Polarity inversion contributes an additional π radians (180°).",
                    .coreEquation
                )
            ]
        ),
        article(
            id: "headphones",
            category: .playback,
            title: "Headphones",
            summary: "Headphone system profiles, binaural rendering, SOFA/HRTF data and head-tracking foundations.",
            systemImage: "headphones",
            keywords: ["headphones", "binaural", "HRTF", "SOFA", "head tracking", "virtual speakers"],
            sections: [
                section(
                    "binaural",
                    "Binaural rendering",
                    [
                        "Binaural mode renders virtual loudspeaker directions through left/right head-related impulse responses. SOFA assets describe directional HRTF/HRIR measurements used by the renderer.",
                        "Head tracking changes the relative virtual source direction so the acoustic scene can remain stable as the listener turns. The quality of the result depends heavily on the HRTF data and the accuracy of the pose estimate."
                    ]
                )
            ],
            formulas: [
                formula(
                    "binaural-convolution",
                    "Per-ear binaural rendering",
                    "y_L[n] = Σₛ xₛ[n] * hₛ,L[n]    ;    y_R[n] = Σₛ xₛ[n] * hₛ,R[n]",
                    "Each virtual source is convolved with the corresponding left- and right-ear directional impulse responses, then summed at each ear.",
                    .coreEquation
                )
            ]
        ),
        article(
            id: "speaker-calibration",
            category: .measurement,
            title: "Speaker Calibration",
            summary: "Guided measurement-driven speaker optimization, PEQ/FIR candidates, verification and rollback.",
            systemImage: "speaker.wave.3.fill",
            keywords: ["speaker calibration", "speaker optimizer", "PEQ", "FIR", "verification", "rollback", "candidate"],
            sections: [
                section(
                    "workflow",
                    "Measure → design → verify",
                    [
                        "Speaker Calibration starts from repeat-qualified measurements, designs bounded candidate corrections, previews the intended change, then requires a fresh post-Apply verification before the result is considered accepted.",
                        "PEQ and FIR are alternative correction tools with different tradeoffs. The optimizer avoids treating deep cancellation nulls as ordinary boost targets and keeps rollback provenance for deployed corrections."
                    ]
                )
            ],
            formulas: [
                formula(
                    "target-error",
                    "Measured target error",
                    "E_dB(f) = T_dB(f) − M_dB(f)",
                    "Candidate design begins from the difference between the chosen target T and qualified measured response M, then applies smoothing, correction-range policy and boost/cut bounds before creating a realizable filter.",
                    .implementationRelationship
                ),
                formula(
                    "verified-improvement",
                    "Before/after verification",
                    "ΔE(f) = |E_before(f)| − |E_after(f)|",
                    "Verification asks whether fresh measured error moved in the intended direction. Acceptance also depends on qualification, identity matching and safety/rollback rules, not this scalar relationship alone.",
                    .diagnosticModel
                )
            ]
        ),
        article(
            id: "measurement-lab",
            category: .measurement,
            title: "Measurement Lab",
            summary: "Advanced repeatable acoustic capture for transfer function, timing, phase, directivity and protected-driver evidence.",
            systemImage: "waveform.badge.magnifyingglass",
            keywords: ["measurement lab", "sweep", "impulse response", "transfer function", "phase", "SNR", "directivity", "driver"],
            sections: [
                section(
                    "capture",
                    "What a qualified capture means",
                    [
                        "Measurement Lab records repeated, identity-bound acoustic captures rather than trusting a single sweep. Qualification checks include source, microphone, routing, sample rate, clipping, repeat count and stability appropriate to the protocol.",
                        "Protected Low/Mid/High driver protocols add crossover, limiter and physical-route provenance. They are never a license to connect an unprotected driver directly to a full-range amplifier output."
                    ]
                ),
                section(
                    "reference",
                    "Electrical reference and coherent timing",
                    [
                        "Timing and phase comparisons that need a common time origin use a simultaneous electrical reference on the same ADC timeline. Independent clocks cannot establish coherent relative arrival.",
                        "Never connect a speaker-level amplifier output directly to a line-level ADC input. Use a documented, safe reference interface."
                    ]
                )
            ],
            formulas: [
                formula(
                    "transfer",
                    "Transfer function",
                    "H(f) = Y(f) / X(f)",
                    "After synchronized excitation/capture and appropriate regularization/windowing, the measured output spectrum Y is referenced to excitation X to estimate the system transfer function.",
                    .coreEquation
                ),
                formula(
                    "impulse",
                    "Impulse response",
                    "h[n] = IFFT{H(f)}",
                    "The time-domain impulse response is obtained from the qualified transfer function and is the basis for arrival, windowed magnitude and phase analysis.",
                    .coreEquation
                ),
                formula(
                    "snr",
                    "Signal-to-noise ratio",
                    "SNR_dB = 20 · log₁₀(A_signal / A_noise)",
                    "Measurement qualification compares usable signal against the noise floor. The exact windows and thresholds are protocol-specific.",
                    .implementationRelationship
                )
            ]
        ),
        article(
            id: "room-correction",
            category: .measurement,
            title: "Room Correction",
            summary: "Multi-position measurement, target design, bounded correction and FIR deployment.",
            systemImage: "waveform.badge.magnifyingglass",
            keywords: ["room correction", "target curve", "multi-seat", "FIR", "measurement", "averaging", "smoothing"],
            sections: [
                section(
                    "workflow",
                    "Room correction workflow",
                    [
                        "Measure named listening positions with a calibrated microphone, review measurement quality, select or import a target, choose the correction range and correction limits, then generate the correction filter.",
                        "Multi-position correction is intended to improve a listening region rather than over-fit one microphone point. Correction limits protect headroom and prevent the filter from trying to fill deep geometry-driven nulls."
                    ]
                )
            ],
            formulas: [
                formula(
                    "bounded-correction",
                    "Bounded target correction",
                    "C_dB(f) = clamp[T_dB(f) − M_dB(f), −CutLimit, +BoostLimit]",
                    "This is the core target-error relationship. The production designer also applies frequency-range policy, smoothing, measurement confidence and FIR realization constraints.",
                    .implementationRelationship
                ),
                formula(
                    "minimum-phase-fir",
                    "Minimum-phase FIR synthesis",
                    "L[k] = C_dB[k] · ln(10)/20;  c = IFFT{L};  c_min[n>0] = 2c[n] for n<N/2;  h = IFFT{exp(FFT{c_min})}",
                    "Room Correction converts the desired dB correction to a log-magnitude spectrum, transforms it to the real cepstrum, keeps the causal minimum-phase cepstrum by doubling positive-time coefficients, exponentiates the resulting complex log spectrum, and transforms back to FIR taps. This is a causal minimum-phase design, not a symmetric linear-phase FIR; total playback latency is reported separately by the complete DSP path.",
                    .implementationRelationship
                )
            ]
        ),
        article(
            id: "active-acoustics",
            category: .advanced,
            title: "Active Acoustics",
            summary: "Ambient analysis, adaptive compensation, room treatment and hardware-gated quiet-zone/feed-forward workflows.",
            systemImage: "waveform.and.mic",
            keywords: ["active acoustics", "ambient", "adaptive EQ", "room treatment", "quiet zone", "feed forward", "ANC", "causality"],
            sections: [
                section(
                    "scope",
                    "Analysis is not authorization",
                    [
                        "Ambient Analysis can characterize environmental change and drive bounded adaptive behavior. Active room-treatment and quiet-zone features have stronger commissioning requirements because they create additional acoustic output.",
                        "Feed-forward noise control is fundamentally constrained by causality: the upstream reference must provide enough preview time for input, processing, output and acoustic propagation. Software plausibility checks never replace physical speaker-safety acceptance."
                    ]
                )
            ],
            formulas: [
                formula(
                    "causality-budget",
                    "Feed-forward causality budget",
                    "B = t_preview − (t_input + t_DSP + t_output + t_anti-noise-path)",
                    "A positive reserve B means the reference signal arrives early enough in the model to make cancellation physically plausible. Actual authorization additionally requires measured clocks, paths, stability, attenuation and emergency-mute safety.",
                    .diagnosticModel
                )
            ]
        ),
        article(
            id: "room-advisor",
            category: .acoustics,
            title: "Room Advisor",
            summary: "Read-only geometry, placement and passive-treatment guidance backed by explicit assumptions and measured A/B evidence where available.",
            systemImage: "wand.and.stars.inverse",
            keywords: ["room advisor", "placement", "toe in", "sub placement", "seats", "treatment", "geometry", "A/B"],
            sections: [
                section(
                    "read-only",
                    "Advice, not automatic deployment",
                    [
                        "Room Advisor proposes bounded physical experiments and treatment ideas. Inspecting a proposal never edits the saved room, moves a speaker in the model behind your back, or changes DSP.",
                        "Subwoofer placement comparisons can use fresh before/after measurements across multiple seats. Common gain shifts are normalized so a louder candidate is not automatically scored as more uniform."
                    ]
                )
            ],
            formulas: [
                formula(
                    "lf-variation",
                    "Frequency-normalized inter-seat LF variation",
                    "σ_LF = √mean₍s,f₎[(L_s(f) − meanₛ L_s(f))²]",
                    "For each low-frequency bin, common level is removed across seats before the residual variation is aggregated. This makes the placement comparison sensitive to seat-to-seat consistency rather than simple gain.",
                    .diagnosticModel
                )
            ]
        ),
        article(
            id: "blind-listening",
            category: .advanced,
            title: "Blind Listening",
            summary: "Explore differences between two local, carefully matched audio excerpts with randomized A/B/X trials.",
            systemImage: "ear.badge.waveform",
            keywords: ["blind", "ABX", "listening", "trial", "statistical", "p-value", "audio test"],
            sections: [
                section(
                    "abx-start",
                    "Prepare a fair, safe offline comparison",
                    [
                        "Stop Notch Sixty live processing before using Blind Listening. This tool plays user-provided audio files through macOS default audio playback at reduced software volume; it does not switch processing presets or verify the selected device. Start with your system hardware volume low.",
                        "Import two stereo PCM excerpts of the same passage and length, with identical sample rate, arrangement and mastering except for the deliberately compared difference. The app refuses file RMS mismatch greater than 0.10 dB and unsafe sample peaks; this is not a perceptual loudness-match or an alignment proof."
                    ]
                ),
                section(
                    "abx-use",
                    "Listen to A, B and the hidden X source",
                    [
                        "Choose 12, 16 or 24 trials. During each trial, audition the known A and B references and hidden X, then guess whether X matches A or B. The hidden assignment changes independently on every trial, without a predictable fixed balance. X must be played before making a choice.",
                        "After all trials, the app reveals the count correct and an exact one-sided binomial fair-guess probability. Even a low p-value does not establish universal audibility, physical acoustic improvement, headphone SPL safety, or release approval. You can export the evidence as JSON, or leave it on-device."
                    ]
                )
            ]
        ),
        article(
            id: "acoustic-research",
            category: .advanced,
            title: "Acoustic Research",
            summary: "Experimental mixed-phase FIR, measured HRTF interpolation, and local headphone model fitting.",
            systemImage: "waveform.path.ecg.rectangle",
            keywords: ["mixed phase", "pre-ringing", "room", "SOFA", "HRTF", "personalization", "headphone model", "correction"],
            sections: [
                section(
                    "research-mixed-phase",
                    "Offline mixed-phase FIR comparisons",
                    [
                        "Select and generate an existing Room Correction minimum-phase FIR. Tools → Acoustic Research can form a bounded mixed-phase candidate by blending a symmetric FIR component and reviewing its actual Fourier magnitude, pre-ringing, A/V delay and headroom. The preview is not installed and cannot establish better room acoustics without a new physical measurement.",
                        "Larger linear shares can increase ringing, shift phase, alter the target magnitude or exceed latency/headroom. Any blocked proposal stays unapplied."
                    ]
                ),
                section(
                    "research-spatial",
                    "HRTF coverage and listener-guided audition",
                    [
                        "Import an actual source-attributed AES69 SOFA/HRTF in Headphones. Acoustic Research checks whether requested spatial directions are close enough to recorded measurements and generates an offline onset-aligned interpolation preview. If directional coverage is absent, it refuses to invent a personalized HRTF.",
                        "Listen to stored candidate profiles using the ordinary Headphones profile workflow, with low hardware volume. Record a subjective 1–5 preference; the rating is local and does not establish individual HRTF transfer accuracy or headphone safety."
                    ]
                ),
                section(
                    "research-headphones",
                    "Local model measurement correction library",
                    [
                        "In Headphones, import a user-supplied attributed model-response JSON file. It must contain explicit increasing frequency points, separate left/right measured magnitudes, an explicit desired target and source attribution/license metadata. The fitter proposes bounded peak filters per ear using the product's actual biquad design. The model is not individualized for your ears or seal.",
                        "Review modeled target error, worst-frequency regression, conservative attenuation, source rights, and every editable PEQ band before staging. The existing stopped-playback Apply and sample-rate rules remain authoritative; no third-party database is bundled or automatically downloaded."
                    ]
                )
            ]
        ),
        article(
            id: "hardware-acceptance",
            category: .advanced,
            title: "Hardware Acceptance",
            summary: "Append-only H01–H08 evidence for real device, endurance, safety and acoustic acceptance.",
            systemImage: "checkmark.shield.fill",
            keywords: ["hardware acceptance", "H01", "H08", "evidence", "physical", "independent review", "safety"],
            sections: [
                section(
                    "authority",
                    "Evidence authority",
                    [
                        "Hardware Acceptance separates remote-software evidence, physical-hardware evidence and independent physical review. A CI test labeled PASS cannot satisfy a gate that requires real hardware authority.",
                        "Campaign identity freezes the source commit, build, Playback System and conditional scope. Observations are append-only; a newer failure intentionally supersedes a stale earlier pass.",
                        "H05 whole-speaker Measurement Lab acceptance remains mandatory. Protected split-driver work, coherent independently routed Sub alignment and live feed-forward ANC are conditional capabilities with explicit scope decisions."
                    ]
                )
            ]
        ),
        article(
            id: "plugins",
            category: .advanced,
            title: "Plug-ins",
            summary: "Audio Unit hosting with controlled preparation, activation and failure boundaries.",
            systemImage: "puzzlepiece.extension",
            keywords: ["plugins", "plug-ins", "Audio Unit", "AU", "rack", "latency"],
            sections: [
                section(
                    "rack",
                    "Using the Audio Unit rack",
                    [
                        "Audio Units are prepared outside the realtime callback and activated through controlled rack mutations. A failed preparation should not silently rewrite the saved rack or tear down the live graph underneath audio processing.",
                        "Third-party plug-ins can add their own latency, CPU load and failure modes. Re-check total latency and stability after changing a rack, especially before measurement or A/V-sensitive use."
                    ]
                )
            ]
        ),
        article(
            id: "settings",
            category: .reference,
            title: "Preferences & App Behavior",
            summary: "Appearance, volume-key resolution, app presence, launch-at-login, permissions, diagnostics and support.",
            systemImage: "gearshape",
            keywords: ["preferences", "settings", "appearance", "volume keys", "menu bar", "launch at login", "permissions", "diagnostics"],
            sections: [
                section(
                    "preferences",
                    "Application preferences",
                    [
                        "Volume-key step size changes Notch Sixty's software master-volume increment; it does not redefine the physical output device's hardware volume step.",
                        "Launch at Login is optional and does not automatically start audio processing. System-audio and microphone permissions are requested only when the relevant workflows need them.",
                        "Copy Diagnostics includes application/build identity, macOS, selected audio device/rate, preset/system state and DSP latency. It intentionally excludes captured audio and room-measurement samples."
                    ]
                )
            ]
        ),
        article(
            id: "workflow-glossary",
            category: .reference,
            title: "Workflow & DSP Glossary",
            summary: "The product vocabulary used for state changes, verification, measurement confidence and common DSP concepts.",
            systemImage: "text.book.closed",
            keywords: [
                "preview", "apply", "verify", "revert", "rollback", "deploy",
                "dBFS", "dBTP", "Q", "FIR", "IIR", "phase", "coherence",
                "latency", "confidence", "headroom", "evidence authority"
            ],
            sections: [
                section(
                    "workflow-verbs",
                    "Workflow verbs",
                    ProductionWorkflowTerm.allCases.map {
                        "\($0.rawValue) — \($0.definition)"
                    }
                ),
                section(
                    "levels",
                    "Level & headroom",
                    [
                        "dBFS — digital level relative to full scale. 0 dBFS is the maximum representable sample magnitude; ordinary playback should retain margin below it.",
                        "dBTP — estimated true-peak level of the reconstructed waveform, including inter-sample peaks. The true-peak limiter protects against this quantity rather than sample peak alone.",
                        "Headroom — remaining level margin before the relevant ceiling or overload boundary. Boost, correction filters and plug-ins can consume headroom even when master volume is unchanged."
                    ]
                ),
                section(
                    "filters",
                    "Filters & time",
                    [
                        "IIR — an infinite-impulse-response recursive filter. Parametric minimum-phase EQ uses second-order IIR biquads.",
                        "FIR — a finite-impulse-response filter expressed as a finite coefficient sequence. FIR is used where controlled impulse/phase behavior or measured correction requires convolution.",
                        "Q — the filter selectivity parameter used by the biquad design. Higher Q produces a narrower affected region around the center frequency for the same filter family.",
                        "Phase — angular relationship between frequency components. A fixed time delay creates frequency-dependent phase rotation.",
                        "Latency — elapsed time added by buffering, filtering, plug-ins and transport. Notch Sixty reports the complete DSP path rather than treating FIR delay as the only contributor."
                    ]
                ),
                section(
                    "measurement",
                    "Measurement & evidence",
                    [
                        "Coherence — evidence that compared signals share a trustworthy timing/reference relationship. It is not synonymous with a visually smooth response curve.",
                        "Confidence — a bounded assessment of how strongly available repeated evidence supports a conclusion. Confidence does not upgrade software/model evidence into physical acceptance.",
                        "Evidence authority — the provenance class that determines what an observation is allowed to establish. Remote software, physical hardware and independent physical review remain intentionally distinct."
                    ]
                )
            ]
        ),
        article(
            id: "math-reference",
            category: .reference,
            title: "Math & DSP Reference",
            summary: "Notation and recurring relationships used throughout the feature-specific math sections.",
            systemImage: "function",
            keywords: ["math", "DSP", "reference", "decibels", "frequency", "phase", "latency", "sample rate", "Q"],
            sections: [
                section(
                    "notation",
                    "Notation",
                    [
                        "f is frequency in hertz, fₛ is sample rate in samples per second, n is a discrete-time sample index, N is a window or filter length, and Δt is a time difference in seconds.",
                        "Magnitude relationships use 20·log₁₀ for amplitude and 10·log₁₀ for power. Phase is shown in radians in equations and commonly displayed in degrees in the UI.",
                        "Feature articles distinguish core equations from implementation relationships and diagnostic/model definitions. A diagnostic equation describes the metric the product is reasoning about; it is not automatically a physical acceptance claim."
                    ]
                )
            ],
            formulas: [
                formula(
                    "samples-time",
                    "Samples and time",
                    "t = N / fₛ    ;    N = t · fₛ",
                    "Convert between frame/sample counts and seconds using the active sample rate.",
                    .coreEquation
                ),
                formula(
                    "phase-time",
                    "Phase from time offset",
                    "φ(f) = 2πfΔt",
                    "A fixed delay becomes progressively larger phase rotation as frequency rises.",
                    .coreEquation
                )
            ]
        )
    ]

    static func article(id: String) -> ProductionUserGuideArticle? {
        articles.first { $0.id == id }
    }

    static func search(_ query: String) -> [ProductionUserGuideArticle] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return articles }
        return articles.filter { article in
            terms.allSatisfy { article.searchableText.contains($0) }
        }
    }

    static func articleID(for section: ProductionSection) -> String {
        switch section {
        case .dashboard: return "dashboard"
        case .equalizer: return "equalizer"
        case .dynamics: return "dynamics"
        case .meters: return "meters"
        case .speakers: return "speakers"
        case .headphones: return "headphones"
        case .speakerCalibration: return "speaker-calibration"
        case .measurementLab: return "measurement-lab"
        case .roomCorrection: return "room-correction"
        case .activeAcoustics: return "active-acoustics"
        case .roomAdvisor: return "room-advisor"
        case .blindListening: return "blind-listening"
        case .acousticResearch: return "acoustic-research"
        case .hardwareAcceptance: return "hardware-acceptance"
        case .plugins: return "plugins"
        }
    }

    static var uncoveredProductionSections: [ProductionSection] {
        ProductionSection.allCases.filter {
            article(id: articleID(for: $0)) == nil
        }
    }

    private static func article(
        id: String,
        category: ProductionUserGuideCategory,
        title: String,
        summary: String,
        systemImage: String,
        keywords: [String],
        sections: [ProductionUserGuideSection],
        formulas: [ProductionUserGuideFormula] = []
    ) -> ProductionUserGuideArticle {
        ProductionUserGuideArticle(
            id: id,
            category: category,
            title: title,
            summary: summary,
            systemImage: systemImage,
            keywords: keywords,
            sections: sections,
            formulas: formulas
        )
    }

    private static func section(
        _ id: String,
        _ title: String,
        _ paragraphs: [String]
    ) -> ProductionUserGuideSection {
        ProductionUserGuideSection(
            id: id,
            title: title,
            paragraphs: paragraphs
        )
    }

    private static func formula(
        _ id: String,
        _ title: String,
        _ expression: String,
        _ explanation: String,
        _ scope: ProductionUserGuideMathScope
    ) -> ProductionUserGuideFormula {
        ProductionUserGuideFormula(
            id: id,
            title: title,
            expression: expression,
            explanation: explanation,
            scope: scope
        )
    }
}

enum ProductionReferenceMode: String, CaseIterable, Identifiable, Hashable {
    case userGuide
    case dspReference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userGuide: return "User Guide"
        case .dspReference: return "DSP Reference"
        }
    }

    var searchPrompt: String {
        switch self {
        case .userGuide: return "Search features, controls or math"
        case .dspReference: return "Search equations, terms or features"
        }
    }

    /// DSP Reference lists only articles that carry equations.
    func includes(_ article: ProductionUserGuideArticle) -> Bool {
        switch self {
        case .userGuide: return true
        case .dspReference: return !article.formulas.isEmpty
        }
    }
}

@MainActor
final class ProductionReferenceNavigator: ObservableObject {
    /// Scene identifier of the standalone help window.
    static let windowID = "help"

    @Published var mode: ProductionReferenceMode = .userGuide
    @Published var selectedArticleID: String? = "getting-started"
    @Published var selectedFormulaID: String?

    func openGuide(articleID: String) {
        selectedArticleID = articleID
        selectedFormulaID = nil
        mode = .userGuide
    }

    func openDSPReference(
        articleID: String,
        formulaID: String? = nil
    ) {
        selectedArticleID = articleID
        selectedFormulaID = formulaID
        mode = .dspReference
    }

    func resetFormulaFocus() {
        selectedFormulaID = nil
    }

    /// Sidebar articles for the current mode and search text.
    func articles(matching searchText: String) -> [ProductionUserGuideArticle] {
        ProductionUserGuideCatalog.search(searchText).filter(mode.includes)
    }

    /// The article the detail pane shows: the selection when the current
    /// mode can show it, otherwise the first match. Nil when nothing matches.
    func displayedArticle(matching searchText: String) -> ProductionUserGuideArticle? {
        let candidates = articles(matching: searchText)
        guard !candidates.isEmpty else { return nil }
        if let selectedArticleID,
           let article = ProductionUserGuideCatalog.article(id: selectedArticleID),
           mode.includes(article) {
            return article
        }
        return candidates.first
    }
}

struct ProductionReferenceHelpButton: View {
    enum Destination {
        case userGuide
        case dspReference
    }

    @ObservedObject var navigator: ProductionReferenceNavigator
    let articleID: String
    var formulaID: String? = nil
    var destination: Destination = .userGuide
    var label: String = "Open reference"

    @Environment(\.openWindow) private var openWindow

    // No button style here: toolbar call sites use glass, inline ones borderless.
    var body: some View {
        Button {
            switch destination {
            case .userGuide:
                navigator.openGuide(articleID: articleID)
            case .dspReference:
                navigator.openDSPReference(
                    articleID: articleID,
                    formulaID: formulaID
                )
            }
            openWindow(id: ProductionReferenceNavigator.windowID)
        } label: {
            Label(label, systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
                .imageScale(.medium)
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Help window content. One split view switches between the User Guide and
/// the DSP Reference with a toolbar picker; it is never nested in a TabView,
/// because a split view inside a toolbar-style TabView takes over the
/// window toolbar and leaves the tab buttons unresponsive.
struct ProductionHelpView: View {
    @ObservedObject var navigator: ProductionReferenceNavigator
    @State private var searchText = ""

    private var articles: [ProductionUserGuideArticle] {
        navigator.articles(matching: searchText)
    }

    private var displayedArticle: ProductionUserGuideArticle? {
        navigator.displayedArticle(matching: searchText)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedArticleBinding) {
                ForEach(ProductionUserGuideCategory.allCases) { category in
                    let matches = articles.filter {
                        $0.category == category
                    }
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches) { article in
                                Label(
                                    article.title,
                                    systemImage: navigator.mode == .dspReference
                                        ? "function" : article.systemImage
                                )
                                .tag(Optional(article.id))
                            }
                        } header: {
                            Label(category.title, systemImage: category.systemImage)
                        }
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .sidebar,
                prompt: navigator.mode.searchPrompt
            )
            .navigationSplitViewColumnWidth(
                min: 220,
                ideal: 270,
                max: 340
            )
        } detail: {
            if let article = displayedArticle {
                switch navigator.mode {
                case .userGuide:
                    ProductionUserGuideArticleView(
                        article: article,
                        targetFormulaID: navigator.selectedFormulaID
                    )
                case .dspReference:
                    ProductionDSPReferenceArticleView(
                        article: article,
                        targetFormulaID: navigator.selectedFormulaID
                    )
                }
            } else {
                ContentUnavailableView(
                    navigator.mode == .userGuide
                        ? "No Guide Results" : "No DSP Reference Results",
                    systemImage: navigator.mode == .userGuide
                        ? "magnifyingglass" : "function",
                    description: Text(
                        "Try a feature name, control, measurement term or equation."
                    )
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Reference", selection: $navigator.mode) {
                    ForEach(ProductionReferenceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between the User Guide and the DSP Reference")
            }
        }
        .frame(
            minWidth: 760,
            idealWidth: 960,
            minHeight: 560,
            idealHeight: 720
        )
    }

    private var selectedArticleBinding: Binding<String?> {
        Binding(
            get: { displayedArticle?.id },
            set: { newValue in
                navigator.selectedArticleID = newValue
                navigator.resetFormulaFocus()
            }
        )
    }
}


private struct ProductionUserGuideArticleView: View {
    let article: ProductionUserGuideArticle
    let targetFormulaID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(article.title, systemImage: article.systemImage)
                            .font(.largeTitle.bold())
                        Text(article.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(article.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.title2.bold())
                            ForEach(
                                Array(section.paragraphs.enumerated()),
                                id: \.offset
                            ) { _, paragraph in
                                Text(paragraph)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !article.formulas.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Math & DSP Details", systemImage: "function")
                                    .font(.title2.bold())
                                Spacer()
                                Text("Expandable")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                            }

                            Text(
                                "These equations describe the real signal-processing relationship or diagnostic metric used by the feature. Implementation notes call out where qualification, smoothing, bounds, buffering or safety logic adds constraints beyond the compact equation."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            ForEach(article.formulas) { formula in
                                ProductionUserGuideFormulaView(
                                    formula: formula,
                                    targeted: targetFormulaID == formula.id
                                )
                                .id(formula.id)
                            }
                        }
                    }
                }
                .padding(26)
                .frame(maxWidth: 780, alignment: .topLeading)
            }
            .navigationTitle(article.title)
            .onAppear {
                scrollToTarget(proxy)
            }
            .onChange(of: targetFormulaID) { _, _ in
                scrollToTarget(proxy)
            }
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let targetFormulaID else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation {
                proxy.scrollTo(targetFormulaID, anchor: .center)
            }
        }
    }
}

private struct ProductionDSPReferenceArticleView: View {
    let article: ProductionUserGuideArticle
    let targetFormulaID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(article.title, systemImage: "function")
                            .font(.largeTitle.bold())
                        Text(article.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    Text(
                        "Reference equations are implementation-audited during PR113. Core equations describe the mathematical operation itself; implementation relationships include product-specific constraints; diagnostic/model definitions describe a metric and do not by themselves establish physical acceptance."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(article.formulas) { formula in
                        ProductionUserGuideFormulaView(
                            formula: formula,
                            targeted: targetFormulaID == formula.id,
                            initiallyExpanded: true
                        )
                        .id(formula.id)
                    }
                }
                .padding(26)
                .frame(maxWidth: 780, alignment: .topLeading)
            }
            .navigationTitle("\(article.title) · DSP Reference")
            .onAppear {
                scrollToTarget(proxy)
            }
            .onChange(of: targetFormulaID) { _, _ in
                scrollToTarget(proxy)
            }
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let targetFormulaID else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation {
                proxy.scrollTo(targetFormulaID, anchor: .center)
            }
        }
    }
}

private struct ProductionUserGuideFormulaView: View {
    let formula: ProductionUserGuideFormula
    let targeted: Bool
    @State private var expanded: Bool

    init(
        formula: ProductionUserGuideFormula,
        targeted: Bool = false,
        initiallyExpanded: Bool = false
    ) {
        self.formula = formula
        self.targeted = targeted
        _expanded = State(
            initialValue: initiallyExpanded || targeted
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(formula.expression)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))

                Text(formula.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formula.title)
                    .font(.headline)
                Spacer()
                Label(formula.scope.title, systemImage: formula.scope.systemImage)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.tint, lineWidth: 1.5)
            }
        }
        .onChange(of: targeted) { _, isTargeted in
            if isTargeted {
                expanded = true
            }
        }
    }
}

