import Foundation

enum SpeakerOptimizerCrossoverError: Error, Equatable {
    case invalidOptions
    case invalidSourcePair
    case unqualifiedBaseline
    case insufficientCommonBandwidth
    case unreliablePhaseOrArrival
}

/// Offline mains/sub feasibility only. Delay and polarity settings are modeled
/// hypotheses, NEVER deployable crossover/limiter or speaker routing changes.
struct SpeakerOptimizerCrossoverOptions: Equatable, Sendable {
    var centerHz = 80.0
    var bandWidthOctaves = 1.0
    var frequencyPointCount = 32
    var maximumAdditionalDelayMs = 8.0
    var delayStepMs = 0.25
    var maximumArrivalGapMs = 25.0
    var maximumSeatRegressionDB = 1.0
    var minimumAggregateImprovementDB = 0.25
    var maximumModeledSumAboveStrongestSourceDB = 6.5

    func valid(sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate >= 16_000
            && centerHz.isFinite && (35...250).contains(centerHz)
            && bandWidthOctaves.isFinite && (0.5...1.5).contains(bandWidthOctaves)
            && (16...64).contains(frequencyPointCount)
            && maximumAdditionalDelayMs.isFinite
            && (0...12).contains(maximumAdditionalDelayMs)
            && delayStepMs.isFinite && (0.125...1).contains(delayStepMs)
            && maximumArrivalGapMs.isFinite && (0...40).contains(maximumArrivalGapMs)
            && maximumSeatRegressionDB.isFinite && (0...2).contains(maximumSeatRegressionDB)
            && minimumAggregateImprovementDB.isFinite
            && (0...2).contains(minimumAggregateImprovementDB)
            && maximumModeledSumAboveStrongestSourceDB.isFinite
            && (0...6.5).contains(maximumModeledSumAboveStrongestSourceDB)
            && centerHz * pow(2, bandWidthOctaves / 2) < sampleRate * 0.48
    }
}

struct SpeakerOptimizerCrossoverSeatPrediction: Equatable, Sendable {
    var positionID: UUID
    var baselineSummedLevelDB: Double
    var candidateSummedLevelDB: Double
    var predictedImprovementDB: Double
    var speakerArrivalSeconds: Double
    var subwooferArrivalSeconds: Double
}

struct SpeakerOptimizerCrossoverFeasibility: Equatable, Sendable {
    var measurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var speaker: MultichannelCalibrationSource
    var subwoofer: MultichannelCalibrationSource
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var evidenceConfidence: Double
    var centerHz: Double
    var frequencyLowHz: Double
    var frequencyHighHz: Double
    var aggregatePredictedImprovementDB: Double
    var maximumSummedAboveStrongestSourceDB: Double
    var seatPredictions: [SpeakerOptimizerCrossoverSeatPrediction]
    /// Positive: add delay to MAIN; negative: add delay to SUB. Zero = none.
    var previewRelativeDelayMs: Double
    var previewInvertSubPolarity: Bool
    var acceptedForPreview: Bool
    var blockingReasons: [String]
    var warnings: [String]
    var previewOnly: Bool { true }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
    var requiresIndependentHeadroomAndLimiterAudit: Bool { true }
}

/// Reconstructs complex transfer from the analyzer's bulk-delay-removed phase
/// PLUS that source's direct-arrival metadata. This convention is meaningful
/// ONLY for captures acquired with the same sweep time reference and route.
/// The saved schema does not authenticate clock/reference alignment across
/// separately isolated sweeps; this is a hypothesis and is NOT apply approval.
struct SpeakerOptimizerCrossoverFeasibilityDesigner: Sendable {
    func analyze(
        baseline: SpeakerOptimizerMeasurementSet,
        speaker: MultichannelCalibrationSource,
        subwoofer: MultichannelCalibrationSource,
        seatWeights: [UUID: Double]? = nil,
        options: SpeakerOptimizerCrossoverOptions = .init()
    ) throws -> SpeakerOptimizerCrossoverFeasibility {
        guard case .speaker(let role) = speaker, role != .lowFrequencyEffects,
              case .subwoofer = subwoofer, speaker != subwoofer,
              baseline.plannedSources.contains(speaker),
              baseline.plannedSources.contains(subwoofer) else {
            throw SpeakerOptimizerCrossoverError.invalidSourcePair
        }
        guard options.valid(sampleRate: baseline.sampleRate) else {
            throw SpeakerOptimizerCrossoverError.invalidOptions
        }
        guard baseline.role == .baseline,
              let evidence = try? SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline),
              evidence.optimizerReady else {
            throw SpeakerOptimizerCrossoverError.unqualifiedBaseline
        }
        let weights = try positionWeights(baseline.positions, supplied: seatWeights)
        let low = options.centerHz / pow(2, options.bandWidthOctaves / 2)
        let high = options.centerHz * pow(2, options.bandWidthOctaves / 2)

        for position in baseline.positions {
            for source in [speaker, subwoofer] {
                guard let report = evidence.groupReports.first(where: {
                    $0.positionID == position.id && $0.source == source
                }), report.optimizerReady,
                    let usableLow = report.commonUsableLowHz,
                    let usableHigh = report.commonUsableHighHz,
                    usableLow <= low && usableHigh >= high,
                    (report.phaseConsistency ?? 0) >=
                        SpeakerOptimizerMeasurementEvidenceEvaluator.minimumPhaseConsistency else {
                    throw SpeakerOptimizerCrossoverError.insufficientCommonBandwidth
                }
            }
        }

        let freqs = (0..<options.frequencyPointCount).map { i in
            low * pow(high / low, Double(i) / Double(options.frequencyPointCount - 1))
        }
        let pairs = try baseline.positions.map { position in
            let main = try response(baseline, at: position.id, source: speaker,
                                    frequencies: freqs)
            let sub = try response(baseline, at: position.id, source: subwoofer,
                                   frequencies: freqs)
            guard abs(main.arrival - sub.arrival) * 1_000 <= options.maximumArrivalGapMs else {
                throw SpeakerOptimizerCrossoverError.unreliablePhaseOrArrival
            }
            return (main: main, sub: sub)
        }
        let baselineEvaluations = pairs.map {
            evaluate($0.main, $0.sub, frequencies: freqs, sampleRate: baseline.sampleRate,
                     relativeDelayMs: 0, invertSub: false)
        }
        let baselineLevels = baselineEvaluations.map(\.summedDB)
        let baselineAggregate = weightedLevel(baselineLevels, weights)
        var best: (delay: Double, inverted: Bool, improvement: Double,
                   values: [BandEvaluation])?
        let steps = Int((options.maximumAdditionalDelayMs / options.delayStepMs).rounded(.down))
        for i in -steps...steps {
            let offset = Double(i) * options.delayStepMs
            for invert in [false, true] {
                if offset == 0 && !invert { continue }
                let evaluations = pairs.map {
                    evaluate($0.main, $0.sub, frequencies: freqs, sampleRate: baseline.sampleRate,
                             relativeDelayMs: offset, invertSub: invert)
                }
                let candidateLevels = evaluations.map(\.summedDB)
                let improvement = weightedLevel(candidateLevels, weights) - baselineAggregate
                let regressions = zip(candidateLevels, baselineLevels).map { pair in pair.0 - pair.1 }
                guard improvement.isFinite,
                      regressions.allSatisfy({ $0 >= -options.maximumSeatRegressionDB }),
                      evaluations.allSatisfy({
                          $0.peakAboveStrongestSourceDB.isFinite
                            && $0.peakAboveStrongestSourceDB
                                <= options.maximumModeledSumAboveStrongestSourceDB
                      }) else { continue }
                let superior = best.map {
                    improvement > $0.improvement + 1e-7
                        || (abs(improvement - $0.improvement) <= 1e-7
                            && abs(offset) < abs($0.delay))
                } ?? true
                if superior {
                    best = (offset, invert, improvement, evaluations)
                }
            }
        }

        let accepted = best.map { $0.improvement >= options.minimumAggregateImprovementDB } ?? false
        let chosen = accepted ? best : nil
        let selected = chosen?.values ?? baselineEvaluations
        let aggregateImprovement = chosen?.improvement ?? 0
        let seatReports = baseline.positions.indices.map { i in
            SpeakerOptimizerCrossoverSeatPrediction(
                positionID: baseline.positions[i].id,
                baselineSummedLevelDB: baselineLevels[i],
                candidateSummedLevelDB: selected[i].summedDB,
                predictedImprovementDB: selected[i].summedDB - baselineLevels[i],
                speakerArrivalSeconds: pairs[i].main.arrival,
                subwooferArrivalSeconds: pairs[i].sub.arrival
            )
        }
        return SpeakerOptimizerCrossoverFeasibility(
            measurementSetID: baseline.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            speaker: speaker,
            subwoofer: subwoofer,
            microphone: baseline.microphone,
            sampleRate: baseline.sampleRate,
            evidenceConfidence: evidence.confidence,
            centerHz: options.centerHz,
            frequencyLowHz: low,
            frequencyHighHz: high,
            aggregatePredictedImprovementDB: aggregateImprovement,
            maximumSummedAboveStrongestSourceDB:
                selected.map(\.peakAboveStrongestSourceDB).max() ?? 0,
            seatPredictions: seatReports,
            previewRelativeDelayMs: chosen?.delay ?? 0,
            previewInvertSubPolarity: chosen?.inverted ?? false,
            acceptedForPreview: accepted,
            blockingReasons: accepted ? [] : [
                "No relative timing/polarity hypothesis cleared the improvement, per-seat and sum-headroom guards."
            ],
            warnings: [
                "The stored baseline lacks independently authenticated common sweep-clock/phase provenance. Cross-source coherent sums and timing are hypothetical until a synchronized timing reference is verified.",
                "Measured phase excludes bulk acoustic arrival; arrival metadata is restored once. Never apply an additional identical compensation.",
                "Candidate level is relative to isolated sources, not an absolute electrical headroom or limiter safety certification.",
                "Live delay, polarity, crossover and speaker protection remain unchanged. A new microphone verification capture is required."
            ]
        )
    }

    private struct ComplexSample {
        var real: Double
        var imaginary: Double
    }

    private struct PositionSourceResponse {
        var arrival: Double
        var values: [ComplexSample]
    }

    private struct BandEvaluation {
        var summedDB: Double
        var peakAboveStrongestSourceDB: Double
    }

    private func response(
        _ baseline: SpeakerOptimizerMeasurementSet,
        at seat: UUID,
        source: MultichannelCalibrationSource,
        frequencies: [Double]
    ) throws -> PositionSourceResponse {
        let captures = baseline.captures.filter {
            $0.positionID == seat && $0.source == source
        }
        guard captures.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount,
              let first = captures.first,
              let phases = first.response.phaseRadians else {
            throw SpeakerOptimizerCrossoverError.unreliablePhaseOrArrival
        }
        let grid = first.response.frequenciesHz
        guard grid.count == phases.count else {
            throw SpeakerOptimizerCrossoverError.unreliablePhaseOrArrival
        }
        let arrivals = captures.compactMap(\.quality.directArrivalSeconds)
        guard arrivals.count == captures.count, arrivals.allSatisfy({
            $0.isFinite && $0 >= 0
        }) else { throw SpeakerOptimizerCrossoverError.unreliablePhaseOrArrival }
        let averageArrival = arrivals.reduce(0, +) / Double(arrivals.count)
        guard averageArrival.isFinite else {
            throw SpeakerOptimizerCrossoverError.unreliablePhaseOrArrival
        }
        var output: [ComplexSample] = []
        for f in frequencies {
            var complex = ComplexSample(real: 0, imaginary: 0)
            for capture in captures {
                guard let phase = capture.response.phaseRadians,
                      phase.count == grid.count,
                      capture.response.magnitudeDB.count == grid.count,
                      capture.response.frequenciesHz.count == grid.count,
                      zip(grid, capture.response.frequenciesHz).allSatisfy({
                          pair in abs(pair.0 - pair.1) <= max(1e-6, pair.0 * 1e-9)
                      }),
                      let point = interpolate(
                        f, frequencies: grid, magnitudes: capture.response.magnitudeDB,
                        phases: phase
                      ) else {
                    throw SpeakerOptimizerCrossoverError.unreliablePhaseOrArrival
                }
                // Mean magnitude and circular phase preserve coherent repeats
                // while group qualification already guards phase consistency.
                complex.real += point.real / Double(captures.count)
                complex.imaginary += point.imaginary / Double(captures.count)
            }
            let phaseShift = -2 * Double.pi * f * averageArrival
            let c = cos(phaseShift)
            let s = sin(phaseShift)
            output.append(ComplexSample(real: complex.real * c - complex.imaginary * s,
                                        imaginary: complex.real * s + complex.imaginary * c))
        }
        return PositionSourceResponse(arrival: averageArrival, values: output)
    }

    private func interpolate(
        _ frequency: Double, frequencies: [Double],
        magnitudes: [Double], phases: [Double]
    ) -> ComplexSample? {
        guard frequencies.count == magnitudes.count,
              frequencies.count == phases.count,
              frequencies.count >= 2,
              frequency >= frequencies[0],
              frequency <= frequencies[frequencies.count - 1] else { return nil }
        var lower = 0
        var upper = frequencies.count - 1
        while upper - lower > 1 {
            let mid = (lower + upper) / 2
            if frequencies[mid] <= frequency { lower = mid } else { upper = mid }
        }
        let octaveGap = log2(frequencies[upper] / frequencies[lower])
        guard octaveGap.isFinite, octaveGap > 0, octaveGap <= 0.30 else { return nil }
        let fraction = log(frequency / frequencies[lower])
            / log(frequencies[upper] / frequencies[lower])
        let magnitude = magnitudes[lower]
            + fraction * (magnitudes[upper] - magnitudes[lower])
        let phaseDelta = atan2(
            sin(phases[upper] - phases[lower]),
            cos(phases[upper] - phases[lower])
        )
        let phase = phases[lower] + fraction * phaseDelta
        let amp = pow(10, magnitude / 20)
        guard amp.isFinite, phase.isFinite, amp > 0 else { return nil }
        return ComplexSample(real: amp * cos(phase), imaginary: amp * sin(phase))
    }

    private func evaluate(
        _ main: PositionSourceResponse, _ sub: PositionSourceResponse,
        frequencies: [Double], sampleRate: Double,
        relativeDelayMs: Double, invertSub: Bool
    ) -> BandEvaluation {
        let delayMain = max(0, relativeDelayMs) / 1_000
        let delaySub = max(0, -relativeDelayMs) / 1_000
        var summedPower = 0.0
        var maxAbove = 0.0
        for i in frequencies.indices {
            let mainPoint = rotate(main.values[i],
                phase: -2 * Double.pi * frequencies[i] * delayMain)
            let subPoint = rotate(sub.values[i],
                phase: -2 * Double.pi * frequencies[i] * delaySub)
            let polarity = invertSub ? -1.0 : 1.0
            let summedReal = mainPoint.real + polarity * subPoint.real
            let summedImag = mainPoint.imaginary + polarity * subPoint.imaginary
            let power = summedReal * summedReal + summedImag * summedImag
            summedPower += power
            let strongest = max(
                mainPoint.real * mainPoint.real + mainPoint.imaginary * mainPoint.imaginary,
                subPoint.real * subPoint.real + subPoint.imaginary * subPoint.imaginary
            )
            let above = 10 * log10(max(power, 1e-24) / max(strongest, 1e-24))
            maxAbove = max(maxAbove, above)
        }
        return BandEvaluation(
            summedDB: 10 * log10(max(summedPower / Double(frequencies.count), 1e-24)),
            peakAboveStrongestSourceDB: maxAbove
        )
    }

    private func rotate(_ value: ComplexSample, phase: Double) -> ComplexSample {
        let c = cos(phase), s = sin(phase)
        return ComplexSample(real: value.real * c - value.imaginary * s,
                             imaginary: value.real * s + value.imaginary * c)
    }

    private func weightedLevel(_ levels: [Double], _ weights: [Double]) -> Double {
        // Arithmetic dB averaging gives every seat an explicit relative
        // influence, without falsely treating microphones as coherent seats.
        zip(levels, weights).reduce(0.0) { sum, pair in
            sum + pair.0 * pair.1
        }
    }

    private func positionWeights(
        _ positions: [SpeakerOptimizerMeasurementPosition],
        supplied: [UUID: Double]?
    ) throws -> [Double] {
        if let supplied, Set(supplied.keys) != Set(positions.map(\.id)) {
            throw SpeakerOptimizerCrossoverError.invalidOptions
        }
        let weights = positions.map { supplied?[$0.id] ?? 1 }
        let total = weights.reduce(0, +)
        guard total.isFinite && total > 0 && weights.allSatisfy({
            $0.isFinite && $0 > 0
        }) else { throw SpeakerOptimizerCrossoverError.invalidOptions }
        return weights.map { $0 / total }
    }
}
