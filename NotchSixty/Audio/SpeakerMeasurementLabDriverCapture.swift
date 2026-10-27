import Foundation

// E8 B2: the Measurement Lab per-driver capture adapter. A `driverNearField` protocol measures one routed way alone
// at the cone, full band. This file turns its repeat-qualified captures into the `RoutedWayLinearisation` that the
// routing compiler designs the driver correction from (E8 B1). Pure and offline: no engine access, no routing change,
// and nothing here deploys; applying a result to a way is the explicit user action of B3.

enum SpeakerMeasurementLabDriverCaptureError: Error, Equatable, LocalizedError {
    case invalidSession
    case protocolRequired
    case invalidProtocol(UUID)
    case unqualifiedProtocol(UUID)
    case incompatibleFrequencyGrid
    case insufficientBandwidth

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "The Measurement Lab session is invalid."
        case .protocolRequired:
            return "No driver near-field protocol was found for that routed way."
        case .invalidProtocol(let id):
            return "Lab protocol \(id.uuidString) is not a valid driver near-field protocol."
        case .unqualifiedProtocol(let id):
            return "Lab protocol \(id.uuidString) does not have repeat-qualified near-field evidence."
        case .incompatibleFrequencyGrid:
            return "Driver near-field captures must share one finite strictly increasing frequency grid."
        case .insufficientBandwidth:
            return "The driver near-field captures do not share enough qualified bandwidth."
        }
    }
}

struct SpeakerMeasurementLabDriverCaptureResult: Equatable, Sendable {
    var wayID: UUID
    var protocolID: UUID
    /// The mean near-field response over the qualified band, ready to store on `RoutedWay.linearisation`.
    var linearisation: RoutedWayLinearisation
    var usableLowHz: Double
    var usableHighHz: Double
    var evidenceConfidence: Double
    var warnings: [String]

    /// Always true: a capture is evidence, never a deployed correction.
    var measurementOnly: Bool { true }
}

struct SpeakerMeasurementLabDriverCaptureAdapter: Sendable {
    static let minimumPointCount = 16

    /// The qualified near-field response of `wayID`. With several protocols for the same way the newest protocol in
    /// the session order that has captures wins; pass `protocolID` to choose one.
    func analyze(
        session: SpeakerMeasurementLabSession,
        wayID: UUID,
        protocolID: UUID? = nil
    ) throws -> SpeakerMeasurementLabDriverCaptureResult {
        do { try session.validateStructure() } catch {
            throw SpeakerMeasurementLabDriverCaptureError.invalidSession
        }
        let candidates = session.protocols.filter {
            $0.request.mode == .driverNearField && $0.routedWayID == wayID
                && (protocolID == nil || $0.id == protocolID)
        }
        guard let labProtocol = candidates.last(where: { candidate in
            session.captures.contains { $0.protocolID == candidate.id }
        }) ?? candidates.last else {
            throw SpeakerMeasurementLabDriverCaptureError.protocolRequired
        }
        guard let source = labProtocol.captureSource else {
            throw SpeakerMeasurementLabDriverCaptureError.invalidProtocol(labProtocol.id)
        }

        let group = session.captures.filter { $0.protocolID == labProtocol.id }
            .sorted { ($0.repeatIndex, $0.capturedAt) < ($1.repeatIndex, $1.capturedAt) }
        let evidence = try qualifiedEvidence(session: session, labProtocol: labProtocol, source: source, group: group)
        guard evidence.optimizerReady else {
            throw SpeakerMeasurementLabDriverCaptureError.unqualifiedProtocol(labProtocol.id)
        }

        guard let grid = group.first?.transferFunction.frequenciesHz,
              grid.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumCommonResponsePointCount,
              grid.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(grid, grid.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              group.allSatisfy({ gridsMatch(grid, $0.transferFunction.frequenciesHz)
                                 && $0.transferFunction.magnitudeDB.count == grid.count }) else {
            throw SpeakerMeasurementLabDriverCaptureError.incompatibleFrequencyGrid
        }
        guard let low = group.compactMap({ $0.quality.usableLowHz }).max(),
              let high = group.compactMap({ $0.quality.usableHighHz }).min(),
              low.isFinite, high.isFinite, low > 0, high > low else {
            throw SpeakerMeasurementLabDriverCaptureError.insufficientBandwidth
        }
        let indices = grid.indices.filter { grid[$0] >= low && grid[$0] <= high }
        guard indices.count >= Self.minimumPointCount else {
            throw SpeakerMeasurementLabDriverCaptureError.insufficientBandwidth
        }
        let levels = indices.map { index in
            group.reduce(0.0) { $0 + $1.transferFunction.magnitudeDB[index] } / Double(group.count)
        }
        guard levels.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabDriverCaptureError.incompatibleFrequencyGrid
        }

        return SpeakerMeasurementLabDriverCaptureResult(
            wayID: wayID,
            protocolID: labProtocol.id,
            linearisation: RoutedWayLinearisation(
                nearField: CrossoverCore.ResponseCapture(frequenciesHz: indices.map { grid[$0] }, levelsDB: levels),
                farField: nil,
                mergeHz: 0),
            usableLowHz: low,
            usableHighHz: high,
            evidenceConfidence: evidence.confidence,
            warnings: [
                "Near-field level is referenced to the microphone distance; the correction uses the response shape only.",
                "Without a far-field capture the response is not merged above the near-field baffle-step region, so apply it to the driver's passband only."
            ])
    }

    private func qualifiedEvidence(
        session: SpeakerMeasurementLabSession,
        labProtocol: SpeakerMeasurementLabProtocol,
        source: MultichannelCalibrationSource,
        group: [SpeakerMeasurementLabCapture]
    ) throws -> SpeakerOptimizerMeasurementGroupReport {
        let synthetic = SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            microphone: session.microphone,
            sampleRate: session.sampleRate,
            positions: [SpeakerOptimizerMeasurementPosition(id: labProtocol.id, name: labProtocol.name)],
            plannedSources: [source],
            captures: group.map { capture in
                SpeakerOptimizerMeasurementCapture(
                    id: capture.id, capturedAt: capture.capturedAt, playbackSystemID: capture.playbackSystemID,
                    routingSignature: capture.routingSignature, microphone: capture.microphone,
                    positionID: labProtocol.id, source: capture.source, sampleRate: capture.sampleRate,
                    response: capture.transferFunction, quality: capture.quality)
            },
            createdAt: session.createdAt,
            modifiedAt: session.modifiedAt)
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(synthetic)
        guard let evidence = report.groupReports.first else {
            throw SpeakerMeasurementLabDriverCaptureError.unqualifiedProtocol(labProtocol.id)
        }
        return evidence
    }

    private func gridsMatch(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0.0 - $0.1) <= max(1.0e-6, abs($0.0) * 1.0e-9) }
    }
}
