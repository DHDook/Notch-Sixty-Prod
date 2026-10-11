import Accelerate
import Foundation

enum SpeakerOptimizerFIRCandidateError: Error, Equatable {
    case invalidConstraints
    case invalidSampleRate
    case insufficientEvidence
    case invalidFrequencyGrid
    case transformUnavailable
    case nonFiniteSynthesis
}

/// Explicitly finite linear-phase latency: odd-length symmetric FIRs have
/// group delay (tapCount - 1) / 2 frames, independent of frequency.
struct SpeakerOptimizerFIRConstraints: Equatable, Sendable {
    var tapCount = 2049
    var maximumGroupDelayMilliseconds = 30.0
    var maximumHeadroomDB = 3.5
    var maximumOutOfBandDeviationDB = 1.0
    var maximumSeatDegradationDB = 0.25
    var minimumModeledImprovementDB = 0.05
    var maximumTruncationOvershootDB = 0.35

    func valid() -> Bool {
        tapCount >= 257 && tapCount <= Int(N60_CONVOLUTION_MAX_TAPS)
            && tapCount % 2 == 1
            && maximumGroupDelayMilliseconds.isFinite
            && (0...100).contains(maximumGroupDelayMilliseconds)
            && maximumHeadroomDB.isFinite && (0...6).contains(maximumHeadroomDB)
            && maximumOutOfBandDeviationDB.isFinite
            && (0...2).contains(maximumOutOfBandDeviationDB)
            && maximumSeatDegradationDB.isFinite && (0...1).contains(maximumSeatDegradationDB)
            && minimumModeledImprovementDB.isFinite && (0...1).contains(minimumModeledImprovementDB)
            && maximumTruncationOvershootDB.isFinite
            && (0...0.5).contains(maximumTruncationOvershootDB)
    }
}

struct SpeakerOptimizerFIRSourceCandidate: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    /// Populated ONLY when the entire candidate passes offline acceptance.
    var taps: [Float]
    var frequenciesHz: [Double]
    var modeledFilterMagnitudeDB: [Double]
    var weightedRMSEBeforeDB: Double
    var predictedWeightedRMSEAfterDB: Double
    var worstSeatRegressionDB: Double
    var maximumPositiveGainDB: Double
    var recommendedHeadroomDB: Double
    var acceptedForPreview: Bool
    var blockingReasons: [String]
}

struct SpeakerOptimizerFIRCandidatePlan: Equatable, Sendable {
    var baselineMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var evidenceConfidence: Double
    var requestedTapCount: Int
    var declaredGroupDelayFrames: Int
    var declaredGroupDelayMilliseconds: Double
    var sources: [SpeakerOptimizerFIRSourceCandidate]

    var previewOnly: Bool { true }
    var isMeasuredVerification: Bool { false }
    var canDeploy: Bool { false }
}

/// Offline linear-phase synthesis using a Hermitian real magnitude spectrum,
/// an inverse DFT, exact symmetric/causal windowed truncation, and a separate
/// forward DFT of ACTUAL Float taps for prediction and headroom auditing.
/// This never installs FIR taps in the real-time audio graph.
struct SpeakerOptimizerFIRCandidateDesigner: Sendable {
    func design(
        baseline: SpeakerOptimizerMeasurementSet,
        seatWeights: [UUID: Double]? = nil,
        options: SpeakerOptimizerDesignOptions = .init(),
        constraints: SpeakerOptimizerFIRConstraints = .init()
    ) throws -> SpeakerOptimizerFIRCandidatePlan {
        guard constraints.valid() else { throw SpeakerOptimizerFIRCandidateError.invalidConstraints }
        let rate = baseline.sampleRate
        guard rate.isFinite, (16_000...384_000).contains(rate) else {
            throw SpeakerOptimizerFIRCandidateError.invalidSampleRate
        }
        let delayFrames = (constraints.tapCount - 1) / 2
        let delayMilliseconds = Double(delayFrames) / rate * 1_000
        guard delayMilliseconds <= constraints.maximumGroupDelayMilliseconds else {
            throw SpeakerOptimizerFIRCandidateError.invalidConstraints
        }

        // PR103 evidence is reevaluated here; no user-supplied or stale
        // candidate curve is accepted as measured input.
        let preview = try SpeakerOptimizerDesignEngine().design(
            baseline: baseline, seatWeights: seatWeights, options: options
        )
        let seatWeights = try normalizedWeights(baseline.positions, seatWeights)
        let transformSize = try Self.transformSize(tapCount: constraints.tapCount)
        let transform = try SpeakerOptimizerFIRTransform(size: transformSize)

        var candidates: [SpeakerOptimizerFIRSourceCandidate] = []
        for sourcePreview in preview.sources {
            let freqs = sourcePreview.frequenciesHz
            let desired = sourcePreview.correctionDB
            let target = sourcePreview.targetMagnitudeDB
            guard freqs.count >= 16, freqs.count == desired.count,
                  freqs.count == target.count,
                  freqs.allSatisfy({ $0.isFinite && $0 > 0 && $0 < rate * 0.49 }),
                  desired.allSatisfy(\.isFinite), target.allSatisfy(\.isFinite),
                  zip(freqs.dropFirst(), freqs).allSatisfy({ pair in pair.0 > pair.1 }) else {
                throw SpeakerOptimizerFIRCandidateError.invalidFrequencyGrid
            }
            let positions = try seatResponses(baseline: baseline, source: sourcePreview.source, frequencies: freqs)
            let before = weightedRMSE(positions, seatWeights, target,
                                      Array(repeating: 0, count: freqs.count))
            let impulse = try synthesize(
                correctionDB: desired, frequencies: freqs,
                sampleRate: rate, tapCount: constraints.tapCount,
                transform: transform
            )
            let spectrum = transform.forward(impulse)
            let response = try transferMagnitude(
                spectrum, frequencies: freqs, sampleRate: rate
            )
            let after = weightedRMSE(positions, seatWeights, target, response)
            let worst = positions.map { position in
                rmse(position, target, response)
                    - rmse(position, target, Array(repeating: 0, count: freqs.count))
            }.max() ?? .infinity
            let audit = audit(
                spectrum: spectrum, sampleRate: rate, low: freqs[0],
                high: freqs[freqs.count - 1],
                options: options, constraints: constraints
            )
            var blockers = audit.blockers
            if !after.isFinite || after > before - constraints.minimumModeledImprovementDB {
                blockers.append("No meaningful modeled correction improvement from the synthesized taps.")
            }
            if worst > constraints.maximumSeatDegradationDB {
                blockers.append("Synthesized FIR degrades an included microphone position beyond its limit.")
            }
            let accepted = blockers.isEmpty
            let reserve = audit.maximumPositiveDB > 1e-6
                ? ceil((audit.maximumPositiveDB + 0.5) * 2) / 2 : 0
            candidates.append(SpeakerOptimizerFIRSourceCandidate(
                source: sourcePreview.source,
                taps: accepted ? impulse : [],
                frequenciesHz: freqs,
                modeledFilterMagnitudeDB: accepted ? response : Array(repeating: 0, count: freqs.count),
                weightedRMSEBeforeDB: before,
                predictedWeightedRMSEAfterDB: accepted ? after : before,
                worstSeatRegressionDB: accepted ? worst : 0,
                maximumPositiveGainDB: accepted ? audit.maximumPositiveDB : 0,
                recommendedHeadroomDB: accepted ? reserve : 0,
                acceptedForPreview: accepted,
                blockingReasons: blockers
            ))
        }
        return SpeakerOptimizerFIRCandidatePlan(
            baselineMeasurementSetID: baseline.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            sampleRate: rate,
            evidenceConfidence: preview.evidenceConfidence,
            requestedTapCount: constraints.tapCount,
            declaredGroupDelayFrames: delayFrames,
            declaredGroupDelayMilliseconds: delayMilliseconds,
            sources: candidates
        )
    }

    private static func transformSize(tapCount: Int) throws -> Int {
        // Prefer a transform larger than the truncated impulse so edge
        // tapering is sampled finely without circular aliasing.
        let required = max(4096, tapCount * 4)
        guard required <= Int(N60_CONVOLUTION_MAX_TAPS) * 8 else {
            throw SpeakerOptimizerFIRCandidateError.invalidConstraints
        }
        var size = 1
        while size < required { size <<= 1 }
        return size
    }

    private func synthesize(
        correctionDB: [Double], frequencies: [Double],
        sampleRate: Double, tapCount: Int,
        transform: SpeakerOptimizerFIRTransform
    ) throws -> [Float] {
        let size = transform.size
        let half = size / 2
        var real = [Float](repeating: 0, count: size)
        let imaginary = [Float](repeating: 0, count: size)
        let low = frequencies[0]
        let high = frequencies[frequencies.count - 1]

        for bin in 0...half {
            let hz = Double(bin) * sampleRate / Double(size)
            let gain: Double
            if hz > low, hz < high {
                let lowEdge = min(1, max(0, log2(hz / low) * 3))
                let highEdge = min(1, max(0, log2(high / hz) * 3))
                gain = interpolated(hz, frequencies: frequencies, values: correctionDB)
                    * min(lowEdge, highEdge)
            } else {
                gain = 0
            }
            let magnitude = pow(10.0, gain / 20.0)
            guard magnitude.isFinite, magnitude > 0,
                  magnitude <= Double(Float.greatestFiniteMagnitude) else {
                throw SpeakerOptimizerFIRCandidateError.nonFiniteSynthesis
            }
            real[bin] = Float(magnitude)
            if bin > 0, bin < half { real[size - bin] = Float(magnitude) }
        }

        let impulse = transform.inverse(real: real, imaginary: imaginary)
        let middle = (tapCount - 1) / 2
        var taps: [Float] = []
        taps.reserveCapacity(tapCount)
        for i in 0..<tapCount {
            let circular = (i - middle + size) % size
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(tapCount - 1))
            taps.append(Float(Double(impulse[circular]) * window))
        }
        guard taps.allSatisfy(\.isFinite) else {
            throw SpeakerOptimizerFIRCandidateError.nonFiniteSynthesis
        }
        return taps
    }

    private func audit(
        spectrum: SpeakerOptimizerFIRSpectrum,
        sampleRate: Double, low: Double, high: Double,
        options: SpeakerOptimizerDesignOptions,
        constraints: SpeakerOptimizerFIRConstraints
    ) -> (maximumPositiveDB: Double, blockers: [String]) {
        var maxGain = 0.0
        var blockers: [String] = []
        let half = spectrum.real.count / 2
        for bin in 0...half {
            let frequency = Double(bin) * sampleRate / Double(spectrum.real.count)
            let power = Double(spectrum.real[bin]) * Double(spectrum.real[bin])
                + Double(spectrum.imaginary[bin]) * Double(spectrum.imaginary[bin])
            let gain = 10 * log10(max(power, 1e-20))
            if !gain.isFinite {
                blockers.append("Non-finite FIR spectrum.")
                break
            }
            maxGain = max(maxGain, gain)
            if gain < -options.maximumCutDB - constraints.maximumTruncationOvershootDB
                || gain > options.maximumBoostDB + constraints.maximumTruncationOvershootDB {
                blockers.append("Truncated FIR exceeds the aggregate cut/boost limits.")
                break
            }
            if (frequency < low || frequency > high)
                && abs(gain) > constraints.maximumOutOfBandDeviationDB {
                blockers.append("FIR has excessive gain deviation outside the qualified measurement band.")
                break
            }
        }
        let requiredHeadroom = maxGain > 1e-6 ? ceil((maxGain + 0.5) * 2) / 2 : 0
        if requiredHeadroom > constraints.maximumHeadroomDB {
            blockers.append("FIR headroom requirement exceeds the allowed budget.")
        }
        return (maxGain, blockers)
    }

    private func transferMagnitude(
        _ spectrum: SpeakerOptimizerFIRSpectrum, frequencies: [Double],
        sampleRate: Double
    ) throws -> [Double] {
        let half = spectrum.real.count / 2
        return try frequencies.map { f in
            let coordinate = f / sampleRate * Double(spectrum.real.count)
            guard coordinate.isFinite, coordinate >= 0,
                  coordinate <= Double(half) else {
                throw SpeakerOptimizerFIRCandidateError.invalidFrequencyGrid
            }
            let lo = min(half, Int(floor(coordinate)))
            let hi = min(half, lo + 1)
            let t = coordinate - Double(lo)
            let lmag = hypot(Double(spectrum.real[lo]), Double(spectrum.imaginary[lo]))
            let hmag = hypot(Double(spectrum.real[hi]), Double(spectrum.imaginary[hi]))
            let gain = 20 * log10(max(1e-10, lmag + t * (hmag - lmag)))
            guard gain.isFinite else { throw SpeakerOptimizerFIRCandidateError.nonFiniteSynthesis }
            return gain
        }
    }

    private func seatResponses(
        baseline: SpeakerOptimizerMeasurementSet, source: MultichannelCalibrationSource,
        frequencies: [Double]
    ) throws -> [[Double]] {
        var result: [[Double]] = []
        for position in baseline.positions {
            let captures = baseline.captures.filter {
                $0.source == source && $0.positionID == position.id
            }
            guard captures.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount,
                  let reference = captures.first?.response.frequenciesHz else {
                throw SpeakerOptimizerFIRCandidateError.insufficientEvidence
            }
            let positionsInGrid = try frequencies.map { f -> Int in
                guard let index = reference.firstIndex(where: { abs($0 - f) < max(1e-6, f * 1e-9) }) else {
                    throw SpeakerOptimizerFIRCandidateError.invalidFrequencyGrid
                }
                return index
            }
            var mean = Array(repeating: 0.0, count: frequencies.count)
            for capture in captures {
                guard capture.response.frequenciesHz.count == reference.count,
                      zip(capture.response.frequenciesHz, reference).allSatisfy({ pair in
                          abs(pair.0 - pair.1) <= max(1e-6, pair.1 * 1e-9)
                      }) else { throw SpeakerOptimizerFIRCandidateError.invalidFrequencyGrid }
                for i in mean.indices {
                    mean[i] += capture.response.magnitudeDB[positionsInGrid[i]] / Double(captures.count)
                }
            }
            guard mean.allSatisfy(\.isFinite) else {
                throw SpeakerOptimizerFIRCandidateError.nonFiniteSynthesis
            }
            result.append(mean)
        }
        return result
    }

    private func normalizedWeights(
        _ positions: [SpeakerOptimizerMeasurementPosition],
        _ supplied: [UUID: Double]?
    ) throws -> [Double] {
        if let supplied, Set(supplied.keys) != Set(positions.map(\.id)) {
            throw SpeakerOptimizerFIRCandidateError.insufficientEvidence
        }
        let weights = positions.map { supplied?[$0.id] ?? 1 }
        guard weights.allSatisfy({ $0.isFinite && $0 > 0 }),
              weights.reduce(0, +).isFinite, weights.reduce(0, +) > 0 else {
            throw SpeakerOptimizerFIRCandidateError.insufficientEvidence
        }
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }

    private func interpolated(_ frequency: Double, frequencies: [Double], values: [Double]) -> Double {
        if frequency <= frequencies[0] { return values[0] }
        if frequency >= frequencies[frequencies.count - 1] { return values[values.count - 1] }
        var start = 0
        var end = frequencies.count - 1
        while end - start > 1 {
            let mid = (start + end) / 2
            if frequencies[mid] <= frequency { start = mid } else { end = mid }
        }
        let fraction = log(frequency / frequencies[start])
            / log(frequencies[end] / frequencies[start])
        return values[start] + fraction * (values[end] - values[start])
    }

    private func rmse(_ values: [Double], _ target: [Double], _ correction: [Double]) -> Double {
        sqrt(values.indices.reduce(0.0) { sum, i in
            let residual = values[i] + correction[i] - target[i]
            return sum + residual * residual
        } / Double(values.count))
    }

    private func weightedRMSE(
        _ seats: [[Double]], _ weights: [Double],
        _ target: [Double], _ correction: [Double]
    ) -> Double {
        sqrt(seats.indices.reduce(0.0) { sum, index in
            let error = rmse(seats[index], target, correction)
            return sum + weights[index] * error * error
        })
    }
}

private struct SpeakerOptimizerFIRSpectrum {
    let real: [Float]
    let imaginary: [Float]
}

private final class SpeakerOptimizerFIRTransform {
    let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let zeros: [Float]

    init(size: Int) throws {
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            throw SpeakerOptimizerFIRCandidateError.transformUnavailable
        }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw SpeakerOptimizerFIRCandidateError.transformUnavailable
        }
        self.size = size
        self.forwardSetup = forward
        self.inverseSetup = inverse
        self.zeros = Array(repeating: 0, count: size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func inverse(real: [Float], imaginary: [Float]) -> [Float] {
        precondition(real.count == size && imaginary.count == size)
        var realOutput = [Float](repeating: 0, count: size)
        var imagOutput = [Float](repeating: 0, count: size)
        real.withUnsafeBufferPointer { inputReal in
            imaginary.withUnsafeBufferPointer { inputImag in
                realOutput.withUnsafeMutableBufferPointer { outReal in
                    imagOutput.withUnsafeMutableBufferPointer { outImag in
                        vDSP_DFT_Execute(
                            inverseSetup, inputReal.baseAddress!, inputImag.baseAddress!,
                            outReal.baseAddress!, outImag.baseAddress!
                        )
                    }
                }
            }
        }
        let factor = Float(1) / Float(size)
        for i in realOutput.indices { realOutput[i] *= factor }
        return realOutput
    }

    func forward(_ taps: [Float]) -> SpeakerOptimizerFIRSpectrum {
        precondition(taps.count <= size)
        var padded = [Float](repeating: 0, count: size)
        for i in taps.indices { padded[i] = taps[i] }
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        padded.withUnsafeBufferPointer { input in
            zeros.withUnsafeBufferPointer { zero in
                real.withUnsafeMutableBufferPointer { outReal in
                    imaginary.withUnsafeMutableBufferPointer { outImag in
                        vDSP_DFT_Execute(
                            forwardSetup, input.baseAddress!, zero.baseAddress!,
                            outReal.baseAddress!, outImag.baseAddress!
                        )
                    }
                }
            }
        }
        return SpeakerOptimizerFIRSpectrum(real: real, imaginary: imaginary)
    }
}
