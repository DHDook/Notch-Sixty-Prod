import Foundation

struct RoomGeometryPoint3D: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    func distance(to other: RoomGeometryPoint3D) -> Double {
        hypot(
            hypot(x - other.x, y - other.y),
            z - other.z
        )
    }
}

struct RoomGeometryDimensions: Codable, Equatable, Sendable {
    var width: Double
    var length: Double
    var height: Double
}

struct RoomGeometryModel: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var projectID: UUID
    var dimensions: RoomGeometryDimensions
    var listener: RoomGeometryPoint3D
    var leftSpeaker: RoomGeometryPoint3D
    var rightSpeaker: RoomGeometryPoint3D
    var modifiedAt: Date = Date()

    static func template(projectID: UUID) -> Self {
        Self(
            projectID: projectID,
            dimensions: RoomGeometryDimensions(
                width: 4.0,
                length: 5.0,
                height: 2.5
            ),
            listener: RoomGeometryPoint3D(
                x: 2.0,
                y: 3.5,
                z: 1.1
            ),
            leftSpeaker: RoomGeometryPoint3D(
                x: 1.2,
                y: 0.75,
                z: 0.9
            ),
            rightSpeaker: RoomGeometryPoint3D(
                x: 2.8,
                y: 0.75,
                z: 0.9
            )
        )
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RoomGeometryError.unsupportedVersion(
                schemaVersion
            )
        }
        guard dimensions.width.isFinite,
              dimensions.length.isFinite,
              dimensions.height.isFinite,
              dimensions.width >= 1.5,
              dimensions.length >= 1.5,
              dimensions.height >= 1.8,
              dimensions.width <= 30,
              dimensions.length <= 30,
              dimensions.height <= 10 else {
            throw RoomGeometryError.invalidDimensions
        }
        try validatePoint(listener, name: "listener")
        try validatePoint(
            leftSpeaker,
            name: "left speaker"
        )
        try validatePoint(
            rightSpeaker,
            name: "right speaker"
        )
        guard leftSpeaker.x < rightSpeaker.x else {
            throw RoomGeometryError.invalidSpeakerOrder
        }
        guard leftSpeaker.distance(to: rightSpeaker) >= 0.3 else {
            throw RoomGeometryError.speakersTooClose
        }
        return self
    }

    private func validatePoint(
        _ point: RoomGeometryPoint3D,
        name: String
    ) throws {
        guard point.x.isFinite,
              point.y.isFinite,
              point.z.isFinite,
              point.x >= 0,
              point.x <= dimensions.width,
              point.y >= 0,
              point.y <= dimensions.length,
              point.z >= 0,
              point.z <= dimensions.height else {
            throw RoomGeometryError.pointOutsideRoom(name)
        }
    }
}

enum RoomGeometryError:
    Error, LocalizedError, Equatable
{
    case unsupportedVersion(Int)
    case invalidDimensions
    case pointOutsideRoom(String)
    case invalidSpeakerOrder
    case speakersTooClose
    case projectMismatch
    case corruptGeometry
    case noSelectedProject
    case noGeometry

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Room geometry uses unsupported schema version \(version)."
        case .invalidDimensions:
            return "Room dimensions must be finite and physically plausible."
        case .pointOutsideRoom(let name):
            return "The \(name) position must be inside the modeled room."
        case .invalidSpeakerOrder:
            return "The left speaker must be to the left of the right speaker."
        case .speakersTooClose:
            return "The modeled stereo speakers are unrealistically close together."
        case .projectMismatch:
            return "Room geometry belongs to a different measurement project."
        case .corruptGeometry:
            return "Saved room geometry is unreadable or corrupt."
        case .noSelectedProject:
            return "Select a measurement project before editing room geometry."
        case .noGeometry:
            return "Create or load a room geometry model first."
        }
    }
}

enum RoomGeometrySurface:
    String, CaseIterable, Codable, Equatable,
    Hashable, Sendable, Identifiable
{
    case leftWall
    case rightWall
    case frontWall
    case rearWall
    case floor
    case ceiling

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftWall: return "Left Wall"
        case .rightWall: return "Right Wall"
        case .frontWall: return "Front Wall"
        case .rearWall: return "Rear Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        }
    }
}

enum RoomGeometrySpeaker:
    String, CaseIterable, Codable, Equatable,
    Hashable, Sendable, Identifiable
{
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left Speaker"
        case .right: return "Right Speaker"
        }
    }
}

enum RoomModeType:
    String, Codable, Equatable, Hashable,
    Sendable, Identifiable
{
    case axial
    case tangential
    case oblique

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .axial: return "Axial"
        case .tangential: return "Tangential"
        case .oblique: return "Oblique"
        }
    }
}

struct RoomModePrediction:
    Identifiable, Equatable, Sendable
{
    var nx: Int
    var ny: Int
    var nz: Int
    var frequencyHz: Double
    var type: RoomModeType

    var id: String {
        "\(nx)-\(ny)-\(nz)"
    }

    var label: String {
        "\(type.displayName) (\(nx), \(ny), \(nz))"
    }
}

struct RoomReflectionPrediction:
    Identifiable, Equatable, Sendable
{
    var speaker: RoomGeometrySpeaker
    var surface: RoomGeometrySurface
    var reflectionPoint: RoomGeometryPoint3D
    var directPathMeters: Double
    var reflectedPathMeters: Double
    var excessPathMeters: Double
    var delayMilliseconds: Double

    var id: String {
        "\(speaker.rawValue)-\(surface.rawValue)"
    }
}

struct RoomBoundaryInterferencePrediction:
    Identifiable, Equatable, Sendable
{
    var speaker: RoomGeometrySpeaker
    var surface: RoomGeometrySurface
    var excessPathMeters: Double
    var firstCancellationHz: Double

    var id: String {
        "\(speaker.rawValue)-\(surface.rawValue)"
    }
}

enum RoomGeometryEvidenceStatus:
    String, Equatable, Sendable
{
    case predicted
    case supported
    case conflicted

    var displayName: String {
        switch self {
        case .predicted: return "Predicted"
        case .supported: return "Supported"
        case .conflicted: return "Conflicted"
        }
    }
}

enum RoomGeometryEvidenceKind:
    String, Equatable, Sendable
{
    case roomMode
    case boundaryInterference
    case firstReflection
}

struct RoomGeometryEvidenceMatch:
    Identifiable, Equatable, Sendable
{
    var id: String
    var kind: RoomGeometryEvidenceKind
    var status: RoomGeometryEvidenceStatus
    var title: String
    var prediction: String
    var measurement: String?
    var rationale: String
}

enum RoomPlacementMoveKind:
    String, Equatable, Sendable
{
    case listener
    case speakerPair
    case speakerSpacing
}

struct RoomPlacementCandidate:
    Identifiable, Equatable, Sendable
{
    var id: String
    var kind: RoomPlacementMoveKind
    var title: String
    var detail: String
    var listener: RoomGeometryPoint3D
    var leftSpeaker: RoomGeometryPoint3D
    var rightSpeaker: RoomGeometryPoint3D
    var score: Double
    var currentScore: Double
    var expectedImprovementPercent: Double
    var rationale: String
}

struct RoomGeometryAnalysis:
    Equatable, Sendable
{
    var modes: [RoomModePrediction]
    var reflections: [RoomReflectionPrediction]
    var boundaryInterference:
        [RoomBoundaryInterferencePrediction]
    var evidence: [RoomGeometryEvidenceMatch]
    var placementCandidates: [RoomPlacementCandidate]
}

struct RoomGeometryPlacementAnalyzer: Sendable {
    static let speedOfSoundMetersPerSecond = 343.0
    static let maximumModeFrequencyHz = 300.0
    static let maximumBoundaryFrequencyHz = 500.0
    static let modeMatchFraction = 0.06
    static let boundaryMatchFraction = 0.08
    static let reflectionMatchMilliseconds = 1.2

    func analyze(
        model: RoomGeometryModel,
        advisorReport: RoomTreatmentAdvisorReport?
    ) throws -> RoomGeometryAnalysis {
        let valid = try model.validated()
        let modes = roomModes(valid)
        let reflections = firstReflections(valid)
        let boundary = boundaryPredictions(
            reflections: reflections
        )
        let evidence = evidenceMatches(
            modes: modes,
            reflections: reflections,
            boundary: boundary,
            report: advisorReport
        )
        let placements = placementCandidates(
            model: valid,
            report: advisorReport
        )
        return RoomGeometryAnalysis(
            modes: modes,
            reflections: reflections,
            boundaryInterference: boundary,
            evidence: evidence,
            placementCandidates: placements
        )
    }

    func roomModes(
        _ model: RoomGeometryModel
    ) -> [RoomModePrediction] {
        let dimensions = model.dimensions
        var result: [RoomModePrediction] = []

        for nx in 0...6 {
            for ny in 0...6 {
                for nz in 0...6 {
                    let nonzero =
                        [nx, ny, nz]
                        .filter { $0 != 0 }
                        .count
                    guard nonzero > 0 else { continue }
                    let frequency =
                        Self.speedOfSoundMetersPerSecond
                        / 2
                        * sqrt(
                            pow(
                                Double(nx)
                                / dimensions.width,
                                2
                            )
                            + pow(
                                Double(ny)
                                / dimensions.length,
                                2
                            )
                            + pow(
                                Double(nz)
                                / dimensions.height,
                                2
                            )
                        )
                    guard frequency
                            <= Self.maximumModeFrequencyHz
                    else {
                        continue
                    }
                    let type: RoomModeType
                    switch nonzero {
                    case 1: type = .axial
                    case 2: type = .tangential
                    default: type = .oblique
                    }
                    result.append(
                        RoomModePrediction(
                            nx: nx,
                            ny: ny,
                            nz: nz,
                            frequencyHz: frequency,
                            type: type
                        )
                    )
                }
            }
        }
        return result.sorted {
            if $0.frequencyHz != $1.frequencyHz {
                return $0.frequencyHz
                    < $1.frequencyHz
            }
            return $0.id < $1.id
        }
    }

    func firstReflections(
        _ model: RoomGeometryModel
    ) -> [RoomReflectionPrediction] {
        var result: [RoomReflectionPrediction] = []
        for speaker in RoomGeometrySpeaker.allCases {
            let source =
                speaker == .left
                ? model.leftSpeaker
                : model.rightSpeaker
            let direct =
                source.distance(to: model.listener)
            for surface in RoomGeometrySurface.allCases {
                let image = imageSource(
                    source,
                    surface: surface,
                    dimensions: model.dimensions
                )
                let reflected =
                    image.distance(to: model.listener)
                let excess = reflected - direct
                guard excess > 1.0e-6,
                      let point = reflectionPoint(
                        listener: model.listener,
                        imageSource: image,
                        surface: surface,
                        dimensions: model.dimensions
                      )
                else {
                    continue
                }
                result.append(
                    RoomReflectionPrediction(
                        speaker: speaker,
                        surface: surface,
                        reflectionPoint: point,
                        directPathMeters: direct,
                        reflectedPathMeters: reflected,
                        excessPathMeters: excess,
                        delayMilliseconds:
                            excess
                            / Self
                                .speedOfSoundMetersPerSecond
                            * 1_000
                    )
                )
            }
        }
        return result.sorted {
            if $0.delayMilliseconds
                != $1.delayMilliseconds {
                return $0.delayMilliseconds
                    < $1.delayMilliseconds
            }
            return $0.id < $1.id
        }
    }

    func boundaryPredictions(
        reflections: [RoomReflectionPrediction]
    ) -> [RoomBoundaryInterferencePrediction] {
        reflections.compactMap { reflection in
            guard reflection.excessPathMeters > 0.05 else {
                return nil
            }
            let frequency =
                Self.speedOfSoundMetersPerSecond
                / (
                    2
                    * reflection.excessPathMeters
                )
            guard frequency >= 20,
                  frequency
                    <= Self.maximumBoundaryFrequencyHz
            else {
                return nil
            }
            return RoomBoundaryInterferencePrediction(
                speaker: reflection.speaker,
                surface: reflection.surface,
                excessPathMeters:
                    reflection.excessPathMeters,
                firstCancellationHz: frequency
            )
        }
        .sorted {
            if $0.firstCancellationHz
                != $1.firstCancellationHz {
                return $0.firstCancellationHz
                    < $1.firstCancellationHz
            }
            return $0.id < $1.id
        }
    }

    private func evidenceMatches(
        modes: [RoomModePrediction],
        reflections: [RoomReflectionPrediction],
        boundary: [RoomBoundaryInterferencePrediction],
        report: RoomTreatmentAdvisorReport?
    ) -> [RoomGeometryEvidenceMatch] {
        guard let report else {
            return strongestPredictions(
                modes: modes,
                reflections: reflections,
                boundary: boundary
            )
        }

        var result: [RoomGeometryEvidenceMatch] = []

        for finding in report.findings {
            switch finding.kind {
            case .lowFrequencyRinging:
                guard let measured =
                        finding.frequencyHz,
                      let mode = modes.min(by: {
                          abs($0.frequencyHz - measured)
                            < abs(
                                $1.frequencyHz
                                - measured
                            )
                      })
                else {
                    continue
                }
                let tolerance = max(
                    3,
                    measured * Self.modeMatchFraction
                )
                let delta =
                    abs(mode.frequencyHz - measured)
                result.append(
                    RoomGeometryEvidenceMatch(
                        id:
                            "mode-\(finding.id)-\(mode.id)",
                        kind: .roomMode,
                        status:
                            delta <= tolerance
                            ? .supported
                            : .conflicted,
                        title:
                            "Room-mode hypothesis near \(Int(measured.rounded())) Hz",
                        prediction: String(
                            format:
                                "%@ predicts %.1f Hz",
                            mode.label,
                            mode.frequencyHz
                        ),
                        measurement: String(
                            format:
                                "PR92 measured excess decay near %.1f Hz",
                            measured
                        ),
                        rationale:
                            delta <= tolerance
                            ? "The measured ringing frequency is close to a rectangular-room mode prediction."
                            : "The nearest rectangular-room mode does not align closely enough with the measured ringing; geometry alone should not label this resonance."
                    )
                )

            case .boundaryInterferenceCandidate,
                 .deepBassCancellation:
                guard let measured =
                        finding.frequencyHz,
                      let candidate =
                        boundary.min(by: {
                            abs(
                                $0.firstCancellationHz
                                - measured
                            )
                            < abs(
                                $1.firstCancellationHz
                                - measured
                            )
                        })
                else {
                    continue
                }
                let tolerance = max(
                    6,
                    measured
                        * Self.boundaryMatchFraction
                )
                let delta = abs(
                    candidate.firstCancellationHz
                    - measured
                )
                result.append(
                    RoomGeometryEvidenceMatch(
                        id:
                            "boundary-\(finding.id)-\(candidate.id)",
                        kind: .boundaryInterference,
                        status:
                            delta <= tolerance
                            ? .supported
                            : .conflicted,
                        title:
                            "Boundary-interference hypothesis near \(Int(measured.rounded())) Hz",
                        prediction: String(
                            format:
                                "%@ / %@ predicts %.1f Hz",
                            candidate.speaker
                                .displayName,
                            candidate.surface
                                .displayName,
                            candidate
                                .firstCancellationHz
                        ),
                        measurement: String(
                            format:
                                "PR92 measured a cancellation candidate near %.1f Hz",
                            measured
                        ),
                        rationale:
                            delta <= tolerance
                            ? "The measured null aligns with the first destructive path-difference candidate for this speaker/surface geometry."
                            : "The measured null does not align closely enough with the nearest modeled boundary path; verify placement before assigning an SBIR cause."
                    )
                )

            case .earlyReflection:
                guard let measured =
                        finding.delayMilliseconds,
                      let candidate =
                        reflections.min(by: {
                            abs(
                                $0.delayMilliseconds
                                - measured
                            )
                            < abs(
                                $1.delayMilliseconds
                                - measured
                            )
                        })
                else {
                    continue
                }
                let delta = abs(
                    candidate.delayMilliseconds
                    - measured
                )
                result.append(
                    RoomGeometryEvidenceMatch(
                        id:
                            "reflection-\(finding.id)-\(candidate.id)",
                        kind: .firstReflection,
                        status:
                            delta
                                <= Self
                                    .reflectionMatchMilliseconds
                            ? .supported
                            : .conflicted,
                        title:
                            "First-reflection path near \(String(format: "%.1f", measured)) ms",
                        prediction: String(
                            format:
                                "%@ / %@ predicts %.1f ms",
                            candidate.speaker
                                .displayName,
                            candidate.surface
                                .displayName,
                            candidate.delayMilliseconds
                        ),
                        measurement: String(
                            format:
                                "PR92 measured an early reflection at %.1f ms",
                            measured
                        ),
                        rationale:
                            delta
                                <= Self
                                    .reflectionMatchMilliseconds
                            ? "The measured reflection delay is compatible with this modeled first-order path. Surface amplitude is still a measured, not geometric, property."
                            : "The measured reflection timing does not match the nearest modeled first-order path closely enough."
                    )
                )

            default:
                continue
            }
        }

        if result.isEmpty {
            return strongestPredictions(
                modes: modes,
                reflections: reflections,
                boundary: boundary
            )
        }
        return result
    }

    private func strongestPredictions(
        modes: [RoomModePrediction],
        reflections: [RoomReflectionPrediction],
        boundary: [RoomBoundaryInterferencePrediction]
    ) -> [RoomGeometryEvidenceMatch] {
        var result: [RoomGeometryEvidenceMatch] = []
        for mode in modes
            .filter({ $0.type == .axial })
            .prefix(3) {
            result.append(
                RoomGeometryEvidenceMatch(
                    id: "predicted-mode-\(mode.id)",
                    kind: .roomMode,
                    status: .predicted,
                    title: mode.label,
                    prediction: String(
                        format:
                            "Predicted at %.1f Hz",
                        mode.frequencyHz
                    ),
                    measurement: nil,
                    rationale:
                        "Geometry predicts this mode, but PR92 has not supplied matching excess-decay evidence."
                )
            )
        }
        for reflection in reflections.prefix(2) {
            result.append(
                RoomGeometryEvidenceMatch(
                    id:
                        "predicted-reflection-\(reflection.id)",
                    kind: .firstReflection,
                    status: .predicted,
                    title:
                        "\(reflection.speaker.displayName) · \(reflection.surface.displayName)",
                    prediction: String(
                        format:
                            "First-order path %.1f ms after direct sound",
                        reflection.delayMilliseconds
                    ),
                    measurement: nil,
                    rationale:
                        "Image-source geometry predicts the path; measured impulse energy is required before treating the surface as acoustically important."
                )
            )
        }
        for item in boundary.prefix(2) {
            result.append(
                RoomGeometryEvidenceMatch(
                    id:
                        "predicted-boundary-\(item.id)",
                    kind: .boundaryInterference,
                    status: .predicted,
                    title:
                        "\(item.speaker.displayName) · \(item.surface.displayName)",
                    prediction: String(
                        format:
                            "First cancellation candidate %.1f Hz",
                        item.firstCancellationHz
                    ),
                    measurement: nil,
                    rationale:
                        "Geometry predicts a path-difference cancellation, but a measured null is required before assigning an SBIR cause."
                )
            )
        }
        return result
    }

    private func placementCandidates(
        model: RoomGeometryModel,
        report: RoomTreatmentAdvisorReport?
    ) -> [RoomPlacementCandidate] {
        let problems = problemFrequencies(report)
        let currentScore = placementScore(
            model,
            problemFrequencies: problems
        )
        guard currentScore.isFinite,
              currentScore > 0 else {
            return []
        }

        var candidates:
            [(id: String, title: String, detail: String, kind: RoomPlacementMoveKind, model: RoomGeometryModel)] = []

        let listenerOffsets: [
            (dx: Double, dy: Double)
        ] = [
            (-0.35, 0),
            (0.35, 0),
            (0, -0.30),
            (0, 0.30),
            (0, -0.60),
            (0, 0.60),
        ]
        for offset in listenerOffsets {
            var candidate = model
            candidate.listener.x += offset.dx
            candidate.listener.y += offset.dy
            guard (try? candidate.validated()) != nil,
                  candidate.listener.x >= 0.25,
                  candidate.listener.x
                    <= model.dimensions.width - 0.25,
                  candidate.listener.y >= 0.25,
                  candidate.listener.y
                    <= model.dimensions.length - 0.25
            else {
                continue
            }
            let direction =
                placementDirection(
                    dx: offset.dx,
                    dy: offset.dy
                )
            candidates.append(
                (
                    id:
                        "listener-\(offset.dx)-\(offset.dy)",
                    title:
                        "Move listening position \(direction)",
                    detail: String(
                        format:
                            "Test a %.0f cm listener move.",
                        hypot(
                            offset.dx,
                            offset.dy
                        ) * 100
                    ),
                    kind: .listener,
                    model: candidate
                )
            )
        }

        for deltaY in [-0.40, -0.20, 0.20, 0.40] {
            var candidate = model
            candidate.leftSpeaker.y += deltaY
            candidate.rightSpeaker.y += deltaY
            guard (try? candidate.validated()) != nil,
                  candidate.leftSpeaker.y >= 0.15,
                  candidate.rightSpeaker.y >= 0.15,
                  candidate.leftSpeaker.y
                    <= model.dimensions.length - 0.15,
                  candidate.rightSpeaker.y
                    <= model.dimensions.length - 0.15
            else {
                continue
            }
            let direction =
                deltaY < 0 ? "toward the front wall" : "away from the front wall"
            candidates.append(
                (
                    id: "pair-y-\(deltaY)",
                    title:
                        "Move both speakers \(direction)",
                    detail: String(
                        format:
                            "Test a %.0f cm pair translation.",
                        abs(deltaY) * 100
                    ),
                    kind: .speakerPair,
                    model: candidate
                )
            )
        }

        for spacingDelta in [-0.40, -0.20, 0.20, 0.40] {
            var candidate = model
            candidate.leftSpeaker.x -=
                spacingDelta / 2
            candidate.rightSpeaker.x +=
                spacingDelta / 2
            guard (try? candidate.validated()) != nil,
                  candidate.leftSpeaker.x >= 0.15,
                  candidate.rightSpeaker.x
                    <= model.dimensions.width - 0.15
            else {
                continue
            }
            let direction =
                spacingDelta > 0 ? "Widen" : "Narrow"
            candidates.append(
                (
                    id: "spacing-\(spacingDelta)",
                    title:
                        "\(direction) speaker spacing",
                    detail: String(
                        format:
                            "Test a %.0f cm total spacing change.",
                        abs(spacingDelta) * 100
                    ),
                    kind: .speakerSpacing,
                    model: candidate
                )
            )
        }

        return candidates.compactMap { candidate in
            let score = placementScore(
                candidate.model,
                problemFrequencies: problems
            )
            guard score.isFinite,
                  score < currentScore * 0.985
            else {
                return nil
            }
            let improvement = max(
                0,
                (currentScore - score)
                / currentScore * 100
            )
            return RoomPlacementCandidate(
                id: candidate.id,
                kind: candidate.kind,
                title: candidate.title,
                detail: candidate.detail,
                listener:
                    candidate.model.listener,
                leftSpeaker:
                    candidate.model.leftSpeaker,
                rightSpeaker:
                    candidate.model.rightSpeaker,
                score: score,
                currentScore: currentScore,
                expectedImprovementPercent:
                    improvement,
                rationale:
                    placementRationale(
                        candidate.model,
                        problemFrequencies: problems
                    )
            )
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score < $1.score
            }
            return $0.id < $1.id
        }
        .prefix(5)
        .map { $0 }
    }

    private func problemFrequencies(
        _ report: RoomTreatmentAdvisorReport?
    ) -> [Double] {
        guard let report else { return [] }
        return report.findings.compactMap { finding in
            switch finding.kind {
            case .lowFrequencyRinging,
                 .boundaryInterferenceCandidate,
                 .deepBassCancellation,
                 .spatialBassVariation:
                return finding.frequencyHz
            default:
                return nil
            }
        }
        .filter { $0 >= 30 && $0 <= 250 }
    }

    private func placementScore(
        _ model: RoomGeometryModel,
        problemFrequencies: [Double]
    ) -> Double {
        let modes = roomModes(model)
        let reflections = firstReflections(model)
        let boundary = boundaryPredictions(
            reflections: reflections
        )

        var score = 0.0
        let frequencies =
            problemFrequencies.isEmpty
            ? modes
                .filter {
                    $0.type == .axial
                        && $0.frequencyHz <= 180
                }
                .prefix(6)
                .map(\.frequencyHz)
            : problemFrequencies

        for frequency in frequencies {
            if let mode = modes.min(by: {
                abs($0.frequencyHz - frequency)
                    < abs($1.frequencyHz - frequency)
            }) {
                let proximity =
                    frequencyProximity(
                        mode.frequencyHz,
                        frequency,
                        toleranceFraction: 0.12
                    )
                score +=
                    proximity
                    * modalCoupling(
                        mode: mode,
                        model: model
                    )
                    * 4
            }

            if let notch = boundary.min(by: {
                abs(
                    $0.firstCancellationHz
                    - frequency
                )
                    < abs(
                        $1.firstCancellationHz
                        - frequency
                    )
            }) {
                score +=
                    frequencyProximity(
                        notch.firstCancellationHz,
                        frequency,
                        toleranceFraction: 0.15
                    )
                    * 3
            }
        }

        for reflection in reflections
            where reflection.delayMilliseconds < 8 {
            score +=
                max(
                    0,
                    (8 - reflection.delayMilliseconds)
                    / 8
                )
                * 0.35
        }

        // Light practical regularization prevents tiny theoretical gains from
        // dominating over simple, repeatable placements.
        let symmetryCenter =
            model.dimensions.width / 2
        score +=
            abs(model.listener.x - symmetryCenter)
            / model.dimensions.width
            * 0.15

        return score + 0.05
    }

    private func modalCoupling(
        mode: RoomModePrediction,
        model: RoomGeometryModel
    ) -> Double {
        let listener =
            modeShape(
                mode,
                at: model.listener,
                dimensions: model.dimensions
            )
        let left =
            modeShape(
                mode,
                at: model.leftSpeaker,
                dimensions: model.dimensions
            )
        let right =
            modeShape(
                mode,
                at: model.rightSpeaker,
                dimensions: model.dimensions
            )
        let source =
            (abs(left) + abs(right)) / 2
        return abs(listener) * source
    }

    private func modeShape(
        _ mode: RoomModePrediction,
        at point: RoomGeometryPoint3D,
        dimensions: RoomGeometryDimensions
    ) -> Double {
        cos(
            Double(mode.nx)
            * Double.pi
            * point.x / dimensions.width
        )
        * cos(
            Double(mode.ny)
            * Double.pi
            * point.y / dimensions.length
        )
        * cos(
            Double(mode.nz)
            * Double.pi
            * point.z / dimensions.height
        )
    }

    private func placementRationale(
        _ model: RoomGeometryModel,
        problemFrequencies: [Double]
    ) -> String {
        guard !problemFrequencies.isEmpty else {
            return "The modeled move reduces low-frequency modal coupling and/or very-early reflection pressure in the rectangular-room prediction."
        }

        let list =
            problemFrequencies
            .prefix(3)
            .map {
                String(
                    format: "%.0f Hz",
                    $0
                )
            }
            .joined(separator: ", ")
        return "The modeled move lowers combined mode/boundary risk around the measured problem frequencies (\(list)). Treat this as a placement experiment and re-measure before keeping it."
    }

    private func frequencyProximity(
        _ predicted: Double,
        _ measured: Double,
        toleranceFraction: Double
    ) -> Double {
        guard predicted > 0,
              measured > 0,
              toleranceFraction > 0 else {
            return 0
        }
        let difference =
            abs(log(predicted / measured))
        let limit = log(1 + toleranceFraction)
        return max(0, 1 - difference / limit)
    }

    private func placementDirection(
        dx: Double,
        dy: Double
    ) -> String {
        if abs(dx) > abs(dy) {
            return dx < 0 ? "left" : "right"
        }
        return dy < 0 ? "forward" : "back"
    }

    private func imageSource(
        _ source: RoomGeometryPoint3D,
        surface: RoomGeometrySurface,
        dimensions: RoomGeometryDimensions
    ) -> RoomGeometryPoint3D {
        switch surface {
        case .leftWall:
            return RoomGeometryPoint3D(
                x: -source.x,
                y: source.y,
                z: source.z
            )
        case .rightWall:
            return RoomGeometryPoint3D(
                x:
                    2 * dimensions.width
                    - source.x,
                y: source.y,
                z: source.z
            )
        case .frontWall:
            return RoomGeometryPoint3D(
                x: source.x,
                y: -source.y,
                z: source.z
            )
        case .rearWall:
            return RoomGeometryPoint3D(
                x: source.x,
                y:
                    2 * dimensions.length
                    - source.y,
                z: source.z
            )
        case .floor:
            return RoomGeometryPoint3D(
                x: source.x,
                y: source.y,
                z: -source.z
            )
        case .ceiling:
            return RoomGeometryPoint3D(
                x: source.x,
                y: source.y,
                z:
                    2 * dimensions.height
                    - source.z
            )
        }
    }

    private func reflectionPoint(
        listener: RoomGeometryPoint3D,
        imageSource: RoomGeometryPoint3D,
        surface: RoomGeometrySurface,
        dimensions: RoomGeometryDimensions
    ) -> RoomGeometryPoint3D? {
        let target: Double
        let listenerCoordinate: Double
        let imageCoordinate: Double

        switch surface {
        case .leftWall:
            target = 0
            listenerCoordinate = listener.x
            imageCoordinate = imageSource.x
        case .rightWall:
            target = dimensions.width
            listenerCoordinate = listener.x
            imageCoordinate = imageSource.x
        case .frontWall:
            target = 0
            listenerCoordinate = listener.y
            imageCoordinate = imageSource.y
        case .rearWall:
            target = dimensions.length
            listenerCoordinate = listener.y
            imageCoordinate = imageSource.y
        case .floor:
            target = 0
            listenerCoordinate = listener.z
            imageCoordinate = imageSource.z
        case .ceiling:
            target = dimensions.height
            listenerCoordinate = listener.z
            imageCoordinate = imageSource.z
        }

        let denominator =
            imageCoordinate - listenerCoordinate
        guard abs(denominator) > 1.0e-9 else {
            return nil
        }
        let t =
            (target - listenerCoordinate)
            / denominator
        guard t >= 0, t <= 1 else {
            return nil
        }

        let point = RoomGeometryPoint3D(
            x:
                listener.x
                + t * (imageSource.x - listener.x),
            y:
                listener.y
                + t * (imageSource.y - listener.y),
            z:
                listener.z
                + t * (imageSource.z - listener.z)
        )
        guard point.x >= -1.0e-6,
              point.x
                <= dimensions.width + 1.0e-6,
              point.y >= -1.0e-6,
              point.y
                <= dimensions.length + 1.0e-6,
              point.z >= -1.0e-6,
              point.z
                <= dimensions.height + 1.0e-6
        else {
            return nil
        }
        return point
    }
}

struct RoomGeometryStore: Sendable {
    let projectStore: RoomCorrectionProjectStore

    init(projectStore: RoomCorrectionProjectStore) {
        self.projectStore = projectStore
    }

    func geometryURL(for projectID: UUID) -> URL {
        projectStore
            .projectDirectory(for: projectID)
            .appendingPathComponent(
                "advisor-geometry-v1.json",
                isDirectory: false
            )
    }

    func load(
        projectID: UUID
    ) throws -> RoomGeometryModel? {
        let url = geometryURL(for: projectID)
        guard FileManager.default
                .fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let model = try JSONDecoder()
                .decode(
                    RoomGeometryModel.self,
                    from: data
                )
            guard model.projectID == projectID else {
                throw RoomGeometryError.projectMismatch
            }
            return try model.validated()
        } catch let error as RoomGeometryError {
            throw error
        } catch {
            throw RoomGeometryError.corruptGeometry
        }
    }

    @discardableResult
    func save(
        _ model: RoomGeometryModel
    ) throws -> URL {
        let valid = try model.validated()
        let directory =
            projectStore.projectDirectory(
                for: valid.projectID
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        let data = try encoder.encode(valid)
        let url = geometryURL(
            for: valid.projectID
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    func delete(projectID: UUID) throws {
        let url = geometryURL(for: projectID)
        guard FileManager.default
                .fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}


// MARK: - PR110: read-only advanced placement experiments

/// Optional, project-scoped experiment geometry. No DSP/profile ownership.
/// Secondary seats and physical Sub positions supplement the PR93 room model
/// without changing its versioned JSON schema or saved state.
struct RoomAdvancedPlacementState: Equatable, Sendable {
    var room: RoomGeometryModel
    var secondarySeats: [RoomGeometryPoint3D] = []
    var leftToeInDegrees: Double = 0
    var rightToeInDegrees: Double = 0
    var subwooferPositions: [RoomGeometryPoint3D] = []

    func validated() throws -> Self {
        _ = try room.validated()
        guard secondarySeats.count <= 7,
              subwooferPositions.count <= 4,
              leftToeInDegrees.isFinite,
              rightToeInDegrees.isFinite,
              abs(leftToeInDegrees) <= 80,
              abs(rightToeInDegrees) <= 80 else {
            throw RoomAdvancedPlacementError.invalidConfiguration
        }
        for point in secondarySeats + subwooferPositions {
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                  point.x >= 0, point.x <= room.dimensions.width,
                  point.y >= 0, point.y <= room.dimensions.length,
                  point.z >= 0, point.z <= room.dimensions.height else {
                throw RoomAdvancedPlacementError.invalidConfiguration
            }
        }
        return self
    }
}

enum RoomAdvancedPlacementError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case corruptSettings

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Advanced placement must match this project and stay inside the room limits."
        case .corruptSettings:
            return "Saved advanced placement settings could not be read; the original room geometry was preserved."
        }
    }
}

enum RoomAdvancedPlacementMove: String, Equatable, Sendable {
    case leftSpeaker
    case rightSpeaker
    case leftToeIn
    case rightToeIn
    case leftHeight
    case rightHeight
    case subwoofer
}

/// This is a *physical experiment*, not a correction plan or an acoustic
/// prediction. No source here owns a profile mutation, DSP graph or Apply API.
struct RoomAdvancedPlacementExperiment: Identifiable, Equatable, Sendable {
    var id: String
    var move: RoomAdvancedPlacementMove
    var description: String
    var trial: RoomAdvancedPlacementState
    var movementMeters: Double
    /// Pure path-length diagnostic, NOT a frequency response or SPL estimate.
    var maximumSeatPathImbalanceMeters: Double
    var evidenceLabel: String { "Geometry hypothesis — measurement required" }
    var requiresMeasuredVerification: Bool { true }
}

/// Reuses PR93's validated coordinates. Search is intentionally small:
/// independently move L/R by 15 cm, try 10 cm height changes, ±5° toe-in,
/// and move each modeled physical Sub 30 cm in x/y. These are bounded,
/// unranked *experiments*; room geometry alone does not authorize claiming
/// any before/after dB, phase, SPL, decay or perceived-image improvement.
///
/// Later PR110 slices will add source-specific microphone evidence, toe-in
/// directivity matching, multi-seat scoring and measured before/after checks.
struct RoomAdvancedPlacementExplorer: Sendable {
    func experiments(
        for original: RoomAdvancedPlacementState
    ) throws -> [RoomAdvancedPlacementExperiment] {
        let state = try original.validated()
        var results: [RoomAdvancedPlacementExperiment] = []

        func include(
            _ id: String,
            move: RoomAdvancedPlacementMove,
            description: String,
            trial: RoomAdvancedPlacementState,
            movement: Double
        ) {
            guard (try? trial.validated()) != nil,
                  trial != state else { return }
            results.append(
                RoomAdvancedPlacementExperiment(
                    id: id,
                    move: move,
                    description: description,
                    trial: trial,
                    movementMeters: movement,
                    maximumSeatPathImbalanceMeters:
                        maximumSeatPathImbalance(trial)
                )
            )
        }

        for (side, kind) in [
            (RoomGeometrySpeaker.left, RoomAdvancedPlacementMove.leftSpeaker),
            (.right, .rightSpeaker),
        ] {
            for (axis, shift) in [
                ("left", -0.15), ("right", 0.15),
                ("forward", -0.15), ("back", 0.15),
            ] {
                var trial = state
                var point = side == .left
                    ? trial.room.leftSpeaker : trial.room.rightSpeaker
                if axis == "left" || axis == "right" {
                    point.x += shift
                } else {
                    point.y += shift
                }
                if side == .left {
                    trial.room.leftSpeaker = point
                } else {
                    trial.room.rightSpeaker = point
                }
                include(
                    "\(side.rawValue)-\(axis)",
                    move: kind,
                    description: "Move \(side.displayName) \(axis) by 15 cm",
                    trial: trial,
                    movement: 0.15
                )
            }
            for (direction, adjustment) in [
                ("lower", -0.10), ("higher", 0.10),
            ] {
                var trial = state
                if side == .left {
                    trial.room.leftSpeaker.z += adjustment
                } else {
                    trial.room.rightSpeaker.z += adjustment
                }
                include(
                    "\(side.rawValue)-height-\(direction)",
                    move: side == .left ? .leftHeight : .rightHeight,
                    description:
                        "Move \(side.displayName) \(direction) by 10 cm",
                    trial: trial,
                    movement: 0.10
                )
            }
            for (direction, adjustment) in [
                ("clockwise", -5.0), ("counterclockwise", 5.0),
            ] {
                var trial = state
                if side == .left {
                    trial.leftToeInDegrees += adjustment
                } else {
                    trial.rightToeInDegrees += adjustment
                }
                include(
                    "\(side.rawValue)-toe-\(direction)",
                    move: side == .left ? .leftToeIn : .rightToeIn,
                    description:
                        "Rotate \(side.displayName) \(direction) by 5°",
                    trial: trial,
                    movement: 0
                )
            }
        }

        for subIndex in state.subwooferPositions.indices {
            for (direction, dx, dy) in [
                ("left", -0.30, 0.0),
                ("right", 0.30, 0.0),
                ("forward", 0.0, -0.30),
                ("back", 0.0, 0.30),
            ] {
                var trial = state
                trial.subwooferPositions[subIndex].x += dx
                trial.subwooferPositions[subIndex].y += dy
                include(
                    "sub-\(subIndex)-\(direction)",
                    move: .subwoofer,
                    description:
                        "Move Sub \(subIndex + 1) \(direction) by 30 cm",
                    trial: trial,
                    movement: 0.30
                )
            }
        }
        return results
    }

    /// Tracks L/R direct-path symmetry across every specified seat.
    /// This is useful diagnostic context, never a scalar acoustic quality
    /// score and never a license to apply EQ or physical sub alignment.
    func maximumSeatPathImbalance(
        _ state: RoomAdvancedPlacementState
    ) -> Double {
        let seats = [state.room.listener] + state.secondarySeats
        return seats.map { seat in
            abs(
                state.room.leftSpeaker.distance(to: seat)
                - state.room.rightSpeaker.distance(to: seat)
            )
        }.max() ?? 0
    }
}


// MARK: - PR110 Slice 2: project-only advanced placement sidecar

/// Versioned sidecar deliberately independent of the existing PR93 geometry
/// JSON and of the persisted Playback System / Content Preset.
struct RoomAdvancedPlacementSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var projectID: UUID
    var secondarySeats: [RoomGeometryPoint3D] = []
    var leftToeInDegrees: Double = 0
    var rightToeInDegrees: Double = 0
    var subwooferPositions: [RoomGeometryPoint3D] = []

    func state(for room: RoomGeometryModel) throws -> RoomAdvancedPlacementState {
        guard schemaVersion == Self.currentSchemaVersion,
              projectID == room.projectID else {
            throw RoomAdvancedPlacementError.invalidConfiguration
        }
        return try RoomAdvancedPlacementState(
            room: room,
            secondarySeats: secondarySeats,
            leftToeInDegrees: leftToeInDegrees,
            rightToeInDegrees: rightToeInDegrees,
            subwooferPositions: subwooferPositions
        ).validated()
    }

    static func from(
        _ state: RoomAdvancedPlacementState
    ) throws -> Self {
        let checked = try state.validated()
        return Self(
            projectID: checked.room.projectID,
            secondarySeats: checked.secondarySeats,
            leftToeInDegrees: checked.leftToeInDegrees,
            rightToeInDegrees: checked.rightToeInDegrees,
            subwooferPositions: checked.subwooferPositions
        )
    }
}

/// No automatic migration of PR93; unsupported/corrupted new sidecars fail
/// closed without deleting the existing base room geometry.
struct RoomAdvancedPlacementStore: Sendable {
    let projectStore: RoomCorrectionProjectStore

    func settingsURL(for projectID: UUID) -> URL {
        projectStore.projectDirectory(for: projectID)
            .appendingPathComponent(
                "advisor-advanced-placement-v1.json", isDirectory: false
            )
    }

    func load(
        projectID: UUID,
        room: RoomGeometryModel
    ) throws -> RoomAdvancedPlacementSettings? {
        guard projectID == room.projectID else {
            throw RoomAdvancedPlacementError.invalidConfiguration
        }
        let url = settingsURL(for: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let decoded: RoomAdvancedPlacementSettings
        do {
            decoded = try JSONDecoder().decode(
                RoomAdvancedPlacementSettings.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw RoomAdvancedPlacementError.corruptSettings
        }
        _ = try decoded.state(for: room)
        return decoded
    }

    @discardableResult
    func save(
        _ settings: RoomAdvancedPlacementSettings,
        room: RoomGeometryModel
    ) throws -> URL {
        _ = try settings.state(for: room)
        let directory = projectStore.projectDirectory(
            for: settings.projectID
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = settingsURL(for: settings.projectID)
        try encoder.encode(settings).write(
            to: destination, options: .atomic
        )
        return destination
    }

    func delete(projectID: UUID) throws {
        let destination = settingsURL(for: projectID)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        try FileManager.default.removeItem(at: destination)
    }
}


// MARK: - PR110 Slice 3: qualified, measurement-informed toe-in advice

/// A scored *spectral orientation experiment*, never proof of in-room
/// improvement. Angles in this model are signed clockwise from the room's
/// forward (+Y) axis: positive toe-in rotates toward +X.
enum RoomAdvancedDirectivityStatus: String, Equatable, Sendable {
    case measuredComparison
    case inconclusive
}

struct RoomAdvancedToeInEvidence: Equatable, Sendable {
    var experimentID: String
    var speaker: RoomGeometrySpeaker
    var status: RoomAdvancedDirectivityStatus
    var sessionID: UUID?
    var sourceProtocolID: UUID?
    var currentAxisOffsetDegrees: Double
    var trialAxisOffsetDegrees: Double
    /// Mean |off-axis minus on-axis magnitude| over an actually supported
    /// 1–8 kHz grid. Diagnostic preference for on-axis spectral similarity;
    /// NOT a predicted in-room improvement or acoustic score.
    var currentAbsoluteDeviationDB: Double?
    var trialAbsoluteDeviationDB: Double?
    var confidence: Double?
    var note: String

    var indicatedSpectralChangeDB: Double? {
        guard let baseline = currentAbsoluteDeviationDB,
              let trial = trialAbsoluteDeviationDB else { return nil }
        return baseline - trial
    }
}

enum RoomAdvancedDirectivityError: Error, LocalizedError, Equatable {
    case invalidProjectIdentity
    case invalidSource
    case unqualifiedLabEvidence

    var errorDescription: String? {
        switch self {
        case .invalidProjectIdentity:
            return "Directivity evidence belongs to a different Playback System."
        case .invalidSource:
            return "Use on-axis whole-speaker evidence for the requested left/right speaker."
        case .unqualifiedLabEvidence:
            return "Measurement Lab evidence did not pass the repeated-capture directivity quality gates."
        }
    }
}

struct RoomAdvancedToeInEvidenceAnalyzer: Sendable {
    static let minimumQualifiedConfidence =
        SpeakerOptimizerMeasurementEvidenceEvaluator.minimumOptimizerConfidence
    static let minimumFrequencyHz = 1_000.0
    static let maximumFrequencyHz = 8_000.0
    static let maximumMeasuredAngularGapDegrees = 20.0

    /// Never accept a caller-supplied directivity report as verified evidence:
    /// derive it by re-running PR106's repeat-qualified analyzer on the actual
    /// session, including source/radius/SNR/clipping/mic/routing quality gates.
    func evaluate(
        state: RoomAdvancedPlacementState,
        playbackSystemID: UUID,
        session: SpeakerMeasurementLabSession,
        onAxisProtocolID: UUID,
        speaker: RoomGeometrySpeaker
    ) throws -> [RoomAdvancedToeInEvidence] {
        let valid = try state.validated()
        guard session.playbackSystemID == playbackSystemID else {
            throw RoomAdvancedDirectivityError.invalidProjectIdentity
        }
        let report: SpeakerMeasurementLabDirectivityReport
        do {
            report = try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxisProtocolID
                )
        } catch {
            throw RoomAdvancedDirectivityError.unqualifiedLabEvidence
        }
        let requiredSource: MultichannelCalibrationSource =
            .speaker(speaker == .left ? .frontLeft : .frontRight)
        guard report.source == requiredSource,
              report.sessionID == session.id,
              report.playbackSystemID == playbackSystemID else {
            throw RoomAdvancedDirectivityError.invalidSource
        }
        return evaluateQualifiedReport(
            report: report,
            state: valid,
            speaker: speaker
        )
    }

    /// Internal pure scoring seam. The production boundary above MUST
    /// authenticate the report through the Lab analyzer before calling it.
    func evaluateQualifiedReport(
        report: SpeakerMeasurementLabDirectivityReport,
        state: RoomAdvancedPlacementState,
        speaker: RoomGeometrySpeaker
    ) -> [RoomAdvancedToeInEvidence] {
        let experiments = (try? RoomAdvancedPlacementExplorer()
            .experiments(for: state)) ?? []
        let origin = speaker == .left
            ? state.room.leftSpeaker : state.room.rightSpeaker
        let toe = speaker == .left
            ? state.leftToeInDegrees : state.rightToeInDegrees
        let current = offset(
            from: origin, to: state.room.listener, toeIn: toe
        )
        let expectedMove: RoomAdvancedPlacementMove =
            speaker == .left ? .leftToeIn : .rightToeIn

        let results: [RoomAdvancedToeInEvidence] = experiments
            .filter { $0.move == expectedMove }
            .map { trial in
                let changedToe = speaker == .left
                    ? trial.trial.leftToeInDegrees
                    : trial.trial.rightToeInDegrees
                let target = offset(
                    from: origin,
                    to: state.room.listener,
                    toeIn: changedToe
                )
                let before = spectralDeviation(report, angle: current)
                let after = spectralDeviation(report, angle: target)
                let qualified = before != nil && after != nil
                return RoomAdvancedToeInEvidence(
                    experimentID: trial.id,
                    speaker: speaker,
                    status: qualified ? .measuredComparison : .inconclusive,
                    sessionID: report.sessionID,
                    sourceProtocolID: report.onAxisProtocolID,
                    currentAxisOffsetDegrees: current,
                    trialAxisOffsetDegrees: target,
                    currentAbsoluteDeviationDB: before?.value,
                    trialAbsoluteDeviationDB: after?.value,
                    confidence: qualified
                        ? min(before!.confidence, after!.confidence) : nil,
                    note: qualified
                        ? "Qualified installed-room on/off-axis spectrum suggests a change in similarity to the on-axis reference; perform fresh listening-position measurement before assessing benefit."
                        : "No repeat-qualified, signed off-axis evidence brackets both angles at usable 1–8 kHz frequencies; do not rank."
                )
            }
        // Unsupported trials retain their identity and explanatory blocker,
        // and cannot rise to the top on a guessed numerical score.
        return results.sorted {
            if $0.status != $1.status {
                return $0.status == .measuredComparison
            }
            if let lhs = $0.indicatedSpectralChangeDB,
               let rhs = $1.indicatedSpectralChangeDB,
               lhs != rhs {
                return lhs > rhs
            }
            return $0.experimentID < $1.experimentID
        }
    }

    private func offset(
        from speaker: RoomGeometryPoint3D,
        to listener: RoomGeometryPoint3D,
        toeIn: Double
    ) -> Double {
        atan2(listener.x - speaker.x, listener.y - speaker.y)
            * 180 / .pi - toeIn
    }

    private func spectralDeviation(
        _ report: SpeakerMeasurementLabDirectivityReport,
        angle: Double
    ) -> (value: Double, confidence: Double)? {
        guard angle.isFinite,
              report.commonUsableLowHz <= Self.minimumFrequencyHz,
              report.commonUsableHighHz >= Self.maximumFrequencyHz else {
            return nil
        }
        let traces = report.traces.filter {
            abs($0.verticalAngleDegrees) < 0.5
                && $0.evidenceConfidence >= Self.minimumQualifiedConfidence
                && $0.frequenciesHz.count == $0.relativeMagnitudeDB.count
                && $0.frequenciesHz.count >= 12
                && $0.relativeMagnitudeDB.allSatisfy(\.isFinite)
        }.sorted { $0.horizontalAngleDegrees < $1.horizontalAngleDegrees }
        guard let exemplar = traces.first else { return nil }
        let indices = exemplar.frequenciesHz.indices.filter {
            (Self.minimumFrequencyHz...Self.maximumFrequencyHz)
                .contains(exemplar.frequenciesHz[$0])
        }
        guard indices.count >= 8,
              traces.allSatisfy({ $0.frequenciesHz == exemplar.frequenciesHz }),
              exemplar.frequenciesHz.allSatisfy(\.isFinite) else {
            return nil
        }
        // On-axis reference is exactly zero dB *relative to itself*.
        // This does not imply the speaker is flat or meets any target.
        if abs(angle) <= 0.0001 { return (0, 1) }
        // A negative-side sample must not be used to extrapolate a positive
        // orientation (or vice versa); 0° is the explicit reference anchor.
        let lower: (Double, [Double], Double)
        let upper: (Double, [Double], Double)
        let onAxis = Array(repeating: 0.0, count: exemplar.frequenciesHz.count)
        if angle > 0 {
            let sameSideLower = traces.last {
                $0.horizontalAngleDegrees > 0
                    && $0.horizontalAngleDegrees <= angle
            }
            let sameSideUpper = traces.first {
                $0.horizontalAngleDegrees > 0
                    && $0.horizontalAngleDegrees >= angle
            }
            guard let sameSideUpper else { return nil }
            lower = (sameSideLower?.horizontalAngleDegrees ?? 0,
                     sameSideLower?.relativeMagnitudeDB ?? onAxis,
                     sameSideLower?.evidenceConfidence ?? 1)
            upper = (sameSideUpper.horizontalAngleDegrees,
                     sameSideUpper.relativeMagnitudeDB,
                     sameSideUpper.evidenceConfidence)
        } else {
            let sameSideLower = traces.last {
                $0.horizontalAngleDegrees < 0
                    && $0.horizontalAngleDegrees <= angle
            }
            let sameSideUpper = traces.first {
                $0.horizontalAngleDegrees < 0
                    && $0.horizontalAngleDegrees >= angle
            }
            guard let sameSideLower else { return nil }
            upper = (sameSideUpper?.horizontalAngleDegrees ?? 0,
                     sameSideUpper?.relativeMagnitudeDB ?? onAxis,
                     sameSideUpper?.evidenceConfidence ?? 1)
            lower = (sameSideLower.horizontalAngleDegrees,
                     sameSideLower.relativeMagnitudeDB,
                     sameSideLower.evidenceConfidence)
        }
        let gap = upper.0 - lower.0
        guard lower.0 <= angle, angle <= upper.0,
              gap >= 0, gap <= Self.maximumMeasuredAngularGapDegrees else {
            return nil
        }
        let ratio = gap > 0 ? (angle - lower.0) / gap : 0
        let meanAbs = indices.reduce(0.0) { sum, i in
            let value = lower.1[i] + ratio * (upper.1[i] - lower.1[i])
            return sum + abs(value)
        } / Double(indices.count)
        return meanAbs.isFinite
            ? (meanAbs, min(lower.2, upper.2)) : nil
    }
}


// MARK: - PR110 Slice 4: measured physical Sub A/B at multiple seats

/// Separate physical position trials from PR108 coherent *digital* Sub
/// timing/phase commissioning. No room model may synthesize new LF evidence.
/// This is an offline, signed human-setup attestation plus two independently
/// repeat-qualified PR103 capture sets. It never alters DSP or output routing.
struct RoomAdvancedSubPlacementComparison: Equatable, Sendable {
    var experimentID: String
    var source: MultichannelCalibrationSource
    var baselineMeasurementSetID: UUID
    var candidateMeasurementSetID: UUID
    var seatCount: Int
    var commonFrequencyPointCount: Int
    var commonLowHz: Double
    var commonHighHz: Double
    var baselineInterseatSpreadRMSDB: Double
    var candidateInterseatSpreadRMSDB: Double
    /// Positive means *lower* inter-seat variation in measured relative LF
    /// magnitude. Not a sound-pressure or target-response improvement.
    var reductionInInterseatSpreadDB: Double
    var evidenceConfidence: Double
    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var requiresRealWorldListeningVerification: Bool { true }
}

enum RoomAdvancedSubPlacementComparisonError:
    Error, Equatable, LocalizedError {
    case missingPhysicalAttestation
    case invalidExperiment
    case mismatchedIdentity
    case inadequateEvidence
    case incompatibleFrequencyResponse

    var errorDescription: String? {
        switch self {
        case .missingPhysicalAttestation:
            return "Confirm identical microphone seats and an unchanged DSP/crossover/gain/phase chain across both physical placement captures."
        case .invalidExperiment:
            return "The proposed physical Sub move must exactly match the saved placement experiment."
        case .mismatchedIdentity:
            return "The baseline and candidate need the same Playback System, source, microphone, route, sample rate, and seat IDs."
        case .inadequateEvidence:
            return "Both positions need separate, fresh, repeat-qualified sweeps at every seat."
        case .incompatibleFrequencyResponse:
            return "Multi-seat LF comparisons need identical qualified response grids across both positions."
        }
    }
}

struct RoomAdvancedSubPlacementComparisonAnalyzer: Sendable {
    static let minimumFrequencyHz = 35.0
    static let maximumFrequencyHz = 160.0
    static let minimumFrequencyPoints = 12
    static let minimumSeats = 2
    static let maximumSeats = 8

    func compare(
        baseline: SpeakerOptimizerMeasurementSet,
        candidate: SpeakerOptimizerMeasurementSet,
        state: RoomAdvancedPlacementState,
        experiment: RoomAdvancedPlacementExperiment,
        playbackSystemID: UUID,
        physicalSetupConfirmed: Bool
    ) throws -> RoomAdvancedSubPlacementComparison {
        guard physicalSetupConfirmed else {
            throw RoomAdvancedSubPlacementComparisonError
                .missingPhysicalAttestation
        }
        let checked = try? state.validated()
        let genuine = try? RoomAdvancedPlacementExplorer()
            .experiments(for: state)
            .first { $0.id == experiment.id }
        guard let checked, let genuine,
              experiment == genuine,
              experiment.move == .subwoofer,
              checked.subwooferPositions != experiment.trial.subwooferPositions
        else {
            throw RoomAdvancedSubPlacementComparisonError.invalidExperiment
        }

        let seats = [checked.room.listener] + checked.secondarySeats
        guard (Self.minimumSeats...Self.maximumSeats).contains(seats.count),
              baseline.positions.count == seats.count,
              candidate.positions.count == seats.count,
              baseline.positions.map(\.id) == candidate.positions.map(\.id),
              baseline.positions.map(\.name) == candidate.positions.map(\.name),
              baseline.id != candidate.id,
              baseline.role == .baseline, candidate.role == .candidate,
              baseline.playbackSystemID == playbackSystemID,
              candidate.playbackSystemID == playbackSystemID,
              baseline.routingSignature == candidate.routingSignature,
              baseline.microphone == candidate.microphone,
              baseline.sampleRate == candidate.sampleRate,
              baseline.plannedSources == candidate.plannedSources,
              baseline.plannedSources.count == 1,
              baseline.captures.allSatisfy({ $0.source == baseline.plannedSources[0] }),
              candidate.captures.allSatisfy({ $0.source == candidate.plannedSources[0] })
        else {
            throw RoomAdvancedSubPlacementComparisonError.mismatchedIdentity
        }
        let source = baseline.plannedSources[0]
        guard case .subwoofer(let physicalIndex) = source,
              Int(physicalIndex) < checked.subwooferPositions.count,
              experiment.id.hasPrefix("sub-\(physicalIndex)-") else {
            throw RoomAdvancedSubPlacementComparisonError.invalidExperiment
        }

        let validator = SpeakerOptimizerMeasurementEvidenceEvaluator()
        guard let baselineReport = try? validator.evaluate(baseline),
              let candidateReport = try? validator.evaluate(candidate),
              baselineReport.optimizerReady, candidateReport.optimizerReady,
              baselineReport.groupReports.count == seats.count,
              candidateReport.groupReports.count == seats.count,
              baselineReport.groupReports.allSatisfy(\.optimizerReady),
              candidateReport.groupReports.allSatisfy(\.optimizerReady),
              let newestBaseline = baseline.captures.map(\.capturedAt).max(),
              let oldestCandidate = candidate.captures.map(\.capturedAt).min(),
              newestBaseline < oldestCandidate,
              Set(baseline.captures.map(\.id))
                .isDisjoint(with: Set(candidate.captures.map(\.id)))
        else {
            throw RoomAdvancedSubPlacementComparisonError.inadequateEvidence
        }

        let allGroups = baselineReport.groupReports
            + candidateReport.groupReports
        let low = max(Self.minimumFrequencyHz,
                      allGroups.compactMap(\.commonUsableLowHz).max() ?? .infinity)
        let high = min(Self.maximumFrequencyHz,
                       allGroups.compactMap(\.commonUsableHighHz).min() ?? 0)
        guard low <= high, low.isFinite, high.isFinite else {
            throw RoomAdvancedSubPlacementComparisonError
                .incompatibleFrequencyResponse
        }

        let allCaptures = baseline.captures + candidate.captures
        guard let grid = allCaptures.first?.response.frequenciesHz,
              !grid.isEmpty,
              zip(grid, grid.dropFirst()).allSatisfy({ $0 < $1 }),
              grid.allSatisfy({ $0.isFinite && $0 > 0 }),
              allCaptures.allSatisfy({
                  $0.response.frequenciesHz == grid
                    && $0.response.magnitudeDB.count == grid.count
                    && $0.response.magnitudeDB.allSatisfy(\.isFinite)
              }) else {
            throw RoomAdvancedSubPlacementComparisonError
                .incompatibleFrequencyResponse
        }
        let selected = grid.indices.filter {
            grid[$0] >= low && grid[$0] <= high
        }
        guard selected.count >= Self.minimumFrequencyPoints else {
            throw RoomAdvancedSubPlacementComparisonError
                .incompatibleFrequencyResponse
        }

        func interseatRMS(_ set: SpeakerOptimizerMeasurementSet) -> Double? {
            let ordered = set.positions.map { position in
                set.captures.filter { $0.positionID == position.id }
            }
            guard ordered.allSatisfy({ !$0.isEmpty }) else { return nil }
            // Per-frequency variance across seats; cancels common gain
            // shifts, so it never pretends to measure absolute LF level.
            let spreads: [Double] = selected.map { frequencyIndex in
                let seatMeans = ordered.map { captures in
                    captures.map { $0.response.magnitudeDB[frequencyIndex] }
                        .reduce(0, +) / Double(captures.count)
                }
                let center = seatMeans.reduce(0, +) / Double(seatMeans.count)
                return seatMeans.reduce(0.0) {
                    $0 + pow($1 - center, 2)
                } / Double(seatMeans.count)
            }
            let value = sqrt(spreads.reduce(0, +) / Double(spreads.count))
            return value.isFinite ? value : nil
        }
        guard let prior = interseatRMS(baseline),
              let after = interseatRMS(candidate) else {
            throw RoomAdvancedSubPlacementComparisonError
                .incompatibleFrequencyResponse
        }
        return RoomAdvancedSubPlacementComparison(
            experimentID: experiment.id,
            source: source,
            baselineMeasurementSetID: baseline.id,
            candidateMeasurementSetID: candidate.id,
            seatCount: seats.count,
            commonFrequencyPointCount: selected.count,
            commonLowHz: low,
            commonHighHz: high,
            baselineInterseatSpreadRMSDB: prior,
            candidateInterseatSpreadRMSDB: after,
            reductionInInterseatSpreadDB: prior - after,
            evidenceConfidence: min(
                baselineReport.confidence, candidateReport.confidence
            )
        )
    }
}
