import Foundation

enum SpeakerMeasurementLabNearFieldComponentKind:
    String, CaseIterable, Codable, Equatable, Sendable {
    case radiator
    case port
    case passiveRadiator
    case other
}

/// Optional physical metadata for a subwoofer near-field protocol.
///
/// Effective radiating area is retained for future physically justified
/// component splicing, but Slice 5 intentionally does NOT synthesize a
/// far-field sum from it.
struct SpeakerMeasurementLabNearFieldComponent:
    Codable, Equatable, Sendable {
    var kind: SpeakerMeasurementLabNearFieldComponentKind
    var label: String?
    var effectiveRadiatingAreaSquareMeters: Double?

    func validate() -> Bool {
        if let label,
           label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if let area = effectiveRadiatingAreaSquareMeters {
            guard area.isFinite, (0.0001...1.0).contains(area) else {
                return false
            }
        }
        return true
    }
}

struct SpeakerMeasurementLabNearFieldLFOptions:
    Equatable, Sendable {
    var maximumAnalysisFrequencyHz: Double = 500
    var minimumComparisonPointCount: Int =
        SpeakerOptimizerMeasurementEvidenceEvaluator
            .minimumCommonResponsePointCount

    func validate() -> Bool {
        maximumAnalysisFrequencyHz.isFinite
            && (100...1_000).contains(maximumAnalysisFrequencyHz)
            && minimumComparisonPointCount >= 8
            && minimumComparisonPointCount <= 512
    }
}

struct SpeakerMeasurementLabNearFieldLFTrace:
    Codable, Equatable, Sendable {
    var protocolID: UUID
    var protocolName: String
    var component:
        SpeakerMeasurementLabNearFieldComponent?
    var distanceMeters: Double
    var frequenciesHz: [Double]
    var meanMagnitudeDB: [Double]
    /// Circular mean phase from the repeat-qualified transfer functions.
    /// It remains a LOCAL near-field diagnostic and is not a far-field phase
    /// prediction.
    var meanPhaseRadians: [Double]?
    var evidenceConfidence: Double
    var dominantMagnitudePeakHz: Double?
}

struct SpeakerMeasurementLabNearFieldLFRelativeTrace:
    Codable, Equatable, Sendable {
    var protocolID: UUID
    var relativeToProtocolID: UUID
    var frequenciesHz: [Double]
    var relativeMagnitudeDB: [Double]
    var wrappedRelativePhaseRadians: [Double]?
}

struct SpeakerMeasurementLabNearFieldMergeAssessment:
    Codable, Equatable, Sendable {
    var componentProtocolIDs: [UUID]
    var commonUsableLowHz: Double
    var commonUsableHighHz: Double
    var effectiveAreaMetadataComplete: Bool
    var phaseComparisonAvailable: Bool
    var canSynthesizeFarFieldComposite: Bool
    var blockingReasons: [String]
}

struct SpeakerMeasurementLabNearFieldLFReport:
    Codable, Equatable, Sendable {
    var sessionID: UUID
    var playbackSystemID: UUID
    var source: MultichannelCalibrationSource
    var commonUsableLowHz: Double
    var commonUsableHighHz: Double
    var traces: [SpeakerMeasurementLabNearFieldLFTrace]
    var relativeTraces:
        [SpeakerMeasurementLabNearFieldLFRelativeTrace]
    var mergeAssessment:
        SpeakerMeasurementLabNearFieldMergeAssessment
    var warnings: [String]

    var measurementOnly: Bool { true }
    var isFarFieldPrediction: Bool { false }
    var canDeploy: Bool { false }
}

enum SpeakerMeasurementLabNearFieldLFError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case invalidSession
    case protocolRequired
    case invalidProtocol(UUID)
    case sourceMismatch
    case unqualifiedProtocol(UUID)
    case incompatibleFrequencyGrid
    case insufficientCommonBandwidth

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Advanced Speaker Measurement Lab near-field LF options are invalid."
        case .invalidSession:
            return "Advanced Speaker Measurement Lab session is invalid."
        case .protocolRequired:
            return "Near-field LF analysis requires at least one subwoofer near-field protocol."
        case .invalidProtocol(let id):
            return "Lab protocol \(id.uuidString) is not a valid subwoofer near-field protocol."
        case .sourceMismatch:
            return "Near-field LF comparison protocols must measure the same physical subwoofer source."
        case .unqualifiedProtocol(let id):
            return "Lab protocol \(id.uuidString) does not have repeat-qualified near-field evidence."
        case .incompatibleFrequencyGrid:
            return "Near-field LF captures must share one finite strictly increasing frequency grid."
        case .insufficientCommonBandwidth:
            return "Near-field LF captures do not share enough qualified low-frequency bandwidth."
        }
    }
}

/// Repeat-qualified local subwoofer radiator / port diagnostics.
///
/// This analyzer intentionally refuses to manufacture a far-field composite.
/// Near-field component pressure is geometry dependent; combining radiator and
/// port traces defensibly needs explicit area scaling plus a justified
/// propagation/phase reference and a listening/far-field anchor. Slice 5
/// exposes the evidence needed to make that future decision without silently
/// pretending a dB-domain sum is physically valid.
struct SpeakerMeasurementLabNearFieldLFAnalyzer: Sendable {
    func analyze(
        session: SpeakerMeasurementLabSession,
        protocolIDs: [UUID]? = nil,
        options: SpeakerMeasurementLabNearFieldLFOptions = .init()
    ) throws -> SpeakerMeasurementLabNearFieldLFReport {
        guard options.validate() else {
            throw SpeakerMeasurementLabNearFieldLFError.invalidOptions
        }
        do {
            try session.validateStructure()
        } catch {
            throw SpeakerMeasurementLabNearFieldLFError.invalidSession
        }

        let requested = protocolIDs.map(Set.init)
        let protocols = session.protocols.filter { labProtocol in
            guard labProtocol.request.mode == .subwooferNearField else {
                return false
            }
            return requested?.contains(labProtocol.id) ?? true
        }
        guard !protocols.isEmpty else {
            throw SpeakerMeasurementLabNearFieldLFError.protocolRequired
        }

        for labProtocol in protocols {
            guard let source = labProtocol.acousticSource,
                  case .subwoofer = source else {
                throw SpeakerMeasurementLabNearFieldLFError
                    .invalidProtocol(labProtocol.id)
            }
            if let component = labProtocol.nearFieldComponent,
               !component.validate() {
                throw SpeakerMeasurementLabNearFieldLFError
                    .invalidProtocol(labProtocol.id)
            }
        }

        guard let source = protocols.first?.acousticSource,
              protocols.allSatisfy({ $0.acousticSource == source }) else {
            throw SpeakerMeasurementLabNearFieldLFError.sourceMismatch
        }

        var evidenceByProtocol:
            [UUID: SpeakerOptimizerMeasurementGroupReport] = [:]
        var allCaptures: [SpeakerMeasurementLabCapture] = []
        for labProtocol in protocols {
            let evidence = try qualifiedEvidence(
                session: session,
                labProtocol: labProtocol
            )
            guard evidence.optimizerReady else {
                throw SpeakerMeasurementLabNearFieldLFError
                    .unqualifiedProtocol(labProtocol.id)
            }
            evidenceByProtocol[labProtocol.id] = evidence
            allCaptures.append(
                contentsOf: captures(
                    session: session,
                    protocolID: labProtocol.id
                )
            )
        }

        guard let referenceGrid =
                allCaptures.first?.transferFunction.frequenciesHz,
              validGrid(referenceGrid),
              allCaptures.allSatisfy({
                  gridsMatch(
                      referenceGrid,
                      $0.transferFunction.frequenciesHz
                  )
              }) else {
            throw SpeakerMeasurementLabNearFieldLFError
                .incompatibleFrequencyGrid
        }

        guard let qualityLow = allCaptures.compactMap({
            $0.quality.usableLowHz
        }).max(),
        let qualityHigh = allCaptures.compactMap({
            $0.quality.usableHighHz
        }).min() else {
            throw SpeakerMeasurementLabNearFieldLFError
                .insufficientCommonBandwidth
        }
        let commonLow = qualityLow
        let commonHigh = min(
            qualityHigh,
            options.maximumAnalysisFrequencyHz
        )
        guard commonLow.isFinite,
              commonHigh.isFinite,
              commonLow > 0,
              commonHigh > commonLow else {
            throw SpeakerMeasurementLabNearFieldLFError
                .insufficientCommonBandwidth
        }
        let indices = referenceGrid.indices.filter {
            referenceGrid[$0] >= commonLow
                && referenceGrid[$0] <= commonHigh
        }
        guard indices.count >= options.minimumComparisonPointCount else {
            throw SpeakerMeasurementLabNearFieldLFError
                .insufficientCommonBandwidth
        }

        let frequencies = indices.map { referenceGrid[$0] }
        var traces: [SpeakerMeasurementLabNearFieldLFTrace] = []
        for labProtocol in protocols {
            let group = captures(
                session: session,
                protocolID: labProtocol.id
            )
            let magnitude = meanMagnitude(group, indices: indices)
            let phase = meanPhase(group, indices: indices)
            guard magnitude.count == frequencies.count,
                  magnitude.allSatisfy(\.isFinite),
                  let evidence = evidenceByProtocol[labProtocol.id] else {
                throw SpeakerMeasurementLabNearFieldLFError
                    .incompatibleFrequencyGrid
            }
            let peakIndex = magnitude.indices.max {
                magnitude[$0] < magnitude[$1]
            }
            traces.append(
                SpeakerMeasurementLabNearFieldLFTrace(
                    protocolID: labProtocol.id,
                    protocolName: labProtocol.name,
                    component: labProtocol.nearFieldComponent,
                    distanceMeters:
                        labProtocol.request.geometry.distanceMeters,
                    frequenciesHz: frequencies,
                    meanMagnitudeDB: magnitude,
                    meanPhaseRadians: phase,
                    evidenceConfidence: evidence.confidence,
                    dominantMagnitudePeakHz:
                        peakIndex.map { frequencies[$0] }
                )
            )
        }

        traces.sort {
            componentRank($0.component?.kind)
                < componentRank($1.component?.kind)
                || (
                    componentRank($0.component?.kind)
                        == componentRank($1.component?.kind)
                    && $0.protocolName < $1.protocolName
                )
        }

        let reference = traces[0]
        let relative = traces.dropFirst().map { trace in
            SpeakerMeasurementLabNearFieldLFRelativeTrace(
                protocolID: trace.protocolID,
                relativeToProtocolID: reference.protocolID,
                frequenciesHz: frequencies,
                relativeMagnitudeDB: zip(
                    trace.meanMagnitudeDB,
                    reference.meanMagnitudeDB
                ).map(-),
                wrappedRelativePhaseRadians:
                    relativePhase(
                        trace.meanPhaseRadians,
                        reference.meanPhaseRadians
                    )
            )
        }

        let metadataComplete = traces.count >= 2
            && traces.allSatisfy {
                $0.component?.effectiveRadiatingAreaSquareMeters != nil
            }
        let phaseAvailable = traces.count >= 2
            && traces.allSatisfy { $0.meanPhaseRadians != nil }

        var blockers: [String] = []
        if traces.count < 2 {
            blockers.append(
                "A component composite requires at least two separately measured near-field components."
            )
        }
        if !metadataComplete {
            blockers.append(
                "Effective radiating-area metadata is incomplete; component pressures cannot be area-scaled."
            )
        }
        if !phaseAvailable {
            blockers.append(
                "Repeat-qualified transfer phase is unavailable for one or more components."
            )
        }
        blockers.append(
            "Separate near-field microphone positions do not by themselves establish a far-field propagation/phase reference."
        )
        blockers.append(
            "A listening-position or otherwise justified far-field anchor is required before a component splice can represent system bass response."
        )

        return SpeakerMeasurementLabNearFieldLFReport(
            sessionID: session.id,
            playbackSystemID: session.playbackSystemID,
            source: source,
            commonUsableLowHz: commonLow,
            commonUsableHighHz: commonHigh,
            traces: traces,
            relativeTraces: relative,
            mergeAssessment:
                SpeakerMeasurementLabNearFieldMergeAssessment(
                    componentProtocolIDs: traces.map(\.protocolID),
                    commonUsableLowHz: commonLow,
                    commonUsableHighHz: commonHigh,
                    effectiveAreaMetadataComplete: metadataComplete,
                    phaseComparisonAvailable: phaseAvailable,
                    canSynthesizeFarFieldComposite: false,
                    blockingReasons: blockers
                ),
            warnings: [
                "Near-field traces describe local radiator/port pressure and are not listening-position bass response.",
                "Relative phase includes component acoustic path and microphone geometry; it is diagnostic evidence, not authenticated far-field phase.",
                "Slice 5 never sums component magnitudes in dB and never grants correction or deployment authority."
            ]
        )
    }

    private func qualifiedEvidence(
        session: SpeakerMeasurementLabSession,
        labProtocol: SpeakerMeasurementLabProtocol
    ) throws -> SpeakerOptimizerMeasurementGroupReport {
        guard let source = labProtocol.acousticSource else {
            throw SpeakerMeasurementLabNearFieldLFError
                .invalidProtocol(labProtocol.id)
        }
        let labCaptures = captures(
            session: session,
            protocolID: labProtocol.id
        )
        let position = SpeakerOptimizerMeasurementPosition(
            id: labProtocol.id,
            name: labProtocol.name
        )
        let syntheticCaptures = labCaptures.map { capture in
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
            captures: syntheticCaptures,
            createdAt: session.createdAt,
            modifiedAt: session.modifiedAt
        )
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator()
            .evaluate(synthetic)
        guard let group = report.groupReports.first else {
            throw SpeakerMeasurementLabNearFieldLFError
                .unqualifiedProtocol(labProtocol.id)
        }
        return group
    }

    private func captures(
        session: SpeakerMeasurementLabSession,
        protocolID: UUID
    ) -> [SpeakerMeasurementLabCapture] {
        session.captures.filter {
            $0.protocolID == protocolID
        }.sorted {
            if $0.repeatIndex != $1.repeatIndex {
                return $0.repeatIndex < $1.repeatIndex
            }
            return $0.capturedAt < $1.capturedAt
        }
    }

    private func validGrid(_ grid: [Double]) -> Bool {
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

    private func meanPhase(
        _ captures: [SpeakerMeasurementLabCapture],
        indices: [Int]
    ) -> [Double]? {
        guard !captures.isEmpty,
              captures.allSatisfy({
                  $0.transferFunction.phaseRadians != nil
              }) else {
            return nil
        }
        return indices.map { index in
            let values = captures.compactMap {
                $0.transferFunction.phaseRadians?[index]
            }
            let x = values.reduce(0.0) { $0 + cos($1) }
            let y = values.reduce(0.0) { $0 + sin($1) }
            return atan2(y, x)
        }
    }

    private func relativePhase(
        _ lhs: [Double]?,
        _ rhs: [Double]?
    ) -> [Double]? {
        guard let lhs, let rhs, lhs.count == rhs.count else {
            return nil
        }
        return zip(lhs, rhs).map {
            atan2(sin($0.0 - $0.1), cos($0.0 - $0.1))
        }
    }

    private func componentRank(
        _ kind: SpeakerMeasurementLabNearFieldComponentKind?
    ) -> Int {
        switch kind {
        case .radiator: return 0
        case .port: return 1
        case .passiveRadiator: return 2
        case .other: return 3
        case nil: return 4
        }
    }
}
