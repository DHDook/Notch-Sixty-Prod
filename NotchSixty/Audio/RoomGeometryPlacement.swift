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
