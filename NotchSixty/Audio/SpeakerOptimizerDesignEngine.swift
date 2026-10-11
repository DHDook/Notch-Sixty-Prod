import Foundation

/// First-stage, offline Speaker Optimizer. This code NEVER mutates DSP, speaker
/// routing, crossover/limiter configuration, or measured verification evidence.
/// Its output is a bounded magnitude-envelope PREVIEW, not executable filters.
enum SpeakerOptimizerDesignError: Error, Equatable {
    case baselineRequired
    case unqualifiedMeasurements
    case invalidOptions
    case invalidSeatWeights
    case incompatibleResponseGrid
    case insufficientCommonBandwidth
}

struct SpeakerOptimizerDesignOptions: Equatable, Sendable {
    /// By default avoid boosting room nulls and avoid consuming output headroom.
    var maximumCutDB: Double = 6
    var maximumBoostDB: Double = 0
    var smoothingOctaves: Double = 1.0 / 3.0
    var targetTiltDBPerOctave: Double = 0
    var maximumSeatDegradationDB: Double = 0.25

    func valid() -> Bool {
        maximumCutDB.isFinite && (0...12).contains(maximumCutDB)
            && maximumBoostDB.isFinite && (0...3).contains(maximumBoostDB)
            && smoothingOctaves.isFinite && (0.15...1.0).contains(smoothingOctaves)
            && targetTiltDBPerOctave.isFinite && (-3...3).contains(targetTiltDBPerOctave)
            && maximumSeatDegradationDB.isFinite && (0...1).contains(maximumSeatDegradationDB)
    }
}

struct SpeakerOptimizerSourcePreview: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var frequenciesHz: [Double]
    var correctionDB: [Double]
    var weightedRMSEBeforeDB: Double
    /// Model-only: adds the proposed envelope to stored measured magnitudes.
    /// NOT a fresh microphone capture or proof of audible improvement.
    var predictedWeightedRMSEAfterDB: Double
    var warnings: [String]
}

struct SpeakerOptimizerPreviewPlan: Equatable, Sendable {
    var baselineMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var evidenceConfidence: Double
    var sources: [SpeakerOptimizerSourcePreview]

    /// Future apply/verification work must require explicit user action and
    /// new microphone evidence. PR104 Slice 1 has no apply transport at all.
    var previewOnly: Bool { true }
    var isMeasuredVerification: Bool { false }
}

/// Derives conservative magnitude-only correction envelopes from qualified
/// PR103 baseline evidence. Uses every explicitly weighted microphone position,
/// preserves each source's COMMON usable frequency band, and rejects invalid
/// measurement identity, unqualified data, or unsupported design options.
struct SpeakerOptimizerDesignEngine: Sendable {
    func design(
        baseline: SpeakerOptimizerMeasurementSet,
        seatWeights: [UUID: Double]? = nil,
        options: SpeakerOptimizerDesignOptions = .init()
    ) throws -> SpeakerOptimizerPreviewPlan {
        guard baseline.role == .baseline else {
            throw SpeakerOptimizerDesignError.baselineRequired
        }
        guard options.valid() else {
            throw SpeakerOptimizerDesignError.invalidOptions
        }
        let evidence = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline)
        guard evidence.optimizerReady else {
            throw SpeakerOptimizerDesignError.unqualifiedMeasurements
        }
        let weights = try normalizedSeatWeights(
            positions: baseline.positions,
            supplied: seatWeights
        )

        var previews: [SpeakerOptimizerSourcePreview] = []
        for source in baseline.plannedSources {
            let groups = evidence.groupReports.filter { $0.source == source }
            guard groups.count == baseline.positions.count,
                  let low = groups.compactMap(\.commonUsableLowHz).max(),
                  let high = groups.compactMap(\.commonUsableHighHz).min(),
                  high > low,
                  let reference = baseline.captures.first(where: { $0.source == source })?.response else {
                throw SpeakerOptimizerDesignError.insufficientCommonBandwidth
            }

            let grid = reference.frequenciesHz
            let indices = grid.indices.filter { grid[$0] >= low && grid[$0] <= high }
            guard indices.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumCommonResponsePointCount else {
                throw SpeakerOptimizerDesignError.insufficientCommonBandwidth
            }

            var perSeat: [[Double]] = []
            for position in baseline.positions {
                let captures = baseline.captures.filter {
                    $0.source == source && $0.positionID == position.id
                }
                guard captures.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount,
                      captures.allSatisfy({ sameGrid(grid, $0.response.frequenciesHz) }) else {
                    throw SpeakerOptimizerDesignError.incompatibleResponseGrid
                }
                let means = indices.map { index in
                    captures.reduce(0.0) { $0 + $1.response.magnitudeDB[index] }
                        / Double(captures.count)
                }
                perSeat.append(means)
            }

            let frequencies = indices.map { grid[$0] }
            let combined = frequencies.indices.map { index in
                perSeat.indices.reduce(0.0) { total, seat in
                    total + weights[seat] * perSeat[seat][index]
                }
            }
            // A spectral reference derived from the captured response removes
            // the arbitrary playback/microphone gain offset: never equate
            // absolute capture dB with desired playback loudness.
            let sorted = combined.sorted()
            let median = sorted[sorted.count / 2]
            let targets = frequencies.map { frequency in
                median + options.targetTiltDBPerOctave * log2(frequency / 1_000)
            }
            let smoothed = logFrequencySmooth(
                frequencies: frequencies,
                magnitudes: combined,
                smoothingOctaves: options.smoothingOctaves
            )
            var correction = frequencies.indices.map { index in
                min(options.maximumBoostDB, max(-options.maximumCutDB, targets[index] - smoothed[index]))
            }

            let before = weightedRMSE(
                perSeat: perSeat, weights: weights, target: targets,
                correction: Array(repeating: 0, count: correction.count)
            )
            var predicted = weightedRMSE(
                perSeat: perSeat, weights: weights, target: targets,
                correction: correction
            )
            var warnings: [String] = []

            // Never preview an aggregate-worsening candidate or a candidate
            // that materially degrades an individually included seat.
            let degradesSeat = perSeat.contains { seat in
                let original = rmse(seat, targets, correction: Array(repeating: 0, count: correction.count))
                let changed = rmse(seat, targets, correction: correction)
                return changed > original + options.maximumSeatDegradationDB
            }
            if !predicted.isFinite || predicted > before + 1.0e-9 || degradesSeat {
                correction = Array(repeating: 0, count: correction.count)
                predicted = before
                warnings.append("Preview reverted to unity: modeled improvement would worsen the aggregate or an included position.")
            }
            previews.append(SpeakerOptimizerSourcePreview(
                source: source,
                frequenciesHz: frequencies,
                correctionDB: correction,
                weightedRMSEBeforeDB: before,
                predictedWeightedRMSEAfterDB: predicted,
                warnings: warnings
            ))
        }

        return SpeakerOptimizerPreviewPlan(
            baselineMeasurementSetID: baseline.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            evidenceConfidence: evidence.confidence,
            sources: previews
        )
    }

    private func normalizedSeatWeights(
        positions: [SpeakerOptimizerMeasurementPosition],
        supplied: [UUID: Double]?
    ) throws -> [Double] {
        let values: [Double]
        if let supplied {
            guard Set(supplied.keys) == Set(positions.map(\.id)) else {
                throw SpeakerOptimizerDesignError.invalidSeatWeights
            }
            values = positions.map { supplied[$0.id] ?? 0 }
        } else {
            values = Array(repeating: 1, count: positions.count)
        }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }),
              values.reduce(0, +).isFinite else {
            throw SpeakerOptimizerDesignError.invalidSeatWeights
        }
        let total = values.reduce(0, +)
        guard total > 0 else { throw SpeakerOptimizerDesignError.invalidSeatWeights }
        return values.map { $0 / total }
    }

    private func sameGrid(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy {
            abs($0 - $1) <= max(1.0e-6, abs($0) * 1.0e-9)
        }
    }

    private func logFrequencySmooth(
        frequencies: [Double],
        magnitudes: [Double],
        smoothingOctaves: Double
    ) -> [Double] {
        let logFrequencies = frequencies.map { log2($0) }
        return frequencies.indices.map { index in
            var sum = 0.0
            var weightSum = 0.0
            for neighbor in frequencies.indices {
                let distance = (logFrequencies[neighbor] - logFrequencies[index]) / smoothingOctaves
                if abs(distance) > 4 { continue }
                let weight = exp(-0.5 * distance * distance)
                sum += magnitudes[neighbor] * weight
                weightSum += weight
            }
            return sum / weightSum
        }
    }

    private func rmse(
        _ magnitude: [Double], _ target: [Double], correction: [Double]
    ) -> Double {
        let sum = magnitude.indices.reduce(0.0) { result, index in
            let residual = magnitude[index] + correction[index] - target[index]
            return result + residual * residual
        }
        return sqrt(sum / Double(magnitude.count))
    }

    private func weightedRMSE(
        perSeat: [[Double]],
        weights: [Double],
        target: [Double],
        correction: [Double]
    ) -> Double {
        let weightedMSE = perSeat.indices.reduce(0.0) { result, seat in
            let error = rmse(perSeat[seat], target, correction: correction)
            return result + weights[seat] * error * error
        }
        return sqrt(weightedMSE)
    }
}
