import Foundation

enum RoomPassiveTreatmentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case broadbandAbsorber
    case bassTrap
    case diffusionCandidate

    var id: String { rawValue }
    var label: String {
        switch self {
        case .broadbandAbsorber: return "Broadband absorber"
        case .bassTrap: return "Bass trap"
        case .diffusionCandidate: return "Diffusion candidate"
        }
    }
}

struct RoomPassiveTreatmentPlacement: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var kind: RoomPassiveTreatmentKind
    var surface: RoomGeometrySurface
    /// Center coordinates normalized along the two dimensions of the chosen surface.
    var u: Double
    var v: Double
    var widthMeters: Double
    var heightMeters: Double
    var thicknessMeters: Double
    var airGapMeters: Double

    var coverageAreaSquareMeters: Double { widthMeters * heightMeters }
    var totalDepthMeters: Double { thicknessMeters + airGapMeters }

    /// A wavelength-scale warning/context number, NOT a prediction of absorption onset.
    var quarterWavelengthContextHz: Double {
        343.0 / (4.0 * totalDepthMeters)
    }

    func validated(in room: RoomGeometryModel) throws -> Self {
        _ = try room.validated()
        let extent = Self.surfaceSize(surface, dimensions: room.dimensions)
        guard u.isFinite, v.isFinite, (0...1).contains(u), (0...1).contains(v),
              widthMeters.isFinite, heightMeters.isFinite,
              thicknessMeters.isFinite, airGapMeters.isFinite,
              widthMeters >= 0.15, heightMeters >= 0.15,
              thicknessMeters >= 0.02, thicknessMeters <= 0.65,
              airGapMeters >= 0, airGapMeters <= 0.60,
              (u * extent.0 - widthMeters / 2) >= -1.0e-6,
              (u * extent.0 + widthMeters / 2) <= extent.0 + 1.0e-6,
              (v * extent.1 - heightMeters / 2) >= -1.0e-6,
              (v * extent.1 + heightMeters / 2) <= extent.1 + 1.0e-6
        else { throw RoomPassiveTreatmentError.invalidPlacement }
        return self
    }

    static func surfaceSize(
        _ surface: RoomGeometrySurface,
        dimensions: RoomGeometryDimensions
    ) -> (Double, Double) {
        switch surface {
        case .frontWall, .rearWall:
            return (dimensions.width, dimensions.height)
        case .leftWall, .rightWall:
            return (dimensions.length, dimensions.height)
        case .floor, .ceiling:
            return (dimensions.width, dimensions.length)
        }
    }
}

struct RoomPassiveTreatmentPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var projectID: UUID
    var placements: [RoomPassiveTreatmentPlacement] = []
    var modifiedAt: Date = Date()

    func validated(in room: RoomGeometryModel) throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion, projectID == room.projectID
        else { throw RoomPassiveTreatmentError.projectMismatch }
        guard placements.count <= 24, Set(placements.map(\.id)).count == placements.count
        else { throw RoomPassiveTreatmentError.invalidPlacement }
        for placement in placements { _ = try placement.validated(in: room) }
        for index in placements.indices {
            for other in placements.indices where other > index {
                let a = placements[index]
                let b = placements[other]
                guard a.surface == b.surface else { continue }
                let extent = RoomPassiveTreatmentPlacement.surfaceSize(a.surface, dimensions: room.dimensions)
                let overlapU = abs(a.u - b.u) * extent.0 < (a.widthMeters + b.widthMeters) / 2 - 1.0e-5
                let overlapV = abs(a.v - b.v) * extent.1 < (a.heightMeters + b.heightMeters) / 2 - 1.0e-5
                if overlapU && overlapV { throw RoomPassiveTreatmentError.overlappingPlacements }
            }
        }
        return self
    }
}

enum RoomPassiveTreatmentError: Error, LocalizedError {
    case projectMismatch
    case invalidPlacement
    case overlappingPlacements
    case geometryRequired
    case corruptPlan

    var errorDescription: String? {
        switch self {
        case .projectMismatch: return "The treatment plan belongs to a different room project or uses an unsupported schema."
        case .invalidPlacement: return "Treatment dimensions or surface coordinates are outside the modeled room."
        case .overlappingPlacements: return "Two treatments overlap on the same room surface."
        case .geometryRequired: return "Save valid room geometry before saving a treatment plan."
        case .corruptPlan: return "The saved treatment plan cannot be read."
        }
    }
}

struct RoomPassiveTreatmentSuggestion: Identifiable, Equatable, Sendable {
    var id: String
    var placement: RoomPassiveTreatmentPlacement
    var title: String
    var evidence: String
    var rationale: String
    var priority: Int
    var confidence: Double
}

struct RoomPassiveTreatmentDesignSummary: Equatable, Sendable {
    var suggestions: [RoomPassiveTreatmentSuggestion]
    var warnings: [String]
    var treatmentAreaSquareMeters: Double
}

struct RoomPassiveTreatmentDesigner: Sendable {
    func evaluate(
        plan: RoomPassiveTreatmentPlan,
        geometry: RoomGeometryModel,
        report: RoomTreatmentAdvisorReport,
        predictions: RoomGeometryAnalysis
    ) throws -> RoomPassiveTreatmentDesignSummary {
        let valid = try plan.validated(in: geometry)
        var warnings: [String] = []
        var suggestions: [RoomPassiveTreatmentSuggestion] = []
        let qualityOK = report.qualityWarnings.isEmpty
            && report.includedMeasurementCount > 0
        if !qualityOK {
            warnings.append("Fix measurement-quality problems before relying on treatment recommendations.")
        }
        if report.analysisMode == .singlePosition {
            warnings.append("Only one microphone position: repeat nearby positions before expensive bass treatment decisions.")
        }
        if qualityOK {
            if let ringing = report.findings.first(where: { $0.kind == .lowFrequencyRinging }),
               let frequency = ringing.frequencyHz {
                let lowBand = frequency < 100
                if lowBand {
                    warnings.append(String(format:
                        "%.0f Hz ringing needs substantial low-frequency treatment. Ordinary thin panels may have little effect; no guaranteed RT60 reduction is predicted.",
                        frequency))
                }
                let size = RoomPassiveTreatmentPlacement.surfaceSize(
                    .frontWall, dimensions: geometry.dimensions)
                for (i, u) in [0.13, 0.87].enumerated() {
                    let item = RoomPassiveTreatmentPlacement(
                        kind: .bassTrap, surface: .frontWall, u: u, v: 0.5,
                        widthMeters: min(0.65, size.0 * 0.22),
                        heightMeters: min(size.1 * 0.75, 1.80),
                        thicknessMeters: 0.30, airGapMeters: 0.10
                    )
                    if (try? item.validated(in: geometry)) != nil {
                        suggestions.append(RoomPassiveTreatmentSuggestion(
                            id: "bass-trap-\(i)", placement: item,
                            title: i == 0 ? "Front-left bass-trap candidate" : "Front-right bass-trap candidate",
                            evidence: ringing.measuredEvidence,
                            rationale: "Prioritize thick LF treatment and placement tests for measured decay. A trap at this corner is a plausible starting location, not a computed reduction at the measured frequency.",
                            priority: 1, confidence: min(0.80, ringing.confidence)
                        ))
                    }
                }
            }

            if let early = report.findings.first(where: { $0.kind == .earlyReflection }),
               let measuredDelay = early.delayMilliseconds {
                // Multiple surfaces may match the same delay: all remain hypotheses.
                let matched = predictions.reflections.filter {
                    abs($0.delayMilliseconds - measuredDelay) <= 1.2
                        && $0.surface != .floor && $0.surface != .ceiling
                }
                for reflection in matched.prefix(4) {
                    let normalized = surfaceCoordinates(
                        reflection.reflectionPoint, surface: reflection.surface,
                        dimensions: geometry.dimensions)
                    let bounds = RoomPassiveTreatmentPlacement.surfaceSize(
                        reflection.surface, dimensions: geometry.dimensions)
                    let item = RoomPassiveTreatmentPlacement(
                        kind: .broadbandAbsorber,
                        surface: reflection.surface, u: normalized.0, v: normalized.1,
                        widthMeters: min(0.80, 2 * min(normalized.0, 1 - normalized.0) * bounds.0),
                        heightMeters: min(1.10, 2 * min(normalized.1, 1 - normalized.1) * bounds.1),
                        thicknessMeters: 0.10, airGapMeters: 0.10
                    )
                    if (try? item.validated(in: geometry)) != nil {
                        suggestions.append(RoomPassiveTreatmentSuggestion(
                            id: "reflection-\(reflection.id)", placement: item,
                            title: "\(reflection.surface.displayName) first-reflection candidate",
                            evidence: early.measuredEvidence,
                            rationale: String(format:
                                "Modeled %@ path delay %.1f ms matches the measured reflection, but timing alone cannot uniquely identify a wall. Verify with a movable absorber or repeated measurement.",
                                reflection.speaker.displayName, reflection.delayMilliseconds),
                            priority: 2, confidence: min(0.75, early.confidence)
                        ))
                    }
                }
            }
        }
        if report.findings.contains(where: { $0.kind == .deepBassCancellation || $0.kind == .boundaryInterferenceCandidate }) {
            warnings.append("Deep nulls/SBIR candidates generally warrant speaker or seat movement first—not thin absorption or large EQ boosts.")
        }
        if !report.findings.contains(where: {
            $0.kind == .lowFrequencyRinging || $0.kind == .earlyReflection
        }) {
            warnings.append("No measured decay/reflection finding justifies blanket absorption. Preserve untreated surfaces unless further measurements identify a need.")
        }
        if valid.placements.contains(where: { $0.kind == .diffusionCandidate }) {
            warnings.append("Diffusion is an optional candidate, not an automatic prescription; check listening distance, coverage and measured reflection needs.")
        }
        for item in valid.placements where item.kind == .bassTrap && item.totalDepthMeters < 0.20 {
            warnings.append("A bass-trap label with less than 20 cm total depth has limited credible very-low-frequency effectiveness without material test data.")
        }
        suggestions.sort { $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority }
        return RoomPassiveTreatmentDesignSummary(
            suggestions: suggestions, warnings: warnings,
            treatmentAreaSquareMeters: valid.placements.reduce(0) { $0 + $1.coverageAreaSquareMeters }
        )
    }

    private func surfaceCoordinates(
        _ point: RoomGeometryPoint3D,
        surface: RoomGeometrySurface,
        dimensions: RoomGeometryDimensions
    ) -> (Double, Double) {
        switch surface {
        case .frontWall, .rearWall: return (point.x / dimensions.width, point.z / dimensions.height)
        case .leftWall, .rightWall: return (point.y / dimensions.length, point.z / dimensions.height)
        case .floor, .ceiling: return (point.x / dimensions.width, point.y / dimensions.length)
        }
    }
}

struct RoomPassiveTreatmentStore: Sendable {
    let projectStore: RoomCorrectionProjectStore

    func url(for projectID: UUID) -> URL {
        projectStore.projectDirectory(for: projectID)
            .appendingPathComponent("advisor-treatment-v1.json")
    }

    func load(projectID: UUID, geometry: RoomGeometryModel) throws -> RoomPassiveTreatmentPlan? {
        let file = url(for: projectID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let plan = try JSONDecoder().decode(
                RoomPassiveTreatmentPlan.self, from: Data(contentsOf: file))
            return try plan.validated(in: geometry)
        } catch let error as RoomPassiveTreatmentError {
            throw error
        } catch {
            throw RoomPassiveTreatmentError.corruptPlan
        }
    }

    func save(_ plan: RoomPassiveTreatmentPlan, geometry: RoomGeometryModel) throws {
        let valid = try plan.validated(in: geometry)
        let directory = projectStore.projectDirectory(for: valid.projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(valid).write(to: url(for: valid.projectID), options: .atomic)
    }

    func delete(projectID: UUID) throws {
        let file = url(for: projectID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
