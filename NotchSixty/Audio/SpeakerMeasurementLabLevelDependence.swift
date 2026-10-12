import Foundation

struct SpeakerMeasurementLabLevelDependenceOptions:
    Equatable, Sendable {
    var minimumExcitationStepDB: Double = 6.0
    var maximumExcitationStepDB: Double = 18.0
    var maximumDistanceMismatchMeters: Double = 0.01
    var maximumAngleMismatchDegrees: Double = 1.0
    var materialShapeChangeRMSDB: Double = 0.50
    var materialLocalizedCompressionDB: Double = 0.75

    func validate() -> Bool {
        minimumExcitationStepDB.isFinite
            && (3...12).contains(minimumExcitationStepDB)
            && maximumExcitationStepDB.isFinite
            && (minimumExcitationStepDB...24).contains(maximumExcitationStepDB)
            && maximumDistanceMismatchMeters.isFinite
            && (0.001...0.05).contains(maximumDistanceMismatchMeters)
            && maximumAngleMismatchDegrees.isFinite
            && (0.1...5).contains(maximumAngleMismatchDegrees)
            && materialShapeChangeRMSDB.isFinite
            && (0.1...3).contains(materialShapeChangeRMSDB)
            && materialLocalizedCompressionDB.isFinite
            && (0.1...6).contains(materialLocalizedCompressionDB)
    }
}

struct SpeakerMeasurementLabLevelDependenceReport:
    Codable, Equatable, Sendable {
    var sessionID: UUID
    var playbackSystemID: UUID
    var source: MultichannelCalibrationSource
    var lowerProtocolID: UUID
    var higherProtocolID: UUID
    var lowerExcitationLevelDBFS: Double
    var higherExcitationLevelDBFS: Double
    var excitationStepDB: Double
    var geometry: SpeakerMeasurementLabGeometry
    var frequenciesHz: [Double]
    /// High-level normalized transfer minus low-level normalized transfer.
    var normalizedTransferDeltaDB: [Double]
    /// Median delta across the qualified band. This may contain true broadband
    /// compression AND any untracked playback-gain drift between protocol groups.
    var broadbandTransferShiftDB: Double
    /// Delta after removing the broadband median.
    var shapeOnlyDeltaDB: [Double]
    var shapeChangeRMSDB: Double
    var maximumLocalizedCompressionDB: Double
    var maximumLocalizedExpansionDB: Double
    var materialLocalizedCompressionPointCount: Int
    var evidenceConfidence: Double
    var warnings: [String]

    var materialLevelDependenceObserved: Bool {
        shapeChangeRMSDB > 0.50
            || maximumLocalizedCompressionDB > 0.75
    }

    var isTHDMeasurement: Bool { false }
    var isIMDMeasurement: Bool { false }
    var isCalibratedSPLMeasurement: Bool { false }
    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
}

enum SpeakerMeasurementLabLevelDependenceError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case invalidSession
    case protocolNotFound(UUID)
    case wholeSpeakerOnAxisRequired
    case explicitExcitationLevelsRequired
    case excitationStepOutOfRange
    case sourceMismatch
    case geometryMismatch
    case captureExcitationMismatch(UUID)
    case unqualifiedProtocol(UUID)
    case incompatibleFrequencyGrid
    case noCommonQualifiedBand

    var errorDescription: String? {
        "Advanced Speaker Measurement Lab level-dependence analysis failed."
    }
}

/// Bounded two-level normalized-transfer comparison.
///
/// This intentionally does NOT estimate harmonic or intermodulation distortion.
/// The existing ESS analysis retains a deconvolved transfer function but does
/// not persist the nonlinear harmonic slices needed for a defensible THD/IMD
/// result. A linear chain should produce the same normalized transfer at two
/// explicit excitation levels; repeat-qualified changes are therefore reported
/// as level dependence / compression evidence.
struct SpeakerMeasurementLabLevelDependenceAnalyzer: Sendable {
    func analyze(
        session: SpeakerMeasurementLabSession,
        firstProtocolID: UUID,
        secondProtocolID: UUID,
        options: SpeakerMeasurementLabLevelDependenceOptions = .init()
    ) throws -> SpeakerMeasurementLabLevelDependenceReport {
        guard options.validate() else {
            throw SpeakerMeasurementLabLevelDependenceError.invalidOptions
        }
        do {
            try session.validateStructure()
        } catch {
            throw SpeakerMeasurementLabLevelDependenceError.invalidSession
        }

        guard let first = session.protocols.first(where: {
            $0.id == firstProtocolID
        }) else {
            throw SpeakerMeasurementLabLevelDependenceError
                .protocolNotFound(firstProtocolID)
        }
        guard let second = session.protocols.first(where: {
            $0.id == secondProtocolID
        }) else {
            throw SpeakerMeasurementLabLevelDependenceError
                .protocolNotFound(secondProtocolID)
        }
        guard first.request.mode == .wholeSpeakerOnAxis,
              second.request.mode == .wholeSpeakerOnAxis else {
            throw SpeakerMeasurementLabLevelDependenceError
                .wholeSpeakerOnAxisRequired
        }
        guard let firstSource = first.acousticSource,
              let secondSource = second.acousticSource,
              firstSource == secondSource else {
            throw SpeakerMeasurementLabLevelDependenceError.sourceMismatch
        }
        guard let firstLevel = first.excitationLevelDBFS,
              let secondLevel = second.excitationLevelDBFS else {
            throw SpeakerMeasurementLabLevelDependenceError
                .explicitExcitationLevelsRequired
        }

        let lower: SpeakerMeasurementLabProtocol
        let higher: SpeakerMeasurementLabProtocol
        let lowerLevel: Double
        let higherLevel: Double
        if firstLevel < secondLevel {
            lower = first
            higher = second
            lowerLevel = firstLevel
            higherLevel = secondLevel
        } else {
            lower = second
            higher = first
            lowerLevel = secondLevel
            higherLevel = firstLevel
        }
        let step = higherLevel - lowerLevel
        guard step >= options.minimumExcitationStepDB - 1.0e-8,
              step <= options.maximumExcitationStepDB + 1.0e-8 else {
            throw SpeakerMeasurementLabLevelDependenceError
                .excitationStepOutOfRange
        }
        guard sameGeometry(
            lower.request.geometry,
            higher.request.geometry,
            options: options
        ) else {
            throw SpeakerMeasurementLabLevelDependenceError.geometryMismatch
        }

        let lowEvidence = try qualifiedEvidence(session, lower)
        let highEvidence = try qualifiedEvidence(session, higher)
        guard lowEvidence.optimizerReady else {
            throw SpeakerMeasurementLabLevelDependenceError
                .unqualifiedProtocol(lower.id)
        }
        guard highEvidence.optimizerReady else {
            throw SpeakerMeasurementLabLevelDependenceError
                .unqualifiedProtocol(higher.id)
        }

        let lowCaptures = captures(
            session,
            protocolID: lower.id,
            expectedLevelDBFS: lowerLevel
        )
        let highCaptures = captures(
            session,
            protocolID: higher.id,
            expectedLevelDBFS: higherLevel
        )
        guard lowCaptures.count == lower.request.repeatCount,
              highCaptures.count == higher.request.repeatCount else {
            throw SpeakerMeasurementLabLevelDependenceError
                .unqualifiedProtocol(
                    lowCaptures.count < lower.request.repeatCount
                        ? lower.id : higher.id
                )
        }

        guard let grid = lowCaptures.first?.transferFunction
                .frequenciesHz,
              validGrid(grid),
              lowCaptures.allSatisfy({
                  gridsMatch(grid, $0.transferFunction.frequenciesHz)
              }),
              highCaptures.allSatisfy({
                  gridsMatch(grid, $0.transferFunction.frequenciesHz)
              }) else {
            throw SpeakerMeasurementLabLevelDependenceError
                .incompatibleFrequencyGrid
        }

        guard let usableLow = (lowCaptures + highCaptures)
                .compactMap({ $0.quality.usableLowHz }).max(),
              let usableHigh = (lowCaptures + highCaptures)
                .compactMap({ $0.quality.usableHighHz }).min() else {
            throw SpeakerMeasurementLabLevelDependenceError
                .noCommonQualifiedBand
        }
        let indices = grid.indices.filter {
            grid[$0] >= usableLow && grid[$0] <= usableHigh
        }
        guard indices.count >= SpeakerOptimizerMeasurementEvidenceEvaluator
                .minimumCommonResponsePointCount else {
            throw SpeakerMeasurementLabLevelDependenceError
                .noCommonQualifiedBand
        }

        let frequencies = indices.map { grid[$0] }
        let lowMean = indices.map { index in
            lowCaptures.reduce(0.0) {
                $0 + $1.transferFunction.magnitudeDB[index]
            } / Double(lowCaptures.count)
        }
        let highMean = indices.map { index in
            highCaptures.reduce(0.0) {
                $0 + $1.transferFunction.magnitudeDB[index]
            } / Double(highCaptures.count)
        }
        let delta = zip(highMean, lowMean).map(-)
        guard delta.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabLevelDependenceError
                .incompatibleFrequencyGrid
        }
        let broadband = median(delta)
        let shape = delta.map { $0 - broadband }
        let shapeRMS = rms(shape)
        let maxCompression = max(0, -(shape.min() ?? 0))
        let maxExpansion = max(0, shape.max() ?? 0)
        let compressionCount = shape.filter {
            -$0 >= options.materialLocalizedCompressionDB
        }.count

        return SpeakerMeasurementLabLevelDependenceReport(
            sessionID: session.id,
            playbackSystemID: session.playbackSystemID,
            source: firstSource,
            lowerProtocolID: lower.id,
            higherProtocolID: higher.id,
            lowerExcitationLevelDBFS: lowerLevel,
            higherExcitationLevelDBFS: higherLevel,
            excitationStepDB: step,
            geometry: lower.request.geometry,
            frequenciesHz: frequencies,
            normalizedTransferDeltaDB: delta,
            broadbandTransferShiftDB: broadband,
            shapeOnlyDeltaDB: shape,
            shapeChangeRMSDB: shapeRMS,
            maximumLocalizedCompressionDB: maxCompression,
            maximumLocalizedExpansionDB: maxExpansion,
            materialLocalizedCompressionPointCount: compressionCount,
            evidenceConfidence: min(
                lowEvidence.confidence,
                highEvidence.confidence
            ),
            warnings: [
                "This is repeat-qualified normalized-transfer level dependence, not THD or IMD.",
                "Excitation is referenced to digital dBFS, not calibrated acoustic SPL at the loudspeaker.",
                "Broadband transfer shift can include playback-gain drift between protocol groups; localized shape change is reported separately.",
                "A material result is diagnostic evidence, not a loudspeaker defect certification or DSP-deployment authority."
            ]
        )
    }

    private func captures(
        _ session: SpeakerMeasurementLabSession,
        protocolID: UUID,
        expectedLevelDBFS: Double
    ) -> [SpeakerMeasurementLabCapture] {
        session.captures.filter {
            $0.protocolID == protocolID
        }.sorted {
            $0.repeatIndex < $1.repeatIndex
        }.filter {
            guard let actual = $0.excitationLevelDBFS else {
                return false
            }
            return abs(actual - expectedLevelDBFS) < 1.0e-6
        }
    }

    private func qualifiedEvidence(
        _ session: SpeakerMeasurementLabSession,
        _ labProtocol: SpeakerMeasurementLabProtocol
    ) throws -> SpeakerOptimizerMeasurementGroupReport {
        guard let source = labProtocol.acousticSource else {
            throw SpeakerMeasurementLabLevelDependenceError
                .wholeSpeakerOnAxisRequired
        }
        let position = SpeakerOptimizerMeasurementPosition(
            id: labProtocol.id,
            name: labProtocol.name
        )
        let captures = session.captures
            .filter { $0.protocolID == labProtocol.id }
            .map { capture in
                SpeakerOptimizerMeasurementCapture(
                    id: capture.id,
                    capturedAt: capture.capturedAt,
                    playbackSystemID: capture.playbackSystemID,
                    routingSignature: capture.routingSignature,
                    microphone: capture.microphone,
                    positionID: labProtocol.id,
                    source: capture.source,
                    sampleRate: capture.sampleRate,
                    response: capture.transferFunction,
                    quality: capture.quality
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
            captures: captures,
            createdAt: session.createdAt,
            modifiedAt: session.modifiedAt
        )
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator()
            .evaluate(synthetic)
        guard let group = report.groupReports.first else {
            throw SpeakerMeasurementLabLevelDependenceError
                .unqualifiedProtocol(labProtocol.id)
        }
        return group
    }

    private func sameGeometry(
        _ a: SpeakerMeasurementLabGeometry,
        _ b: SpeakerMeasurementLabGeometry,
        options: SpeakerMeasurementLabLevelDependenceOptions
    ) -> Bool {
        abs(a.distanceMeters - b.distanceMeters)
                <= options.maximumDistanceMismatchMeters
            && abs(a.horizontalAngleDegrees - b.horizontalAngleDegrees)
                <= options.maximumAngleMismatchDegrees
            && abs(a.verticalAngleDegrees - b.verticalAngleDegrees)
                <= options.maximumAngleMismatchDegrees
            && a.speakerRemainedInstalled
            && b.speakerRemainedInstalled
    }

    private func validGrid(_ grid: [Double]) -> Bool {
        grid.count >= SpeakerOptimizerMeasurementEvidenceEvaluator
            .minimumCommonResponsePointCount
            && grid.allSatisfy { $0.isFinite && $0 > 0 }
            && zip(grid, grid.dropFirst()).allSatisfy { $0.0 < $0.1 }
    }

    private func gridsMatch(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            abs($0.0 - $0.1)
                <= max(1.0e-6, abs($0.0) * 1.0e-9)
        }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty,
              values.allSatisfy(\.isFinite) else {
            return .infinity
        }
        return sqrt(
            values.reduce(0.0) { $0 + $1 * $1 }
                / Double(values.count)
        )
    }
}
