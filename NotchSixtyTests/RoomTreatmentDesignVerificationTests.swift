import Foundation
import XCTest
@testable import NotchSixty

final class RoomTreatmentDesignVerificationTests: XCTestCase {
    private let designer = RoomPassiveTreatmentDesigner()
    private let verifier = RoomTreatmentVerifier()

    func testTreatmentPlanRejectsOutOfBoundsAndOverlap() throws {
        let geometry = room()
        var a = placement(u: 0.50)
        a.widthMeters = 0.80
        var b = placement(u: 0.55)
        b.widthMeters = 0.80
        var plan = RoomPassiveTreatmentPlan(projectID: geometry.projectID)
        plan.placements = [a, b]
        XCTAssertThrowsError(try plan.validated(in: geometry))
        plan.placements = [a]
        XCTAssertNoThrow(try plan.validated(in: geometry))
        a.u = 0.99
        plan.placements = [a]
        XCTAssertThrowsError(try plan.validated(in: geometry))
    }

    func testMeasuredRingingSuggestsSubstantialBassTreatmentNotThinPanel() throws {
        let geometry = room()
        let finding = RoomTreatmentAdvisorFinding(
            id: "lf", kind: .lowFrequencyRinging,
            severity: .important, title: "Ringing",
            measuredEvidence: "80 Hz prolonged decay",
            interpretation: "Ringing", recommendation: "Bass trapping",
            primaryRemedy: .passiveTreatment,
            confidence: 0.91, frequencyHz: 80, decaySeconds: 0.9
        )
        let report = advisorReport(projectID: geometry.projectID, findings: [finding])
        let predictions = try RoomGeometryPlacementAnalyzer().analyze(
            model: geometry, advisorReport: report
        )
        let plan = RoomPassiveTreatmentPlan(projectID: geometry.projectID)
        let result = try designer.evaluate(
            plan: plan, geometry: geometry, report: report, predictions: predictions
        )
        XCTAssertTrue(result.suggestions.contains { $0.placement.kind == .bassTrap })
        XCTAssertTrue(result.warnings.contains { $0.contains("thin panels") })
        XCTAssertTrue(result.suggestions.allSatisfy { $0.confidence <= 0.80 })
    }

    func testNoEvidenceDoesNotRecommendBlanketAbsorption() throws {
        let geometry = room()
        let report = advisorReport(projectID: geometry.projectID, findings: [])
        let predictions = try RoomGeometryPlacementAnalyzer().analyze(
            model: geometry, advisorReport: report
        )
        let result = try designer.evaluate(
            plan: RoomPassiveTreatmentPlan(projectID: geometry.projectID),
            geometry: geometry, report: report, predictions: predictions
        )
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("Preserve untreated") })
    }

    func testTreatmentPlanIsSeparateFromPersistedRoomCorrectionProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR94-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = RoomCorrectionProjectStore(rootDirectory: root)
        let geometry = room()
        let project = RoomCorrectionProject(
            id: geometry.projectID, playbackSystemID: UUID(),
            name: "Room treatment"
        )
        try projects.save(project)
        let store = RoomPassiveTreatmentStore(projectStore: projects)
        let plan = RoomPassiveTreatmentPlan(
            projectID: project.id,
            placements: [placement(u: 0.5)]
        )
        try store.save(plan, geometry: geometry)
        XCTAssertEqual(try store.load(projectID: project.id, geometry: geometry), plan)
        XCTAssertEqual(try projects.load(project.id), project)
        XCTAssertTrue(store.url(for: project.id).lastPathComponent.contains("advisor-treatment"))
    }

    func testVerificationRejectsMismatchedMicOrSystem() {
        let system = UUID()
        let a = project(name: "Before", system: system, seats: [("Center", 0)])
        var b = project(name: "After", system: system, seats: [("Center", 0)])
        b.microphone?.displayName = "Other microphone"
        let result = verifier.compare(baseline: a, followUp: b)
        XCTAssertFalse(result.comparable)
        XCTAssertTrue(result.metrics.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("microphone") })
    }

    func testVerificationRejectsDuplicatePositionNamesRatherThanCrashing() {
        let system = UUID()
        let a = project(name: "Before", system: system, seats: [("Center", 0), ("Left", 4)])
        let b = project(name: "After", system: system, seats: [("Center", 0), ("Center", 4)])
        let result = verifier.compare(baseline: a, followUp: b)
        XCTAssertFalse(result.comparable)
        XCTAssertTrue(result.warnings.contains { $0.contains("uniquely named") })
    }

    func testVerificationMeasuresImprovedBassSeatConsistency() {
        let system = UUID()
        let a = project(name: "Before", system: system, seats: [("Center", 0), ("Left", 10)])
        let b = project(name: "After", system: system, seats: [("Center", 0), ("Left", 3)])
        let result = verifier.compare(baseline: a, followUp: b)
        XCTAssertTrue(result.comparable, result.warnings.joined(separator: " | "))
        let spread = result.metrics.first { $0.id == "seat-spread" }
        XCTAssertNotNil(spread)
        XCTAssertEqual(spread?.baseline ?? -1, 10, accuracy: 0.1)
        XCTAssertEqual(spread?.followUp ?? -1, 3, accuracy: 0.1)
        XCTAssertEqual(spread?.change, .improved)
    }

    func testVerificationFailsClosedOnClippedFollowUp() {
        let system = UUID()
        let a = project(name: "Before", system: system, seats: [("Center", 0)])
        var b = project(name: "After", system: system, seats: [("Center", 0)])
        b.measurements[0].right.quality.clipped = true
        let result = verifier.compare(baseline: a, followUp: b)
        XCTAssertFalse(result.comparable)
        XCTAssertTrue(result.metrics.isEmpty)
    }

    @MainActor
    func testTreatmentDraftDoesNotOverwritePlanUntilExplicitSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR94-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectStore = RoomCorrectionProjectStore(rootDirectory: root)
        let geometry = room()
        try projectStore.save(RoomCorrectionProject(
            id: geometry.projectID, playbackSystemID: UUID(), name: "Draft test"
        ))
        try RoomGeometryStore(projectStore: projectStore).save(geometry)
        let controller = RoomTreatmentAdvisorController(store: projectStore)
        controller.prepareForUse()
        controller.createTreatmentPlan()
        controller.saveTreatmentPlan()
        let saved = try XCTUnwrap(controller.savedTreatmentPlan)
        controller.addManualTreatment(kind: .broadbandAbsorber, surface: .frontWall)
        XCTAssertNotEqual(controller.treatmentDraft, saved)
        XCTAssertEqual(controller.savedTreatmentPlan, saved)
        XCTAssertEqual(
            try controller.treatmentStore.load(projectID: geometry.projectID, geometry: geometry),
            saved
        )
    }

    private func room() -> RoomGeometryModel {
        RoomGeometryModel(
            projectID: UUID(),
            dimensions: RoomGeometryDimensions(width: 4, length: 5, height: 2.5),
            listener: RoomGeometryPoint3D(x: 2, y: 3.5, z: 1.1),
            leftSpeaker: RoomGeometryPoint3D(x: 1.2, y: 0.75, z: 0.9),
            rightSpeaker: RoomGeometryPoint3D(x: 2.8, y: 0.75, z: 0.9)
        )
    }

    private func placement(u: Double) -> RoomPassiveTreatmentPlacement {
        RoomPassiveTreatmentPlacement(
            kind: .broadbandAbsorber, surface: .frontWall,
            u: u, v: 0.5, widthMeters: 0.5, heightMeters: 0.8,
            thicknessMeters: 0.10, airGapMeters: 0.1
        )
    }

    private func advisorReport(
        projectID: UUID, findings: [RoomTreatmentAdvisorFinding]
    ) -> RoomTreatmentAdvisorReport {
        RoomTreatmentAdvisorReport(
            projectID: projectID, projectName: "Room",
            retainedMeasurementCount: 1, includedMeasurementCount: 1,
            analysisMode: .singlePosition, microphoneName: "UMIK",
            calibratedMicrophone: false, qualityWarnings: [],
            findings: findings, actionPriorities: []
        )
    }

    private func project(
        name: String, system: UUID, seats: [(String, Double)]
    ) -> RoomCorrectionProject {
        var result = RoomCorrectionProject(
            playbackSystemID: system, name: name
        )
        result.microphone = RoomCorrectionMicrophone(
            stableID: "umik", displayName: "UMIK",
            manufacturer: nil, inputChannelIndex: 0,
            calibration: nil
        )
        result.sweep = RoomCorrectionSweepSettings(sampleRate: 48_000)
        let frequencies: [Double] = [40, 63, 80, 100, 125, 160, 200, 250, 500, 1_000, 2_000, 4_000]
        for (label, offset) in seats {
            let magnitude = frequencies.map { $0 <= 200 ? offset : 0.0 }
            let response = RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies, magnitudeDB: magnitude, phaseRadians: nil
            )
            let quality = RoomCorrectionMeasurementQuality(
                clipped: false, estimatedSNRDB: 48, sweepComplete: true,
                directArrivalSeconds: 0
            )
            let channel = RoomCorrectionChannelMeasurement(
                capturedAt: Date(), rawCapture: [0],
                impulseResponse: [1, 0, 0, 0],
                transferFunction: response, quality: quality
            )
            result.measurements.append(RoomCorrectionMeasurementPosition(
                name: label, sampleRate: 48_000, left: channel, right: channel
            ))
        }
        return result
    }
}
