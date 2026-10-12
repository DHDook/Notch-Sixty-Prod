import Foundation

struct SpeakerOptimizerCorrectionEvidenceMaskSource: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var frequenciesHz: [Double]
    var authorizedForSpeakerCorrection: [Bool]

    func validate() -> Bool {
        frequenciesHz.count == authorizedForSpeakerCorrection.count
            && !frequenciesHz.isEmpty
            && frequenciesHz.allSatisfy { $0.isFinite && $0 > 0 }
            && zip(frequenciesHz, frequenciesHz.dropFirst())
                .allSatisfy { $0.0 < $0.1 }
    }
}

/// Internal bridge from PR105 cross-domain evidence into the generic PR104
/// preview designers. A missing or unmatched point is protected by default.
struct SpeakerOptimizerCorrectionEvidenceMask: Equatable, Sendable {
    var baselineMeasurementSetID: UUID
    var characterizationMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var sources: [SpeakerOptimizerCorrectionEvidenceMaskSource]
    var maximumProtectedLeakageDB: Double = 0.5

    func validate(for baseline: SpeakerOptimizerMeasurementSet) throws {
        guard baseline.id == baselineMeasurementSetID,
              baseline.playbackSystemID == playbackSystemID,
              baseline.routingSignature == routingSignature,
              maximumProtectedLeakageDB.isFinite,
              (0...1).contains(maximumProtectedLeakageDB),
              Set(sources.map(\.source)).count == sources.count,
              sources.allSatisfy({ $0.validate() }) else {
            throw SpeakerOptimizerClassificationAwareError.invalidEvidenceMask
        }
    }

    func authorizationVector(
        source: MultichannelCalibrationSource,
        frequenciesHz: [Double]
    ) throws -> [Bool] {
        guard let sourceMask = sources.first(where: { $0.source == source }) else {
            return Array(repeating: false, count: frequenciesHz.count)
        }
        guard sourceMask.validate(),
              frequenciesHz.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw SpeakerOptimizerClassificationAwareError.invalidEvidenceMask
        }
        return frequenciesHz.map { frequency in
            guard let index = sourceMask.frequenciesHz.firstIndex(where: {
                abs($0 - frequency) <= max(1.0e-6, frequency * 1.0e-9)
            }) else {
                return false
            }
            return sourceMask.authorizedForSpeakerCorrection[index]
        }
    }
}

enum SpeakerOptimizerClassificationAwareError: Error, Equatable, LocalizedError {
    case invalidEvidenceMask
    case classificationIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidEvidenceMask:
            return "Speaker Optimizer correction authorization mask is invalid or stale."
        case .classificationIdentityMismatch:
            return "Speaker Optimizer classification does not match the baseline playback/routing identity."
        }
    }
}

struct SpeakerOptimizerClassificationAwarePEQPlan: Equatable, Sendable {
    var classification: SpeakerOptimizerCrossDomainReport
    var candidate: SpeakerOptimizerPEQCandidatePlan

    var previewOnly: Bool { true }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

struct SpeakerOptimizerClassificationAwareFIRPlan: Equatable, Sendable {
    var classification: SpeakerOptimizerCrossDomainReport
    var candidate: SpeakerOptimizerFIRCandidatePlan

    var previewOnly: Bool { true }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

/// The guided PR105 path never accepts an externally supplied classification.
/// It re-runs the classifier from qualified characterization + listening
/// evidence, converts ONLY speakerPersistent points into correction authority,
/// and then asks the generic PR104 preview engines to honor that mask.
struct SpeakerOptimizerClassificationAwareCandidateDesigner: Sendable {
    func designPEQ(
        characterization: SpeakerOptimizerCharacterizationMeasurementSet,
        listeningBaseline: SpeakerOptimizerMeasurementSet,
        seatWeights: [UUID: Double]? = nil,
        options: SpeakerOptimizerDesignOptions = .init(),
        constraints: SpeakerOptimizerPEQConstraints = .init(),
        classificationOptions: SpeakerOptimizerCrossDomainOptions = .init()
    ) throws -> SpeakerOptimizerClassificationAwarePEQPlan {
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: characterization,
            listeningBaseline: listeningBaseline,
            options: classificationOptions
        )
        let mask = try makeMask(report: report, baseline: listeningBaseline)
        let candidate = try SpeakerOptimizerPEQCandidateDesigner().design(
            baseline: listeningBaseline,
            seatWeights: seatWeights,
            options: options,
            constraints: constraints,
            evidenceMask: mask
        )
        return SpeakerOptimizerClassificationAwarePEQPlan(
            classification: report,
            candidate: candidate
        )
    }

    func designFIR(
        characterization: SpeakerOptimizerCharacterizationMeasurementSet,
        listeningBaseline: SpeakerOptimizerMeasurementSet,
        seatWeights: [UUID: Double]? = nil,
        options: SpeakerOptimizerDesignOptions = .init(),
        constraints: SpeakerOptimizerFIRConstraints = .init(),
        classificationOptions: SpeakerOptimizerCrossDomainOptions = .init()
    ) throws -> SpeakerOptimizerClassificationAwareFIRPlan {
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: characterization,
            listeningBaseline: listeningBaseline,
            options: classificationOptions
        )
        let mask = try makeMask(report: report, baseline: listeningBaseline)
        let candidate = try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: listeningBaseline,
            seatWeights: seatWeights,
            options: options,
            constraints: constraints,
            evidenceMask: mask
        )
        return SpeakerOptimizerClassificationAwareFIRPlan(
            classification: report,
            candidate: candidate
        )
    }

    func makeMask(
        report: SpeakerOptimizerCrossDomainReport,
        baseline: SpeakerOptimizerMeasurementSet
    ) throws -> SpeakerOptimizerCorrectionEvidenceMask {
        guard report.listeningMeasurementSetID == baseline.id,
              report.playbackSystemID == baseline.playbackSystemID,
              report.routingSignature == baseline.routingSignature else {
            throw SpeakerOptimizerClassificationAwareError.classificationIdentityMismatch
        }
        let sources = report.sources.map { sourceReport in
            SpeakerOptimizerCorrectionEvidenceMaskSource(
                source: sourceReport.source,
                frequenciesHz: sourceReport.points.map(\.frequencyHz),
                authorizedForSpeakerCorrection: sourceReport.points.map {
                    $0.classification == .speakerPersistent
                }
            )
        }
        let mask = SpeakerOptimizerCorrectionEvidenceMask(
            baselineMeasurementSetID: baseline.id,
            characterizationMeasurementSetID:
                report.characterizationMeasurementSetID,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            sources: sources
        )
        try mask.validate(for: baseline)
        return mask
    }
}
