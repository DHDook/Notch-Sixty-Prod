import Foundation

struct SpeakerMeasurementLabCoherentTimingOptions:
    Equatable, Sendable {
    var minimumFrequencyHz: Double = 35
    var maximumFrequencyHz: Double = 250
    var minimumPointCount: Int =
        SpeakerOptimizerMeasurementEvidenceEvaluator
            .minimumCommonResponsePointCount
    var maximumReferenceArrivalSpreadMilliseconds: Double = 0.25
    var maximumReferenceMagnitudeRepeatabilityRMSDB: Double = 0.50
    var minimumReferencePhaseConsistency: Double = 0.98

    func validate(sampleRate: Double) -> Bool {
        sampleRate.isFinite && sampleRate >= 16_000
            && minimumFrequencyHz.isFinite
            && (20...120).contains(minimumFrequencyHz)
            && maximumFrequencyHz.isFinite
            && (80...500).contains(maximumFrequencyHz)
            && maximumFrequencyHz > minimumFrequencyHz
            && maximumFrequencyHz < sampleRate * 0.48
            && (8...512).contains(minimumPointCount)
            && maximumReferenceArrivalSpreadMilliseconds.isFinite
            && (0.02...2.0)
                .contains(maximumReferenceArrivalSpreadMilliseconds)
            && maximumReferenceMagnitudeRepeatabilityRMSDB.isFinite
            && (0.1...2.0)
                .contains(maximumReferenceMagnitudeRepeatabilityRMSDB)
            && minimumReferencePhaseConsistency.isFinite
            && (0.90...1.0).contains(minimumReferencePhaseConsistency)
    }
}

struct SpeakerMeasurementLabCoherentTimingReport:
    Codable, Equatable, Sendable {
    var sessionID: UUID
    var coherentPairID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var main: MultichannelCalibrationSource
    var subwoofer: MultichannelCalibrationSource
    var sampleRate: Double
    var frequenciesHz: [Double]
    /// Sub minus Main after each acoustic sweep is divided by its simultaneous
    /// electrical reference in the complex domain.
    var relativeMagnitudeDB: [Double]
    var wrappedRelativePhaseRadians: [Double]
    /// Positive means the sub acoustic path arrives later than the main after
    /// subtracting each sweep's electrical-reference arrival.
    var relativeArrivalMilliseconds: Double
    var referenceArrivalSpreadMilliseconds: Double
    var referenceMagnitudeRepeatabilityRMSDB: Double
    var referencePhaseConsistency: Double
    var evidenceConfidence: Double
    var warnings: [String]

    var crossSourceClockProvenanceAuthenticated: Bool { true }
    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var canMutateDSP: Bool { false }
}

enum SpeakerMeasurementLabCoherentTimingError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case invalidSession
    case pairNotFound
    case pairIncomplete
    case unqualifiedAcousticEvidence(UUID)
    case unqualifiedReferenceEvidence
    case referencePathUnstable
    case incompatibleFrequencyGrid
    case insufficientCommonBandwidth

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Coherent mains/sub timing options are invalid."
        case .invalidSession:
            return "The Advanced Speaker Measurement Lab session is invalid."
        case .pairNotFound:
            return "No linked coherent Main/Sub pair matches that pair ID."
        case .pairIncomplete:
            return "Coherent timing requires exactly one Main and one Sub protocol with complete repeated captures."
        case .unqualifiedAcousticEvidence(let id):
            return "Coherent protocol \(id.uuidString) is not repeat-qualified acoustic evidence."
        case .unqualifiedReferenceEvidence:
            return "Every coherent repeat requires qualified simultaneous electrical-reference evidence."
        case .referencePathUnstable:
            return "The simultaneous reference path changed too much across Main/Sub sweeps to authenticate a common time origin."
        case .incompatibleFrequencyGrid:
            return "Main, Sub and electrical-reference transfers do not share one stable frequency grid."
        case .insufficientCommonBandwidth:
            return "The coherent pair does not share enough qualified crossover-band evidence."
        }
    }
}

/// Slice 9B: reference-aligned coherent Main/Sub diagnostics.
///
/// Each separately excited source is corrected by the electrical/reference
/// transfer captured in the SAME IOProc callback timeline. Only after the
/// reference path itself passes arrival, magnitude and phase stability guards
/// is cross-source timing provenance called authenticated.
///
/// This remains measurement-only. It does not apply delay, polarity, crossover,
/// gain or limiter changes.
struct SpeakerMeasurementLabCoherentTimingAnalyzer: Sendable {
    func analyze(
        session: SpeakerMeasurementLabSession,
        coherentPairID: UUID,
        options: SpeakerMeasurementLabCoherentTimingOptions = .init()
    ) throws -> SpeakerMeasurementLabCoherentTimingReport {
        guard options.validate(sampleRate: session.sampleRate) else {
            throw SpeakerMeasurementLabCoherentTimingError.invalidOptions
        }
        do { try session.validateStructure() }
        catch { throw SpeakerMeasurementLabCoherentTimingError.invalidSession }

        let protocols = session.protocols.filter {
            $0.request.mode == .coherentMainsSubTiming
                && $0.coherentPairID == coherentPairID
        }
        guard !protocols.isEmpty else {
            throw SpeakerMeasurementLabCoherentTimingError.pairNotFound
        }
        guard protocols.count == 2,
              let mainProtocol = protocols.first(where: {
                  $0.coherentLeg == .main
              }),
              let subProtocol = protocols.first(where: {
                  $0.coherentLeg == .subwoofer
              }),
              case .sourcePair(let main, let subwoofer)
                = mainProtocol.request.target,
              subProtocol.request.target == mainProtocol.request.target,
              mainProtocol.captureSource == main,
              subProtocol.captureSource == subwoofer else {
            throw SpeakerMeasurementLabCoherentTimingError.pairIncomplete
        }

        let mainCaptures = captures(session, protocolID: mainProtocol.id)
        let subCaptures = captures(session, protocolID: subProtocol.id)
        guard mainCaptures.count == mainProtocol.request.repeatCount,
              subCaptures.count == subProtocol.request.repeatCount else {
            throw SpeakerMeasurementLabCoherentTimingError.pairIncomplete
        }

        let mainEvidence = try qualifiedEvidence(
            session: session,
            labProtocol: mainProtocol,
            captures: mainCaptures
        )
        guard mainEvidence.optimizerReady else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedAcousticEvidence(mainProtocol.id)
        }
        let subEvidence = try qualifiedEvidence(
            session: session,
            labProtocol: subProtocol,
            captures: subCaptures
        )
        guard subEvidence.optimizerReady else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedAcousticEvidence(subProtocol.id)
        }

        let allCaptures = mainCaptures + subCaptures
        guard allCaptures.allSatisfy({
            $0.sharedClockReference?.sharedTimeOriginQualified == true
        }) else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedReferenceEvidence
        }
        guard let first = allCaptures.first,
              let referenceGrid =
                first.sharedClockReference?
                    .transferFunction.frequenciesHz,
              gridValid(referenceGrid) else {
            throw SpeakerMeasurementLabCoherentTimingError
                .incompatibleFrequencyGrid
        }
        guard allCaptures.allSatisfy({
            gridsMatch(
                referenceGrid,
                $0.transferFunction.frequenciesHz
            ) && gridsMatch(
                referenceGrid,
                $0.sharedClockReference!
                    .transferFunction.frequenciesHz
            )
        }) else {
            throw SpeakerMeasurementLabCoherentTimingError
                .incompatibleFrequencyGrid
        }

        let referenceArrivals = allCaptures.compactMap {
            $0.sharedClockReference?.directArrivalSeconds
        }
        guard referenceArrivals.count == allCaptures.count else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedReferenceEvidence
        }
        let arrivalSpread = (
            (referenceArrivals.max() ?? .infinity)
                - (referenceArrivals.min() ?? -.infinity)
        ) * 1_000

        let analysisIndices = referenceGrid.indices.filter {
            referenceGrid[$0] >= options.minimumFrequencyHz
                && referenceGrid[$0] <= options.maximumFrequencyHz
        }
        guard analysisIndices.count >= options.minimumPointCount else {
            throw SpeakerMeasurementLabCoherentTimingError
                .insufficientCommonBandwidth
        }

        let referenceMagnitudeRepeatability = rmsDeviationFromMean(
            allCaptures.map { capture in
                analysisIndices.map { index in
                    capture.sharedClockReference!
                        .transferFunction.magnitudeDB[index]
                }
            }
        )
        let referencePhaseConsistency = try meanCircularConsistency(
            allCaptures.map { capture in
                guard let phase =
                        capture.sharedClockReference?
                            .transferFunction.phaseRadians else {
                    throw SpeakerMeasurementLabCoherentTimingError
                        .unqualifiedReferenceEvidence
                }
                return analysisIndices.map { phase[$0] }
            }
        )

        guard arrivalSpread.isFinite,
              arrivalSpread
                <= options.maximumReferenceArrivalSpreadMilliseconds,
              referenceMagnitudeRepeatability.isFinite,
              referenceMagnitudeRepeatability
                <= options.maximumReferenceMagnitudeRepeatabilityRMSDB,
              referencePhaseConsistency.isFinite,
              referencePhaseConsistency
                >= options.minimumReferencePhaseConsistency else {
            throw SpeakerMeasurementLabCoherentTimingError
                .referencePathUnstable
        }

        let frequencies = analysisIndices.map { referenceGrid[$0] }
        let mainResponse = try correctedMean(
            captures: mainCaptures,
            indices: analysisIndices,
            frequencies: frequencies
        )
        let subResponse = try correctedMean(
            captures: subCaptures,
            indices: analysisIndices,
            frequencies: frequencies
        )
        let relativeMagnitude = zip(
            subResponse.magnitudeDB,
            mainResponse.magnitudeDB
        ).map(-)
        let relativePhase = zip(
            subResponse.phaseRadians,
            mainResponse.phaseRadians
        ).map {
            atan2(sin($0.0 - $0.1), cos($0.0 - $0.1))
        }

        let relativeArrivalMs =
            (subResponse.correctedArrivalSeconds
                - mainResponse.correctedArrivalSeconds) * 1_000

        return SpeakerMeasurementLabCoherentTimingReport(
            sessionID: session.id,
            coherentPairID: coherentPairID,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            microphone: session.microphone,
            main: main,
            subwoofer: subwoofer,
            sampleRate: session.sampleRate,
            frequenciesHz: frequencies,
            relativeMagnitudeDB: relativeMagnitude,
            wrappedRelativePhaseRadians: relativePhase,
            relativeArrivalMilliseconds: relativeArrivalMs,
            referenceArrivalSpreadMilliseconds: arrivalSpread,
            referenceMagnitudeRepeatabilityRMSDB:
                referenceMagnitudeRepeatability,
            referencePhaseConsistency: referencePhaseConsistency,
            evidenceConfidence: min(
                mainEvidence.confidence,
                subEvidence.confidence
            ),
            warnings: [
                "Cross-source clock provenance is authenticated only for this linked pair, reference path, route, sample rate and capture session.",
                "Relative phase is reference-aligned measured evidence, not permission to alter delay, polarity or crossover settings.",
                "The electrical reference removes per-sweep time origin; it does not certify absolute DAC/ADC latency."
            ]
        )
    }

    private struct CorrectedMean {
        var magnitudeDB: [Double]
        var phaseRadians: [Double]
        var correctedArrivalSeconds: Double
    }

    private func correctedMean(
        captures: [SpeakerMeasurementLabCapture],
        indices: [Int],
        frequencies: [Double]
    ) throws -> CorrectedMean {
        var magnitude = Array(repeating: 0.0, count: indices.count)
        var real = Array(repeating: 0.0, count: indices.count)
        var imag = Array(repeating: 0.0, count: indices.count)
        var correctedArrivals: [Double] = []

        for capture in captures {
            guard let acousticPhase =
                    capture.transferFunction.phaseRadians,
                  let acousticArrival =
                    capture.quality.directArrivalSeconds,
                  let reference = capture.sharedClockReference,
                  let referencePhase =
                    reference.transferFunction.phaseRadians,
                  acousticPhase.count
                    == capture.transferFunction.frequenciesHz.count,
                  referencePhase.count
                    == reference.transferFunction.frequenciesHz.count else {
                throw SpeakerMeasurementLabCoherentTimingError
                    .unqualifiedReferenceEvidence
            }
            correctedArrivals.append(
                acousticArrival - reference.directArrivalSeconds
            )
            for (outputIndex, gridIndex) in indices.enumerated() {
                let f = frequencies[outputIndex]
                magnitude[outputIndex] += (
                    capture.transferFunction.magnitudeDB[gridIndex]
                        - reference.transferFunction
                            .magnitudeDB[gridIndex]
                ) / Double(captures.count)

                let acousticAbsolute =
                    acousticPhase[gridIndex]
                    - 2 * Double.pi * f * acousticArrival
                let referenceAbsolute =
                    referencePhase[gridIndex]
                    - 2 * Double.pi * f
                        * reference.directArrivalSeconds
                let corrected = acousticAbsolute - referenceAbsolute
                real[outputIndex] += cos(corrected)
                    / Double(captures.count)
                imag[outputIndex] += sin(corrected)
                    / Double(captures.count)
            }
        }
        guard correctedArrivals.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedReferenceEvidence
        }
        let phases = zip(real, imag).map {
            atan2($0.1, $0.0)
        }
        let arrival = correctedArrivals.reduce(0, +)
            / Double(correctedArrivals.count)
        return CorrectedMean(
            magnitudeDB: magnitude,
            phaseRadians: phases,
            correctedArrivalSeconds: arrival
        )
    }

    private func qualifiedEvidence(
        session: SpeakerMeasurementLabSession,
        labProtocol: SpeakerMeasurementLabProtocol,
        captures: [SpeakerMeasurementLabCapture]
    ) throws -> SpeakerOptimizerMeasurementGroupReport {
        guard let source = labProtocol.captureSource else {
            throw SpeakerMeasurementLabCoherentTimingError.pairIncomplete
        }
        let position = SpeakerOptimizerMeasurementPosition(
            id: labProtocol.id,
            name: labProtocol.name
        )
        let syntheticCaptures = captures.map {
            SpeakerOptimizerMeasurementCapture(
                id: $0.id,
                capturedAt: $0.capturedAt,
                playbackSystemID: $0.playbackSystemID,
                routingSignature: $0.routingSignature,
                microphone: $0.microphone,
                positionID: labProtocol.id,
                source: $0.source,
                sampleRate: $0.sampleRate,
                response: $0.transferFunction,
                quality: $0.quality
            )
        }
        let synthetic = SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            microphone: session.microphone,
            sampleRate: session.sampleRate,
            positions: [position],
            plannedSources: [source],
            captures: syntheticCaptures,
            createdAt: session.createdAt,
            modifiedAt: session.modifiedAt
        )
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator()
            .evaluate(synthetic)
        guard let group = report.groupReports.first else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedAcousticEvidence(labProtocol.id)
        }
        return group
    }

    private func captures(
        _ session: SpeakerMeasurementLabSession,
        protocolID: UUID
    ) -> [SpeakerMeasurementLabCapture] {
        session.captures.filter {
            $0.protocolID == protocolID
        }.sorted {
            $0.repeatIndex < $1.repeatIndex
        }
    }

    private func gridValid(_ grid: [Double]) -> Bool {
        grid.count >= 8
            && grid.allSatisfy { $0.isFinite && $0 > 0 }
            && zip(grid, grid.dropFirst()).allSatisfy {
                $0.0 < $0.1
            }
    }

    private func gridsMatch(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy {
                abs($0.0 - $0.1)
                    <= max(1.0e-6, abs($0.0) * 1.0e-9)
            }
    }

    private func rmsDeviationFromMean(
        _ traces: [[Double]]
    ) -> Double {
        guard let first = traces.first,
              !first.isEmpty,
              traces.allSatisfy({
                  $0.count == first.count
                    && $0.allSatisfy(\.isFinite)
              }) else { return .infinity }
        let mean = first.indices.map { index in
            traces.reduce(0.0) {
                $0 + $1[index]
            } / Double(traces.count)
        }
        var sum = 0.0
        var count = 0
        for trace in traces {
            for index in trace.indices {
                let delta = trace[index] - mean[index]
                sum += delta * delta
                count += 1
            }
        }
        return count > 0 ? sqrt(sum / Double(count)) : .infinity
    }

    private func meanCircularConsistency(
        _ traces: [[Double]]
    ) throws -> Double {
        guard let first = traces.first,
              !first.isEmpty,
              traces.allSatisfy({
                  $0.count == first.count
                    && $0.allSatisfy(\.isFinite)
              }) else {
            throw SpeakerMeasurementLabCoherentTimingError
                .unqualifiedReferenceEvidence
        }
        var values: [Double] = []
        for index in first.indices {
            let real = traces.reduce(0.0) {
                $0 + cos($1[index])
            } / Double(traces.count)
            let imag = traces.reduce(0.0) {
                $0 + sin($1[index])
            } / Double(traces.count)
            values.append(hypot(real, imag))
        }
        return values.reduce(0, +) / Double(values.count)
    }
}
