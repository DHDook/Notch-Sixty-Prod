import Foundation

enum SpeakerOptimizerDeviationClassification: String, Codable, CaseIterable, Sendable {
    /// Similar local shape appears in the early-window characterization and
    /// consistently across listening seats. This is evidence that a later
    /// optimizer MAY treat the feature as speaker-persistent; it is not itself
    /// permission to apply a filter.
    case speakerPersistent
    /// The near-speaker response is locally quiet while the listening area has
    /// a strong or strongly position-varying feature.
    case roomSeatDependent
    /// The two domains disagree or the evidence is not decisive enough.
    case ambiguous
    /// Neither domain contains a material local deviation at this frequency.
    case noMaterialDeviation
}

struct SpeakerOptimizerCrossDomainOptions: Equatable, Sendable {
    var smoothingOctaves: Double = 1.0 / 3.0
    var significantDeviationDB: Double = 1.5
    var nearSpeakerFlatToleranceDB: Double = 0.75
    var speakerAgreementToleranceDB: Double = 1.0
    var maximumPersistentSeatSpreadDB: Double = 1.0
    var roomSeatSpreadThresholdDB: Double = 1.5
    var minimumPointCount: Int = 16

    func validate() -> Bool {
        smoothingOctaves.isFinite && (0.15...1.0).contains(smoothingOctaves)
            && significantDeviationDB.isFinite && (0.5...6).contains(significantDeviationDB)
            && nearSpeakerFlatToleranceDB.isFinite
            && (0...significantDeviationDB).contains(nearSpeakerFlatToleranceDB)
            && speakerAgreementToleranceDB.isFinite
            && (0.25...3).contains(speakerAgreementToleranceDB)
            && maximumPersistentSeatSpreadDB.isFinite
            && (0.25...3).contains(maximumPersistentSeatSpreadDB)
            && roomSeatSpreadThresholdDB.isFinite
            && (0.5...6).contains(roomSeatSpreadThresholdDB)
            && minimumPointCount >= 8
    }
}

struct SpeakerOptimizerCrossDomainPoint: Codable, Equatable, Sendable {
    var frequencyHz: Double
    /// Local shape residual after log-frequency smoothing. Absolute microphone
    /// level and speaker distance are intentionally not compared.
    var characterizationResidualDB: Double
    var listeningMeanResidualDB: Double
    var listeningSeatSpreadDB: Double
    var classification: SpeakerOptimizerDeviationClassification

    /// A later design stage may use this point as supporting evidence for
    /// speaker correction. PR105 Slice 3 still does not design/apply filters.
    var supportsSpeakerCorrection: Bool {
        classification == .speakerPersistent
    }
}

struct SpeakerOptimizerCrossDomainSourceReport: Codable, Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var frequenciesHz: [Double]
    var points: [SpeakerOptimizerCrossDomainPoint]
    var characterizationCaptureCount: Int
    var listeningSeatCount: Int

    var speakerPersistentFraction: Double {
        fraction(.speakerPersistent)
    }

    var roomSeatDependentFraction: Double {
        fraction(.roomSeatDependent)
    }

    private func fraction(_ classification: SpeakerOptimizerDeviationClassification) -> Double {
        guard !points.isEmpty else { return 0 }
        return Double(points.filter { $0.classification == classification }.count)
            / Double(points.count)
    }
}

struct SpeakerOptimizerCrossDomainReport: Codable, Equatable, Sendable {
    var characterizationMeasurementSetID: UUID
    var listeningMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sources: [SpeakerOptimizerCrossDomainSourceReport]
    var warnings: [String]

    /// Classification is advisory evidence only. It never authorizes DSP
    /// mutation, crossover changes, timing changes or filter deployment.
    var previewOnly: Bool { true }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

enum SpeakerOptimizerCrossDomainError: Error, Equatable, LocalizedError {
    case invalidOptions
    case incompatibleMeasurementDomains
    case unqualifiedCharacterization
    case unqualifiedListeningBaseline
    case missingEarlyWindowEvidence(MultichannelCalibrationSource)
    case inconsistentEarlyWindowGrid(MultichannelCalibrationSource)
    case insufficientCommonBandwidth(MultichannelCalibrationSource)
    case missingListeningSource(MultichannelCalibrationSource)
    case invalidListeningResponse

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Speaker Optimizer cross-domain classification options are invalid."
        case .incompatibleMeasurementDomains:
            return "Speaker characterization and listening evidence are not identity-compatible."
        case .unqualifiedCharacterization:
            return "Speaker characterization evidence has not passed its repeated-measurement qualification."
        case .unqualifiedListeningBaseline:
            return "The listening-position baseline has not passed Speaker Optimizer qualification."
        case .missingEarlyWindowEvidence(let source):
            return "\(source.displayName) does not have enough compact early-window characterization evidence."
        case .inconsistentEarlyWindowGrid(let source):
            return "\(source.displayName) early-window repeats do not share one reliable frequency grid."
        case .insufficientCommonBandwidth(let source):
            return "\(source.displayName) has too little common early-window/listening bandwidth for classification."
        case .missingListeningSource(let source):
            return "\(source.displayName) is not present in the listening-position baseline."
        case .invalidListeningResponse:
            return "A listening-position response cannot be interpolated safely onto the characterization grid."
        }
    }
}

/// Compares LOCAL RESPONSE SHAPE, not absolute capture level.
///
/// Characterization distance changes absolute level, so direct dB subtraction
/// between a 1 m capture and a couch capture would be invalid. Each domain is
/// first reduced to a local residual around a log-frequency-smoothed trend.
/// Only those residuals are compared.
struct SpeakerOptimizerCrossDomainClassifier: Sendable {
    func classify(
        characterization: SpeakerOptimizerCharacterizationMeasurementSet,
        listeningBaseline: SpeakerOptimizerMeasurementSet,
        options: SpeakerOptimizerCrossDomainOptions = .init()
    ) throws -> SpeakerOptimizerCrossDomainReport {
        guard options.validate() else {
            throw SpeakerOptimizerCrossDomainError.invalidOptions
        }
        do {
            try characterization.validateCompatibility(with: listeningBaseline)
        } catch {
            throw SpeakerOptimizerCrossDomainError.incompatibleMeasurementDomains
        }

        let characterizationReport = try SpeakerOptimizerCharacterizationEvidenceEvaluator()
            .evaluate(characterization)
        guard characterizationReport.optimizerReady else {
            throw SpeakerOptimizerCrossDomainError.unqualifiedCharacterization
        }
        let listeningReport = try SpeakerOptimizerMeasurementEvidenceEvaluator()
            .evaluate(listeningBaseline)
        guard listeningReport.optimizerReady, listeningBaseline.role == .baseline else {
            throw SpeakerOptimizerCrossDomainError.unqualifiedListeningBaseline
        }

        let early = characterization.earlyWindowEvidence ?? []
        var reports: [SpeakerOptimizerCrossDomainSourceReport] = []

        for target in characterization.targets {
            let source = target.source
            guard listeningBaseline.plannedSources.contains(source) else {
                throw SpeakerOptimizerCrossDomainError.missingListeningSource(source)
            }
            let sourceEarly = early.filter {
                $0.targetID == target.id && $0.source == source
            }
            guard sourceEarly.count
                    >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount else {
                throw SpeakerOptimizerCrossDomainError.missingEarlyWindowEvidence(source)
            }
            guard let referenceGrid = sourceEarly.first?.response.frequenciesHz,
                  sourceEarly.allSatisfy({
                      sameGrid(referenceGrid, $0.response.frequenciesHz)
                          && $0.magnitudeOnly && !$0.isAnechoic
                  }) else {
                throw SpeakerOptimizerCrossDomainError.inconsistentEarlyWindowGrid(source)
            }

            let listeningGroups = listeningBaseline.positions.map { position in
                listeningBaseline.captures.filter {
                    $0.positionID == position.id && $0.source == source
                }
            }
            guard listeningGroups.allSatisfy({
                $0.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount
            }) else {
                throw SpeakerOptimizerCrossDomainError.unqualifiedListeningBaseline
            }

            let validFrequencies = referenceGrid.filter { frequency in
                listeningGroups.allSatisfy { captures in
                    captures.allSatisfy {
                        guard let first = $0.response.frequenciesHz.first,
                              let last = $0.response.frequenciesHz.last else { return false }
                        return frequency >= first && frequency <= last
                    }
                }
            }
            guard validFrequencies.count >= options.minimumPointCount else {
                throw SpeakerOptimizerCrossDomainError.insufficientCommonBandwidth(source)
            }

            let earlyMean = try validFrequencies.map { frequency in
                try sourceEarly.reduce(0.0) { sum, evidence in
                    sum + (try interpolate(
                        response: evidence.response,
                        frequencyHz: frequency
                    ))
                } / Double(sourceEarly.count)
            }
            let characterizationResidual = localResidual(
                frequencies: validFrequencies,
                magnitudes: earlyMean,
                smoothingOctaves: options.smoothingOctaves
            )

            var seatResiduals: [[Double]] = []
            for captures in listeningGroups {
                let seatMean = try validFrequencies.map { frequency in
                    try captures.reduce(0.0) { sum, capture in
                        sum + (try interpolate(
                            response: capture.response,
                            frequencyHz: frequency
                        ))
                    } / Double(captures.count)
                }
                seatResiduals.append(localResidual(
                    frequencies: validFrequencies,
                    magnitudes: seatMean,
                    smoothingOctaves: options.smoothingOctaves
                ))
            }

            var points: [SpeakerOptimizerCrossDomainPoint] = []
            points.reserveCapacity(validFrequencies.count)
            for index in validFrequencies.indices {
                let seatValues = seatResiduals.map { $0[index] }
                let seatMean = seatValues.reduce(0, +) / Double(seatValues.count)
                let spread = standardDeviation(seatValues, mean: seatMean)
                let near = characterizationResidual[index]
                let classification = classifyPoint(
                    characterizationResidualDB: near,
                    listeningMeanResidualDB: seatMean,
                    listeningSeatSpreadDB: spread,
                    options: options
                )
                points.append(SpeakerOptimizerCrossDomainPoint(
                    frequencyHz: validFrequencies[index],
                    characterizationResidualDB: near,
                    listeningMeanResidualDB: seatMean,
                    listeningSeatSpreadDB: spread,
                    classification: classification
                ))
            }

            reports.append(SpeakerOptimizerCrossDomainSourceReport(
                source: source,
                frequenciesHz: validFrequencies,
                points: points,
                characterizationCaptureCount: sourceEarly.count,
                listeningSeatCount: listeningGroups.count
            ))
        }

        return SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID: characterization.id,
            listeningMeasurementSetID: listeningBaseline.id,
            playbackSystemID: listeningBaseline.playbackSystemID,
            routingSignature: listeningBaseline.routingSignature,
            sources: reports,
            warnings: [
                "Cross-domain labels compare local spectral shape only; absolute 1 m and listening-seat levels are intentionally not compared.",
                "Speaker-persistent means supporting evidence for later bounded correction, not permission to boost/cut or deploy a filter.",
                "Room/seat-dependent and ambiguous deviations must not be promoted to speaker-defect correction without additional evidence.",
                "Classification uses magnitude-only early-window evidence and is never synchronized timing, phase, polarity or crossover evidence."
            ]
        )
    }

    private func classifyPoint(
        characterizationResidualDB near: Double,
        listeningMeanResidualDB seatMean: Double,
        listeningSeatSpreadDB spread: Double,
        options: SpeakerOptimizerCrossDomainOptions
    ) -> SpeakerOptimizerDeviationClassification {
        let significant = options.significantDeviationDB
        let nearSignificant = abs(near) >= significant
        let seatSignificant = abs(seatMean) >= significant
        let sameDirection = near == 0 || seatMean == 0
            ? false
            : (near > 0) == (seatMean > 0)
        let agrees = abs(near - seatMean) <= options.speakerAgreementToleranceDB

        if nearSignificant && seatSignificant && sameDirection && agrees
            && spread <= options.maximumPersistentSeatSpreadDB {
            return .speakerPersistent
        }
        if abs(near) <= options.nearSpeakerFlatToleranceDB
            && (seatSignificant || spread >= options.roomSeatSpreadThresholdDB) {
            return .roomSeatDependent
        }
        if abs(near) < significant && abs(seatMean) < significant
            && spread < options.roomSeatSpreadThresholdDB {
            return .noMaterialDeviation
        }
        return .ambiguous
    }

    private func localResidual(
        frequencies: [Double],
        magnitudes: [Double],
        smoothingOctaves: Double
    ) -> [Double] {
        let logs = frequencies.map(log2)
        let smoothed = frequencies.indices.map { index in
            var weighted = 0.0
            var weightSum = 0.0
            for neighbor in frequencies.indices {
                let distance = (logs[neighbor] - logs[index]) / smoothingOctaves
                guard abs(distance) <= 4 else { continue }
                let weight = exp(-0.5 * distance * distance)
                weighted += magnitudes[neighbor] * weight
                weightSum += weight
            }
            return weightSum > 0 ? weighted / weightSum : magnitudes[index]
        }
        return magnitudes.indices.map { magnitudes[$0] - smoothed[$0] }
    }

    private func interpolate(
        response: RoomCorrectionFrequencyResponse,
        frequencyHz: Double
    ) throws -> Double {
        let f = response.frequenciesHz
        let m = response.magnitudeDB
        guard f.count == m.count, f.count >= 2,
              f.allSatisfy({ $0.isFinite && $0 > 0 }),
              m.allSatisfy(\.isFinite),
              zip(f, f.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              let first = f.first, let last = f.last,
              frequencyHz >= first, frequencyHz <= last else {
            throw SpeakerOptimizerCrossDomainError.invalidListeningResponse
        }
        if frequencyHz == first { return m[0] }
        if frequencyHz == last { return m[m.count - 1] }
        var low = 0
        var high = f.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if f[mid] <= frequencyHz { low = mid } else { high = mid }
        }
        let leftLog = log(f[low])
        let rightLog = log(f[high])
        let targetLog = log(frequencyHz)
        let fraction = (targetLog - leftLog) / (rightLog - leftLog)
        return m[low] + fraction * (m[high] - m[low])
    }

    private func sameGrid(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            abs($0.0 - $0.1) <= max(1.0e-6, abs($0.0) * 1.0e-9)
        }
    }

    private func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let variance = values.reduce(0.0) {
            $0 + ($1 - mean) * ($1 - mean)
        } / Double(values.count)
        return sqrt(max(0, variance))
    }
}
