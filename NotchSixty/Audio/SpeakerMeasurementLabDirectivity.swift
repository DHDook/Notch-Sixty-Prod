import Foundation

struct SpeakerMeasurementLabDirectivityOptions:
    Equatable, Sendable {
    /// A pair must be measured at materially the same radius. The tolerance is
    /// the larger of this absolute floor and the fractional reference radius.
    var minimumDistanceToleranceMeters: Double = 0.02
    var maximumDistanceMismatchFraction: Double = 0.03
    var minimumComparisonPointCount: Int =
        SpeakerOptimizerMeasurementEvidenceEvaluator
            .minimumCommonResponsePointCount

    func validate() -> Bool {
        minimumDistanceToleranceMeters.isFinite
            && (0.005...0.10).contains(
                minimumDistanceToleranceMeters
            )
            && maximumDistanceMismatchFraction.isFinite
            && (0.005...0.10).contains(
                maximumDistanceMismatchFraction
            )
            && minimumComparisonPointCount >= 8
            && minimumComparisonPointCount <= 512
    }
}

struct SpeakerMeasurementLabDirectivityTrace:
    Codable, Equatable, Sendable {
    var protocolID: UUID
    var protocolName: String
    var horizontalAngleDegrees: Double
    var verticalAngleDegrees: Double
    var angularOffsetDegrees: Double
    var distanceMeters: Double
    var frequenciesHz: [Double]
    /// Off-axis minus on-axis at the same nominal radius. Negative values
    /// normally mean the off-axis response is lower.
    var relativeMagnitudeDB: [Double]
    var meanRelativeMagnitudeDB: Double
    var minimumRelativeMagnitudeDB: Double
    var maximumRelativeMagnitudeDB: Double
    var evidenceConfidence: Double
}

struct SpeakerMeasurementLabDirectivityReport:
    Codable, Equatable, Sendable {
    var sessionID: UUID
    var playbackSystemID: UUID
    var source: MultichannelCalibrationSource
    var onAxisProtocolID: UUID
    var referenceDistanceMeters: Double
    var commonUsableLowHz: Double
    var commonUsableHighHz: Double
    var traces: [SpeakerMeasurementLabDirectivityTrace]
    var warnings: [String]

    var measurementOnly: Bool { true }
    var isAnechoic: Bool { false }
    var canDeploy: Bool { false }
}

enum SpeakerMeasurementLabDirectivityError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case invalidSession
    case onAxisReferenceRequired
    case offAxisProtocolRequired
    case sourceMismatch
    case distanceMismatch
    case unqualifiedProtocol(UUID)
    case incompatibleFrequencyGrid
    case insufficientCommonBandwidth

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Advanced Speaker Measurement Lab directivity options are invalid."
        case .invalidSession:
            return "Advanced Speaker Measurement Lab session is invalid."
        case .onAxisReferenceRequired:
            return "Directivity analysis requires a whole-speaker on-axis reference protocol."
        case .offAxisProtocolRequired:
            return "Directivity analysis requires at least one whole-speaker off-axis protocol for the same source."
        case .sourceMismatch:
            return "On-axis and off-axis directivity protocols must measure the same whole speaker."
        case .distanceMismatch:
            return "On-axis and off-axis directivity protocols must use materially the same microphone radius."
        case .unqualifiedProtocol(let id):
            return "Lab protocol \(id.uuidString) does not have repeat-qualified measurement evidence."
        case .incompatibleFrequencyGrid:
            return "Directivity captures must share one finite strictly increasing frequency grid."
        case .insufficientCommonBandwidth:
            return "Directivity captures do not share enough qualified usable bandwidth."
        }
    }
}

/// Repeat-qualified installed-room directivity comparison.
///
/// This deliberately does NOT claim polar, spinorama, free-field or anechoic
/// performance. It compares whole-speaker transfer magnitude measured with the
/// same session/microphone at materially the same radius. Later quasi-anechoic
/// work may provide a more reflection-limited source for this same geometry.
struct SpeakerMeasurementLabDirectivityAnalyzer: Sendable {
    func analyze(
        session: SpeakerMeasurementLabSession,
        onAxisProtocolID: UUID,
        offAxisProtocolIDs: [UUID]? = nil,
        options: SpeakerMeasurementLabDirectivityOptions = .init()
    ) throws -> SpeakerMeasurementLabDirectivityReport {
        guard options.validate() else {
            throw SpeakerMeasurementLabDirectivityError.invalidOptions
        }
        do {
            try session.validateStructure()
        } catch {
            throw SpeakerMeasurementLabDirectivityError.invalidSession
        }

        guard let reference = session.protocols.first(
            where: { $0.id == onAxisProtocolID }
        ),
        reference.request.mode == .wholeSpeakerOnAxis,
        let referenceSource = reference.acousticSource,
        case .speaker(let referenceRole) = referenceSource,
        referenceRole != .lowFrequencyEffects else {
            throw SpeakerMeasurementLabDirectivityError
                .onAxisReferenceRequired
        }

        let requestedIDs = offAxisProtocolIDs.map(Set.init)
        let candidates = session.protocols.filter { labProtocol in
            guard labProtocol.request.mode == .wholeSpeakerOffAxis else {
                return false
            }
            if let requestedIDs {
                return requestedIDs.contains(labProtocol.id)
            }
            return labProtocol.acousticSource == referenceSource
        }
        guard !candidates.isEmpty else {
            throw SpeakerMeasurementLabDirectivityError
                .offAxisProtocolRequired
        }

        let referenceEvidence = try qualifiedEvidence(
            session: session,
            labProtocol: reference
        )
        guard referenceEvidence.optimizerReady else {
            throw SpeakerMeasurementLabDirectivityError
                .unqualifiedProtocol(reference.id)
        }

        for labProtocol in candidates {
            guard labProtocol.acousticSource == referenceSource else {
                throw SpeakerMeasurementLabDirectivityError.sourceMismatch
            }
            guard sameRadius(
                reference.request.geometry.distanceMeters,
                labProtocol.request.geometry.distanceMeters,
                options: options
            ) else {
                throw SpeakerMeasurementLabDirectivityError
                    .distanceMismatch
            }
        }

        let referenceCaptures = captures(
            session: session,
            protocolID: reference.id
        )
        guard let referenceGrid =
                referenceCaptures.first?
                    .transferFunction.frequenciesHz,
              gridIsValid(referenceGrid) else {
            throw SpeakerMeasurementLabDirectivityError
                .incompatibleFrequencyGrid
        }

        var allCaptures = referenceCaptures
        var evidenceByProtocol: [UUID:
            SpeakerOptimizerMeasurementGroupReport] = [
                reference.id: referenceEvidence
            ]

        for labProtocol in candidates {
            let evidence = try qualifiedEvidence(
                session: session,
                labProtocol: labProtocol
            )
            guard evidence.optimizerReady else {
                throw SpeakerMeasurementLabDirectivityError
                    .unqualifiedProtocol(labProtocol.id)
            }
            evidenceByProtocol[labProtocol.id] = evidence
            let offAxisCaptures = captures(
                session: session,
                protocolID: labProtocol.id
            )
            guard offAxisCaptures.allSatisfy({
                gridsMatch(
                    referenceGrid,
                    $0.transferFunction.frequenciesHz
                )
            }) else {
                throw SpeakerMeasurementLabDirectivityError
                    .incompatibleFrequencyGrid
            }
            allCaptures.append(contentsOf: offAxisCaptures)
        }
        guard referenceCaptures.allSatisfy({
            gridsMatch(referenceGrid, $0.transferFunction.frequenciesHz)
        }) else {
            throw SpeakerMeasurementLabDirectivityError
                .incompatibleFrequencyGrid
        }

        let commonLow = allCaptures.compactMap {
            $0.quality.usableLowHz
        }.max()
        let commonHigh = allCaptures.compactMap {
            $0.quality.usableHighHz
        }.min()
        guard let commonLow, let commonHigh,
              commonLow.isFinite, commonHigh.isFinite,
              commonLow > 0, commonHigh > commonLow else {
            throw SpeakerMeasurementLabDirectivityError
                .insufficientCommonBandwidth
        }

        let indices = referenceGrid.indices.filter {
            referenceGrid[$0] >= commonLow
                && referenceGrid[$0] <= commonHigh
        }
        guard indices.count >= options.minimumComparisonPointCount else {
            throw SpeakerMeasurementLabDirectivityError
                .insufficientCommonBandwidth
        }

        let frequencies = indices.map { referenceGrid[$0] }
        let referenceMean = meanMagnitude(
            referenceCaptures,
            indices: indices
        )
        guard referenceMean.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabDirectivityError
                .incompatibleFrequencyGrid
        }

        var traces: [SpeakerMeasurementLabDirectivityTrace] = []
        for labProtocol in candidates {
            let offAxis = captures(
                session: session,
                protocolID: labProtocol.id
            )
            let offAxisMean = meanMagnitude(
                offAxis,
                indices: indices
            )
            let relative = zip(
                offAxisMean,
                referenceMean
            ).map(-)
            guard !relative.isEmpty,
                  relative.allSatisfy(\.isFinite),
                  let minimum = relative.min(),
                  let maximum = relative.max(),
                  let evidence = evidenceByProtocol[labProtocol.id] else {
                throw SpeakerMeasurementLabDirectivityError
                    .incompatibleFrequencyGrid
            }
            let mean = relative.reduce(0, +)
                / Double(relative.count)
            let geometry = labProtocol.request.geometry
            let angle = hypot(
                geometry.horizontalAngleDegrees,
                geometry.verticalAngleDegrees
            )
            traces.append(
                SpeakerMeasurementLabDirectivityTrace(
                    protocolID: labProtocol.id,
                    protocolName: labProtocol.name,
                    horizontalAngleDegrees:
                        geometry.horizontalAngleDegrees,
                    verticalAngleDegrees:
                        geometry.verticalAngleDegrees,
                    angularOffsetDegrees: angle,
                    distanceMeters: geometry.distanceMeters,
                    frequenciesHz: frequencies,
                    relativeMagnitudeDB: relative,
                    meanRelativeMagnitudeDB: mean,
                    minimumRelativeMagnitudeDB: minimum,
                    maximumRelativeMagnitudeDB: maximum,
                    evidenceConfidence: min(
                        referenceEvidence.confidence,
                        evidence.confidence
                    )
                )
            )
        }
        traces.sort {
            if $0.angularOffsetDegrees != $1.angularOffsetDegrees {
                return $0.angularOffsetDegrees
                    < $1.angularOffsetDegrees
            }
            if $0.horizontalAngleDegrees
                != $1.horizontalAngleDegrees {
                return $0.horizontalAngleDegrees
                    < $1.horizontalAngleDegrees
            }
            return $0.verticalAngleDegrees
                < $1.verticalAngleDegrees
        }

        return SpeakerMeasurementLabDirectivityReport(
            sessionID: session.id,
            playbackSystemID: session.playbackSystemID,
            source: referenceSource,
            onAxisProtocolID: reference.id,
            referenceDistanceMeters:
                reference.request.geometry.distanceMeters,
            commonUsableLowHz: commonLow,
            commonUsableHighHz: commonHigh,
            traces: traces,
            warnings: [
                "Relative curves are installed-room off-axis minus on-axis magnitude at the same nominal microphone radius.",
                "No anechoic, free-field, spinorama, sound-power or beamwidth claim is made by this analysis.",
                "User-entered angle and distance geometry remain physical setup assumptions."
            ]
        )
    }

    private func qualifiedEvidence(
        session: SpeakerMeasurementLabSession,
        labProtocol: SpeakerMeasurementLabProtocol
    ) throws -> SpeakerOptimizerMeasurementGroupReport {
        guard let source = labProtocol.acousticSource else {
            throw SpeakerMeasurementLabDirectivityError.sourceMismatch
        }
        let labCaptures = captures(
            session: session,
            protocolID: labProtocol.id
        )
        let position = SpeakerOptimizerMeasurementPosition(
            id: labProtocol.id,
            name: labProtocol.name
        )
        let measurementCaptures = labCaptures.map { capture in
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
            captures: measurementCaptures,
            createdAt: session.createdAt,
            modifiedAt: session.modifiedAt
        )
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator()
            .evaluate(synthetic)
        guard let group = report.groupReports.first else {
            throw SpeakerMeasurementLabDirectivityError
                .unqualifiedProtocol(labProtocol.id)
        }
        return group
    }

    private func captures(
        session: SpeakerMeasurementLabSession,
        protocolID: UUID
    ) -> [SpeakerMeasurementLabCapture] {
        session.captures
            .filter { $0.protocolID == protocolID }
            .sorted {
                if $0.repeatIndex != $1.repeatIndex {
                    return $0.repeatIndex < $1.repeatIndex
                }
                return $0.capturedAt < $1.capturedAt
            }
    }

    private func sameRadius(
        _ lhs: Double,
        _ rhs: Double,
        options: SpeakerMeasurementLabDirectivityOptions
    ) -> Bool {
        let tolerance = max(
            options.minimumDistanceToleranceMeters,
            abs(lhs) * options.maximumDistanceMismatchFraction
        )
        return abs(lhs - rhs) <= tolerance
    }

    private func gridIsValid(_ grid: [Double]) -> Bool {
        grid.count
            >= SpeakerOptimizerMeasurementEvidenceEvaluator
                .minimumCommonResponsePointCount
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

    private func meanMagnitude(
        _ captures: [SpeakerMeasurementLabCapture],
        indices: [Int]
    ) -> [Double] {
        guard !captures.isEmpty else { return [] }
        return indices.map { index in
            captures.reduce(0.0) {
                $0 + $1.transferFunction.magnitudeDB[index]
            } / Double(captures.count)
        }
    }
}
