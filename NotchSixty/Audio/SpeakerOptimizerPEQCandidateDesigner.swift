import Foundation

/// PR104 Slice 2. An offline, preview-only digital PEQ candidate. Coefficients
/// describe a normalized RBJ peaking biquad but are NOT installed in an audio
/// graph. Never use this type to bypass a speaker crossover or driver limiter.
struct SpeakerOptimizerPEQBand: Equatable, Sendable {
    var centerHz: Double
    var q: Double
    var gainDB: Double
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    static func peak(centerHz: Double, q: Double, gainDB: Double, sampleRate: Double) -> Self? {
        guard centerHz.isFinite, q.isFinite, gainDB.isFinite, sampleRate.isFinite,
              centerHz > 0, centerHz < sampleRate * 0.49, q > 0, sampleRate > 0 else { return nil }
        let w = 2 * Double.pi * centerHz / sampleRate
        let a = pow(10, gainDB / 40)
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha / a
        guard a0.isFinite, a0 > 0 else { return nil }
        let c = cos(w)
        let result = Self(
            centerHz: centerHz, q: q, gainDB: gainDB,
            b0: (1 + alpha * a) / a0,
            b1: (-2 * c) / a0,
            b2: (1 - alpha * a) / a0,
            a1: (-2 * c) / a0,
            a2: (1 - alpha / a) / a0
        )
        guard [result.b0, result.b1, result.b2, result.a1, result.a2]
            .allSatisfy(\.isFinite) else { return nil }
        // The stable peaking prototype has poles inside the unit circle; this
        // numerical check is also a fail-closed guard against malformed taps.
        guard abs(result.a2) < 1, 1 + result.a1 + result.a2 > 0,
              1 - result.a1 + result.a2 > 0 else { return nil }
        return result
    }

    func magnitudeDB(at frequencyHz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequencyHz / sampleRate
        let realN = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let imagN = -b1 * sin(w) - b2 * sin(2 * w)
        let realD = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let imagD = -a1 * sin(w) - a2 * sin(2 * w)
        let num = realN * realN + imagN * imagN
        let den = realD * realD + imagD * imagD
        guard num.isFinite, den.isFinite, num > 0, den > 0 else { return .nan }
        return 10 * log10(num / den)
    }
}

enum SpeakerOptimizerPEQError: Error, Equatable {
    case invalidConstraints
    case invalidSampleRate
    case incompatibleEvidence
    case invalidResponse
}

struct SpeakerOptimizerPEQConstraints: Equatable, Sendable {
    var maximumBands = 6
    var minimumQ = 0.55
    var maximumQ = 4.0
    var maximumBandGainMagnitudeDB = 6.0
    var maximumHeadroomDB = 3.5
    var maximumOutOfBandDeviationDB = 1.0
    var minimumModeledImprovementDB = 0.03

    func valid() -> Bool {
        (1...8).contains(maximumBands)
            && minimumQ.isFinite && (0.4...2).contains(minimumQ)
            && maximumQ.isFinite && (minimumQ...6).contains(maximumQ)
            && maximumBandGainMagnitudeDB.isFinite
            && (0.5...6).contains(maximumBandGainMagnitudeDB)
            && maximumHeadroomDB.isFinite && (0...6).contains(maximumHeadroomDB)
            && maximumOutOfBandDeviationDB.isFinite
            && (0...2).contains(maximumOutOfBandDeviationDB)
            && minimumModeledImprovementDB.isFinite
            && (0...0.5).contains(minimumModeledImprovementDB)
    }
}

struct SpeakerOptimizerPEQSourceCandidate: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var bands: [SpeakerOptimizerPEQBand]
    var frequenciesHz: [Double]
    var modeledFilterMagnitudeDB: [Double]
    var weightedRMSEBeforeDB: Double
    var predictedWeightedRMSEAfterDB: Double
    var worstSeatRegressionDB: Double
    var maximumPositiveGainDB: Double
    var recommendedHeadroomDB: Double
    var warnings: [String]
}

struct SpeakerOptimizerPEQCandidatePlan: Equatable, Sendable {
    var baselineMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var evidenceConfidence: Double
    var sources: [SpeakerOptimizerPEQSourceCandidate]
    var previewOnly: Bool { true }
    var isMeasuredVerification: Bool { false }
}

/// Greedy constrained peaking-EQ parameterization. Each proposed filter uses
/// the actual DIGITAL biquad transfer function (not an approximate Gaussian).
/// Objective and seat regression are evaluated against qualified, measured
/// PR103 magnitude data, but their results are still MODEL predictions.
/// This code never applies a filter to output routing or DSP state.
struct SpeakerOptimizerPEQCandidateDesigner: Sendable {
    func design(
        baseline: SpeakerOptimizerMeasurementSet,
        seatWeights: [UUID: Double]? = nil,
        options: SpeakerOptimizerDesignOptions = .init(),
        constraints: SpeakerOptimizerPEQConstraints = .init()
    ) throws -> SpeakerOptimizerPEQCandidatePlan {
        guard constraints.valid() else { throw SpeakerOptimizerPEQError.invalidConstraints }
        let rate = baseline.sampleRate
        guard rate.isFinite, rate >= 16_000, rate <= 384_000 else {
            throw SpeakerOptimizerPEQError.invalidSampleRate
        }
        // Re-create the source preview from the baseline and options. We never
        // compile user-supplied, stale or forged preview/evidence objects.
        let preview = try SpeakerOptimizerDesignEngine().design(
            baseline: baseline, seatWeights: seatWeights, options: options
        )
        let weights = try weightsForPositions(baseline.positions, supplied: seatWeights)
        var candidates: [SpeakerOptimizerPEQSourceCandidate] = []

        for sourcePreview in preview.sources {
            let source = sourcePreview.source
            let commonCount = sourcePreview.frequenciesHz.count
            guard commonCount >= 16,
                  commonCount == sourcePreview.correctionDB.count,
                  commonCount == sourcePreview.targetMagnitudeDB.count,
                  sourcePreview.frequenciesHz.allSatisfy({ $0.isFinite && $0 > 0 && $0 < rate * 0.49 }),
                  sourcePreview.targetMagnitudeDB.allSatisfy(\.isFinite),
                  sourcePreview.correctionDB.allSatisfy(\.isFinite) else {
                throw SpeakerOptimizerPEQError.invalidResponse
            }
            var positions: [[Double]] = []
            for position in baseline.positions {
                let captures = baseline.captures.filter {
                    $0.source == source && $0.positionID == position.id
                }
                guard captures.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount else {
                    throw SpeakerOptimizerPEQError.incompatibleEvidence
                }
                let indices = try responseIndices(
                    captures[0].response.frequenciesHz,
                    target: sourcePreview.frequenciesHz
                )
                var means = [Double](repeating: 0, count: commonCount)
                for capture in captures {
                    let sampleGrid = capture.response.frequenciesHz
                    guard sampleGrid.count == captures[0].response.frequenciesHz.count else {
                        throw SpeakerOptimizerPEQError.incompatibleEvidence
                    }
                    for i in sampleGrid.indices {
                        let f = captures[0].response.frequenciesHz[i]
                        guard abs(sampleGrid[i] - f) <= max(1e-6, f * 1e-9) else {
                            throw SpeakerOptimizerPEQError.incompatibleEvidence
                        }
                    }
                    for j in indices.indices {
                        means[j] += capture.response.magnitudeDB[indices[j]] / Double(captures.count)
                    }
                }
                guard means.allSatisfy(\.isFinite) else {
                    throw SpeakerOptimizerPEQError.invalidResponse
                }
                positions.append(means)
            }
            let freqs = sourcePreview.frequenciesHz
            let target = sourcePreview.targetMagnitudeDB
            let before = weightedRMSE(positions, weights, target, Array(repeating: 0, count: commonCount))
            var corrections = Array(repeating: 0.0, count: commonCount)
            var bands: [SpeakerOptimizerPEQBand] = []
            var current = before
            let low = freqs[0]
            let high = freqs[commonCount - 1]
            let maximumCenter = min(high, rate * 0.45)
            let allowedQs = [0.55, 0.7, 1.0, 1.4, 2.0, 2.8, 4.0, 5.0, 6.0].filter {
                $0 >= constraints.minimumQ && $0 <= constraints.maximumQ
            }
            var warnings: [String] = []

            for _ in 0..<constraints.maximumBands {
                var best: (band: SpeakerOptimizerPEQBand, shape: [Double], rmse: Double)?
                for index in freqs.indices {
                    let center = freqs[index]
                    guard center >= low * 1.15, center <= maximumCenter / 1.15 else { continue }
                    // One dB resolution plus fractional last step, all bounded
                    // by both the optimizer design and PEQ per-band caps.
                    let cuts = gainSteps(maximum: min(options.maximumCutDB,
                        constraints.maximumBandGainMagnitudeDB)).map { -$0 }
                    let boosts = gainSteps(maximum: min(options.maximumBoostDB,
                        constraints.maximumBandGainMagnitudeDB))
                    for gain in cuts + boosts {
                        for q in allowedQs {
                            guard let band = SpeakerOptimizerPEQBand.peak(
                                centerHz: center, q: q, gainDB: gain, sampleRate: rate
                            ) else { continue }
                            let shape = freqs.map {
                                band.magnitudeDB(at: $0, sampleRate: rate)
                            }
                            guard shape.allSatisfy(\.isFinite) else { continue }
                            let proposed = zip(corrections, shape).map(+)
                            guard passesChecks(
                                bands: bands + [band], frequencies: freqs,
                                proposed: proposed, positions: positions,
                                weights: weights, target: target,
                                constraints: constraints, options: options,
                                sampleRate: rate
                            ) else { continue }
                            let result = weightedRMSE(positions, weights, target, proposed)
                            if result + constraints.minimumModeledImprovementDB < current,
                               result < (best?.rmse ?? .infinity) {
                                best = (band, shape, result)
                            }
                        }
                    }
                }
                guard let chosen = best else { break }
                bands.append(chosen.band)
                for i in corrections.indices { corrections[i] += chosen.shape[i] }
                current = chosen.rmse
            }

            if bands.isEmpty {
                warnings.append("No safe PEQ candidate clears the modeled improvement and position-guard thresholds; unity preview retained.")
            }
            if options.maximumBoostDB > 0 {
                warnings.append("Optional positive PEQ gains require explicit headroom and later independent physical verification.")
            }
            // Oversampled peak-gain audit over the entire digital response,
            // not merely the measured/optimized frequencies.
            let peakDB = maximumPositiveGain(bands, sampleRate: rate)
            guard peakDB.isFinite, peakDB <= constraints.maximumHeadroomDB + 1e-6 else {
                throw SpeakerOptimizerPEQError.invalidResponse
            }
            let headroom = peakDB > 1e-6 ? ceil((peakDB + 0.5) * 2) / 2 : 0
            let regressions = positions.map { position in
                rmse(position, target, corrections)
                    - rmse(position, target, Array(repeating: 0, count: commonCount))
            }
            candidates.append(SpeakerOptimizerPEQSourceCandidate(
                source: source,
                bands: bands,
                frequenciesHz: freqs,
                modeledFilterMagnitudeDB: corrections,
                weightedRMSEBeforeDB: before,
                predictedWeightedRMSEAfterDB: current,
                worstSeatRegressionDB: regressions.max() ?? 0,
                maximumPositiveGainDB: peakDB,
                recommendedHeadroomDB: headroom,
                warnings: warnings
            ))
        }
        return SpeakerOptimizerPEQCandidatePlan(
            baselineMeasurementSetID: baseline.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            sampleRate: rate,
            evidenceConfidence: preview.evidenceConfidence,
            sources: candidates
        )
    }

    private func gainSteps(maximum: Double) -> [Double] {
        guard maximum >= 0.25 else { return [] }
        var gains: [Double] = []
        var gain = 0.5
        while gain <= maximum + 1e-9 {
            gains.append(gain)
            gain += 0.5
        }
        if let last = gains.last, last < maximum - 1e-6 { gains.append(maximum) }
        return gains
    }

    private func passesChecks(
        bands: [SpeakerOptimizerPEQBand], frequencies: [Double],
        proposed: [Double], positions: [[Double]], weights: [Double],
        target: [Double], constraints: SpeakerOptimizerPEQConstraints,
        options: SpeakerOptimizerDesignOptions, sampleRate: Double
    ) -> Bool {
        let oldZeros = Array(repeating: 0.0, count: proposed.count)
        let baselineError = weightedRMSE(positions, weights, target, oldZeros)
        let candidateError = weightedRMSE(positions, weights, target, proposed)
        guard candidateError.isFinite, candidateError <= baselineError + 1e-8 else { return false }
        for position in positions {
            guard rmse(position, target, proposed)
                <= rmse(position, target, oldZeros) + options.maximumSeatDegradationDB + 1e-8 else {
                return false
            }
        }
        let peak = maximumPositiveGain(bands, sampleRate: sampleRate)
        guard peak.isFinite, peak <= constraints.maximumHeadroomDB + 1e-8 else { return false }
        // Inspect frequencies OUTSIDE the allowed band; a bell filter's
        // skirts must not silently alter crossover or unmeasured regions.
        let minF = frequencies[0]
        let maxF = frequencies[frequencies.count - 1]
        let nyquist = sampleRate * 0.5
        for i in 0...256 {
            let f = 10 * pow((nyquist * 0.98) / 10, Double(i) / 256)
            if f >= minF && f <= maxF { continue }
            let sum = bands.reduce(0.0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) }
            if !sum.isFinite || abs(sum) > constraints.maximumOutOfBandDeviationDB + 1e-8 {
                return false
            }
        }
        return true
    }

    private func maximumPositiveGain(_ bands: [SpeakerOptimizerPEQBand], sampleRate: Double) -> Double {
        guard !bands.isEmpty else { return 0 }
        let nyquist = sampleRate * 0.5
        var peak = 0.0
        for i in 0...1024 {
            let frequency = 10 * pow((nyquist * 0.99) / 10, Double(i) / 1024)
            let gain = bands.reduce(0.0) {
                $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate)
            }
            if !gain.isFinite { return .nan }
            peak = max(peak, gain)
        }
        return peak
    }

    private func weightsForPositions(
        _ positions: [SpeakerOptimizerMeasurementPosition],
        supplied: [UUID: Double]?
    ) throws -> [Double] {
        let result = positions.map { supplied?[$0.id] ?? 1 }
        if let supplied, Set(supplied.keys) != Set(positions.map(\.id)) {
            throw SpeakerOptimizerPEQError.incompatibleEvidence
        }
        guard result.allSatisfy({ $0.isFinite && $0 > 0 }),
              result.reduce(0, +).isFinite else { throw SpeakerOptimizerPEQError.incompatibleEvidence }
        let total = result.reduce(0, +)
        guard total > 0 else { throw SpeakerOptimizerPEQError.incompatibleEvidence }
        return result.map { $0 / total }
    }

    private func responseIndices(_ grid: [Double], target: [Double]) throws -> [Int] {
        var result: [Int] = []
        for f in target {
            guard let index = grid.firstIndex(where: { abs($0 - f) <= max(1e-6, f * 1e-9) }) else {
                throw SpeakerOptimizerPEQError.incompatibleEvidence
            }
            result.append(index)
        }
        return result
    }

    private func rmse(_ samples: [Double], _ target: [Double], _ correction: [Double]) -> Double {
        let sum = samples.indices.reduce(0.0) { total, i in
            let residual = samples[i] + correction[i] - target[i]
            return total + residual * residual
        }
        return sqrt(sum / Double(samples.count))
    }

    private func weightedRMSE(
        _ seats: [[Double]], _ weights: [Double],
        _ target: [Double], _ correction: [Double]
    ) -> Double {
        sqrt(seats.indices.reduce(0.0) { total, i in
            let error = rmse(seats[i], target, correction)
            return total + weights[i] * error * error
        })
    }
}
