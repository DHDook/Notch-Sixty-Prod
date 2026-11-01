import Foundation

/// E4 S28: the noise survey before arming. Pure control-plane maths on a third-octave spectrum; it never
/// touches the arm or output path and is not called from an audio callback.
///
/// The annoyance figures are ESTIMATES from public material only (owner, 28 Oct 2026: no licensed
/// standards). They are not ISO 532 or DIN 45680 values and are labelled that way everywhere.
/// - A and C weightings: the closed-form analogue responses of IEC 61672 (published pole frequencies).
/// - Loudness: a stationary Zwicker-style estimate (Zwicker and Fastl, Psychoacoustics): Bark scale,
///   spreading slopes, core loudness N' = 0.08 (E_TQ/E0)^0.23 [(0.5 + 0.5 E/E_TQ)^0.23 - 1], with the
///   threshold in quiet from Terhardt's published approximation.
enum QuietZoneNoiseWeighting {
    /// A-weighting in dB (0 dB at 1 kHz).
    static func aWeightingDB(_ f: Double) -> Double {
        guard f > 0 else { return -200 }
        let f2 = f * f
        let ra = 12194.0 * 12194.0 * f2 * f2
            / ((f2 + 20.6 * 20.6) * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12194.0 * 12194.0))
        return 20 * log10(ra) + 2.0
    }

    /// C-weighting in dB (0 dB at 1 kHz).
    static func cWeightingDB(_ f: Double) -> Double {
        guard f > 0 else { return -200 }
        let f2 = f * f
        let rc = 12194.0 * 12194.0 * f2 / ((f2 + 20.6 * 20.6) * (f2 + 12194.0 * 12194.0))
        return 20 * log10(rc) + 0.06
    }

    /// Bark (critical-band rate) of a frequency (Zwicker and Terhardt).
    static func bark(_ f: Double) -> Double {
        13 * atan(0.00076 * f) + 3.5 * atan(pow(f / 7500, 2))
    }

    /// Threshold in quiet, dB SPL (Terhardt).
    static func thresholdInQuietDB(_ f: Double) -> Double {
        let k = max(f, 20) / 1000
        return 3.64 * pow(k, -0.8) - 6.5 * exp(-0.6 * pow(k - 3.3, 2)) + 0.001 * pow(k, 4)
    }
}

/// One third-octave band of the survey: its level in dB SPL.
struct QuietZoneSurveyBand: Equatable, Sendable {
    let centerHz: Double
    let levelDB: Double
    /// Temporal standard deviation of the level in dB over the capture (steadiness).
    let spreadDB: Double
    /// The quietest the band gets across the capture, dB (the floor the noise sits on).
    let floorDB: Double
}

struct QuietZoneAnnoyanceEstimate: Equatable, Sendable {
    /// Estimated stationary loudness in sone (a Zwicker-style estimate, NOT an ISO 532 value).
    let loudnessSone: Double
    let dBA: Double
    let dBC: Double
    /// dB(C) - dB(A): large values mean the noise is dominated by low frequencies.
    var lowFrequencyIndicatorDB: Double { dBC - dBA }
    var isLowFrequencyDominated: Bool { lowFrequencyIndicatorDB >= QuietZoneNoiseSurvey.lowFrequencyIndicatorThresholdDB }
    /// Always true; the label the UI shows beside the figures.
    var isEstimate: Bool { true }
}

enum QuietZoneNoiseClass: String, Codable, Equatable, Sendable {
    /// Steady 20-150 Hz tone well above the floor: the tonal canceller handles it without a head start.
    case cancellableTonal
    /// 20-150 Hz but not steady: needs a reference microphone ahead of the seat (S24).
    case needsReference
    /// Above the physical envelope: not cancelled; offered to ambient compensation masking.
    case aboveEnvelope
    /// Within 6 dB of the floor, or below 20 Hz: nothing to gain.
    case negligible
}

struct QuietZoneNoiseFinding: Equatable, Sendable {
    let centerHz: Double
    let noiseClass: QuietZoneNoiseClass
    let levelDB: Double
    /// Predicted reduction in dB (0 when not cancellable).
    let predictedReductionDB: Double
}

struct QuietZoneNoiseSurveyReport: Equatable, Sendable {
    let findings: [QuietZoneNoiseFinding]
    let before: QuietZoneAnnoyanceEstimate
    /// Annoyance with the predicted reductions applied (the remainder is what stays audible).
    let predictedAfter: QuietZoneAnnoyanceEstimate
    /// Frequencies above the envelope that masking could help with; the user chooses.
    let maskingSuggestionHz: [Double]
    /// Plain-language statements for the card, including the physical envelope.
    let statements: [String]
}

enum QuietZoneNoiseSurvey {
    static let lowestHz = 20.0
    static let highestHz = 150.0
    static let minimumExcessDB = 6.0
    static let maximumSteadySpreadDB = 2.0
    /// Tonal prediction cap, dB (the offline solve plus real-room limits).
    static let maximumTonalReductionDB = 25.0
    static let lowFrequencyIndicatorThresholdDB = 10.0
    /// Plain text of docs/ANC_QUALIFICATION.md section 1.
    static let envelopeStatement =
        "Quiet Zone cancels steady low-frequency noise (about 20-150 Hz) such as fans and hum. "
        + "It cannot cancel speech, random sounds or anything above about 150 Hz."

    static func classify(_ band: QuietZoneSurveyBand) -> QuietZoneNoiseClass {
        if band.centerHz < lowestHz { return .negligible }
        if band.centerHz > highestHz { return .aboveEnvelope }
        let excess = band.levelDB - band.floorDB
        if excess < minimumExcessDB { return .negligible }
        return band.spreadDB <= maximumSteadySpreadDB ? .cancellableTonal : .needsReference
    }

    /// `coherence` is the S24 broadband coherence in [0, 1], or nil when no reference was surveyed.
    static func survey(bands: [QuietZoneSurveyBand], coherence: Double?) -> QuietZoneNoiseSurveyReport {
        var findings: [QuietZoneNoiseFinding] = []
        var masking: [Double] = []
        for band in bands.sorted(by: { $0.centerHz < $1.centerHz }) {
            let cls = classify(band)
            var reduction = 0.0
            switch cls {
            case .cancellableTonal:
                reduction = min(band.levelDB - band.floorDB, maximumTonalReductionDB)
            case .needsReference:
                if let coherence {
                    reduction = min(QuietZoneUpstreamAssessment.reductionBoundDB(coherence: coherence),
                                    band.levelDB - band.floorDB)
                }
            case .aboveEnvelope:
                if band.levelDB > QuietZoneNoiseWeighting.thresholdInQuietDB(band.centerHz) + minimumExcessDB {
                    masking.append(band.centerHz)
                }
            case .negligible:
                break
            }
            findings.append(QuietZoneNoiseFinding(
                centerHz: band.centerHz, noiseClass: cls, levelDB: band.levelDB,
                predictedReductionDB: max(0, reduction)))
        }
        let before = annoyance(bands: bands.map { ($0.centerHz, $0.levelDB) })
        let reducedByHz = Dictionary(uniqueKeysWithValues: findings.map { ($0.centerHz, $0.predictedReductionDB) })
        let after = annoyance(bands: bands.map { ($0.centerHz, $0.levelDB - (reducedByHz[$0.centerHz] ?? 0)) })
        var statements = [envelopeStatement]
        let tonal = findings.filter { $0.noiseClass == .cancellableTonal }
        let ref = findings.filter { $0.noiseClass == .needsReference }
        if tonal.isEmpty && ref.isEmpty {
            statements.append("No steady low-frequency noise stands out here, so there is little for Quiet Zone to cancel.")
        }
        if !tonal.isEmpty {
            statements.append("Steady tones found at \(list(tonal.map(\.centerHz))) Hz can be cancelled without a reference microphone.")
        }
        if !ref.isEmpty {
            statements.append(coherence == nil
                ? "Low-frequency noise at \(list(ref.map(\.centerHz))) Hz is not steady; it needs a reference microphone nearer the source."
                : "Low-frequency noise at \(list(ref.map(\.centerHz))) Hz is limited by how well the reference microphone hears it.")
        }
        if !masking.isEmpty {
            statements.append("Noise above 150 Hz cannot be cancelled. Ambient compensation masking can help; you choose.")
        }
        statements.append("Loudness figures are estimates, not ISO 532 or DIN 45680 values.")
        return QuietZoneNoiseSurveyReport(
            findings: findings, before: before, predictedAfter: after,
            maskingSuggestionHz: masking, statements: statements)
    }

    /// Predicted reduction against the achieved one (S16 readout), in dB. Positive: achieved less than predicted.
    static func shortfallDB(predicted: Double, achieved: Double) -> Double { predicted - achieved }

    /// Setup guidance for near-field placement.
    static let nearFieldGuidance = [
        "Put a speaker close to the listening position (bedside or behind the headrest). Near-field speakers are the strongest actuators for a small quiet zone.",
        "Place the seat microphone where the head will be, and keep the head within a few centimetres of it.",
        "Keep the reference microphone between the noise source and the seat, as far ahead as practical."
    ]

    private static func list(_ values: [Double]) -> String {
        values.map { String(Int($0.rounded())) }.joined(separator: ", ")
    }

    // MARK: Annoyance

    static func annoyance(bands: [(Double, Double)]) -> QuietZoneAnnoyanceEstimate {
        func sum(_ weight: (Double) -> Double) -> Double {
            let power = bands.reduce(0.0) { $0 + pow(10, ($1.1 + weight($1.0)) / 10) }
            return power > 0 ? 10 * log10(power) : -200
        }
        return QuietZoneAnnoyanceEstimate(
            loudnessSone: loudness(bands: bands),
            dBA: sum(QuietZoneNoiseWeighting.aWeightingDB),
            dBC: sum(QuietZoneNoiseWeighting.cWeightingDB))
    }

    /// Stationary loudness estimate in sone from third-octave levels in dB SPL.
    static func loudness(bands: [(Double, Double)]) -> Double {
        let step = 0.25
        let grid = stride(from: step, through: 24.0, by: step).map { $0 }
        var excitation = [Double](repeating: 0, count: grid.count)
        for (f, level) in bands where f > 0 && level.isFinite {
            let z0 = QuietZoneNoiseWeighting.bark(f)
            let upper = 24 + 0.23 / (f / 1000) - 0.2 * level
            for (i, z) in grid.enumerated() {
                let slope = z < z0 ? 27 * (z0 - z) : max(upper, 3) * (z - z0)
                excitation[i] += pow(10, (level - slope) / 10)
            }
        }
        var total = 0.0
        for (i, z) in grid.enumerated() where excitation[i] > 0 {
            let f = barkToHz(z)
            let eTQ = pow(10, QuietZoneNoiseWeighting.thresholdInQuietDB(f) / 10)
            let n = 0.08 * pow(eTQ, 0.23) * (pow(0.5 + 0.5 * excitation[i] / eTQ, 0.23) - 1)
            total += max(0, n) * step
        }
        return total * loudnessCalibration
    }

    /// Calibrated so a 1 kHz third-octave band at 40 dB SPL reads about 1 sone.
    static let loudnessCalibration = 1.73

    static func barkToHz(_ z: Double) -> Double {
        // Invert by bisection; monotonic.
        var lo = 20.0, hi = 20_000.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if QuietZoneNoiseWeighting.bark(mid) < z { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
