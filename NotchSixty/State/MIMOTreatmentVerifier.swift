import Foundation

/// E19 S7, design note 7: the decay half of the MIMO treatment verification. It compares third-octave T30 (T20 when the
/// decay range is too short for T30) between the measured baseline and the treated response at every included seat, from 25
/// to 160 Hz. The treated response is judged twice: as predicted (`MeasurementCore.predictTreatedIR`) and, after the user has
/// listened, as repeat-measured. The spatial criteria stay with the PR75 verifier (`MIMORoomTreatmentVerifier`); its report is
/// passed in and any failure there blocks here with its own named reason.
///
/// Control plane only: offline, allocates, never on an audio thread. Nothing here arms or publishes anything.
struct MIMOTreatmentDecayCriteria: Equatable, Sendable {
    var minimumBandHz = 25.0
    var maximumBandHz = 160.0
    /// Comparable bands (reliable before and after) a seat needs for its decay to count as judged.
    var minimumReliableBandsPerSeat = 5
    /// The median over every seat and band of 1 - treated / baseline must reach this.
    var minimumMedianT30Improvement = 0.10
    /// No seat and band may get longer than this ratio of its baseline.
    var maximumBandWorseningRatio = 1.10
    /// Repeat-measured against predicted: the median relative difference of treated T30 must stay under this.
    var maximumPredictionDisagreement = 0.30
    static let conservative = MIMOTreatmentDecayCriteria()
}

enum MIMOTreatmentVerificationPhase: String, Equatable, Sendable {
    case predicted
    case repeatMeasured
}

/// One named reason a verification does not pass. Every case is a separate criterion.
enum MIMOTreatmentVerificationFailure: Equatable, Sendable {
    case noSeats
    case seatCountMismatch(phase: MIMOTreatmentVerificationPhase)
    case decayNotReliable(phase: MIMOTreatmentVerificationPhase, seat: Int, comparableBands: Int)
    case decayNotShortened(phase: MIMOTreatmentVerificationPhase, medianImprovement: Double)
    case decayWorsened(phase: MIMOTreatmentVerificationPhase, seat: Int, bandHz: Double, ratio: Double)
    case spatialCriteriaFailed
    case spatialReportMissing
    case repeatMeasurementMissing
    case predictionDisagrees(medianDifference: Double)
    case analysisFailed(phase: MIMOTreatmentVerificationPhase)

    var reason: String {
        switch self {
        case .noSeats: return "No included seat has a measured response."
        case .seatCountMismatch(let phase): return "The \(phase.rawValue) responses do not cover the same seats as the baseline."
        case .decayNotReliable(let phase, let seat, let bands):
            return "Seat \(seat + 1): only \(bands) bass bands had a usable \(phase.rawValue) decay. Re-measure with a longer, quieter capture."
        case .decayNotShortened(let phase, let improvement):
            return String(format: "The %@ bass decay is only %.0f percent shorter; at least 10 percent is required.", phase.rawValue, improvement * 100)
        case .decayWorsened(let phase, let seat, let hz, let ratio):
            return String(format: "Seat %d: the %@ decay at %.0f Hz is %.0f percent longer than before.", seat + 1, phase.rawValue, hz, (ratio - 1) * 100)
        case .spatialCriteriaFailed: return "The seat-to-seat level criteria of the repeat measurement are not met."
        case .spatialReportMissing: return "The seat-to-seat level verification has not been run."
        case .repeatMeasurementMissing: return "A treated repeat measurement is required."
        case .predictionDisagrees(let difference):
            return String(format: "The treated measurement differs from the prediction by %.0f percent; re-design or re-measure.", difference * 100)
        case .analysisFailed(let phase): return "The \(phase.rawValue) decay could not be analysed."
        }
    }
}

struct MIMOTreatmentDecayBand: Equatable, Sendable {
    var centreHz: Double
    /// T30 in seconds, else T20; nil when neither is reliable on this response.
    var seconds: Double?
}

struct MIMOTreatmentVerificationResult: Equatable, Sendable {
    var failures: [MIMOTreatmentVerificationFailure]
    var predictedMedianImprovement: Double?
    var measuredMedianImprovement: Double?
    /// Baseline and predicted T30 per seat and band, for the screen (S8).
    var baselineBands: [[MIMOTreatmentDecayBand]]
    var predictedBands: [[MIMOTreatmentDecayBand]]
    var measuredBands: [[MIMOTreatmentDecayBand]]?
    var passed: Bool { failures.isEmpty }
    /// True when the repeat measurement was supplied (it may still have failed).
    var includesRepeatMeasurement: Bool { measuredBands != nil }
}

enum MIMOTreatmentVerifier {
    /// Third-octave T30 (else T20) per band over the criteria range, one entry per band even when unreliable (seconds nil).
    /// Reliable means the analyser's own range flags are clear (35 dB decay for T30, 25 dB for T20) and the value is positive.
    static func decayBands(
        impulseResponse: [Float], sampleRate: Double, criteria: MIMOTreatmentDecayCriteria = .conservative
    ) throws -> [MIMOTreatmentDecayBand] {
        let bands = try MeasurementCore.analyzeDecay(
            impulseResponse: impulseResponse, sampleRate: sampleRate, bandsPerOctave: 3,
            minCentreHz: criteria.minimumBandHz, maxCentreHz: criteria.maximumBandHz)
        return bands.map { band in
            let flags = band.flags
            if flags & UInt32(N60_MEASURE_DECAY_FLAG_NO_DECAY) != 0 { return MIMOTreatmentDecayBand(centreHz: band.centreHz, seconds: nil) }
            if flags & UInt32(N60_MEASURE_DECAY_FLAG_T30_RANGE) == 0, band.t30Seconds > 0 {
                return MIMOTreatmentDecayBand(centreHz: band.centreHz, seconds: band.t30Seconds)
            }
            if flags & UInt32(N60_MEASURE_DECAY_FLAG_T20_RANGE) == 0, band.t20Seconds > 0 {
                return MIMOTreatmentDecayBand(centreHz: band.centreHz, seconds: band.t20Seconds)
            }
            return MIMOTreatmentDecayBand(centreHz: band.centreHz, seconds: nil)
        }
    }

    /// `baseline[seat]`, `predicted[seat]` and `measured[seat]` are impulse responses at one rate, included seats only.
    /// `spatial` is the PR75 report built from the treated repeat measurement; it must be present when `measured` is.
    static func verify(
        baseline: [[Float]], predicted: [[Float]], measured: [[Float]]?, spatial: MIMORoomTreatmentVerificationReport?,
        sampleRate: Double, criteria: MIMOTreatmentDecayCriteria = .conservative
    ) -> MIMOTreatmentVerificationResult {
        var failures: [MIMOTreatmentVerificationFailure] = []
        var result = MIMOTreatmentVerificationResult(
            failures: [], predictedMedianImprovement: nil, measuredMedianImprovement: nil, baselineBands: [], predictedBands: [],
            measuredBands: nil)
        guard !baseline.isEmpty else { result.failures = [.noSeats]; return result }
        guard predicted.count == baseline.count else {
            result.failures = [.seatCountMismatch(phase: .predicted)]
            return result
        }
        guard let base = try? baseline.map({ try decayBands(impulseResponse: $0, sampleRate: sampleRate, criteria: criteria) }) else {
            result.failures = [.analysisFailed(phase: .predicted)]
            return result
        }
        result.baselineBands = base

        func judge(
            _ irs: [[Float]], _ phase: MIMOTreatmentVerificationPhase
        ) -> (bands: [[MIMOTreatmentDecayBand]]?, improvement: Double?, failures: [MIMOTreatmentVerificationFailure]) {
            guard let bands = try? irs.map({ try decayBands(impulseResponse: $0, sampleRate: sampleRate, criteria: criteria) }) else {
                return (nil, nil, [.analysisFailed(phase: phase)])
            }
            var found: [MIMOTreatmentVerificationFailure] = []
            var improvements: [Double] = []
            for seat in 0..<base.count {
                var comparable = 0
                for (before, after) in zip(base[seat], bands[seat]) {
                    guard let b = before.seconds, let a = after.seconds, b > 0 else { continue }
                    comparable += 1
                    improvements.append(1 - a / b)
                    if a / b > criteria.maximumBandWorseningRatio {
                        found.append(.decayWorsened(phase: phase, seat: seat, bandHz: before.centreHz, ratio: a / b))
                    }
                }
                if comparable < criteria.minimumReliableBandsPerSeat {
                    found.append(.decayNotReliable(phase: phase, seat: seat, comparableBands: comparable))
                }
            }
            let median = Self.median(improvements)
            if let median, median < criteria.minimumMedianT30Improvement {
                found.append(.decayNotShortened(phase: phase, medianImprovement: median))
            }
            return (bands, median, found)
        }

        let p = judge(predicted, .predicted)
        failures += p.failures
        result.predictedBands = p.bands ?? []
        result.predictedMedianImprovement = p.improvement

        if let measured {
            if measured.count != baseline.count {
                failures.append(.seatCountMismatch(phase: .repeatMeasured))
            } else {
                let m = judge(measured, .repeatMeasured)
                failures += m.failures
                result.measuredBands = m.bands
                result.measuredMedianImprovement = m.improvement
                if let pb = p.bands, let mb = m.bands {
                    var differences: [Double] = []
                    for seat in 0..<pb.count {
                        for (a, b) in zip(pb[seat], mb[seat]) {
                            if let x = a.seconds, let y = b.seconds, x > 0 { differences.append(abs(y - x) / x) }
                        }
                    }
                    if let difference = median(differences), difference > criteria.maximumPredictionDisagreement {
                        failures.append(.predictionDisagrees(medianDifference: difference))
                    }
                }
                if let spatial {
                    if !spatial.accepted { failures.append(.spatialCriteriaFailed) }
                } else {
                    failures.append(.spatialReportMissing)
                }
            }
        } else {
            failures.append(.repeatMeasurementMissing)
        }
        result.failures = failures
        return result
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
