import Foundation
import XCTest
@testable import NotchSixty

final class RoomGeometryPlacementTests: XCTestCase {
    private let analyzer = RoomGeometryPlacementAnalyzer()

    func testRectangularRoomAxialModesMatchClosedFormFrequencies() throws {
        let model = roomModel()
        let modes = analyzer.roomModes(
            try model.validated()
        )

        let widthMode = try XCTUnwrap(
            modes.first {
                $0.nx == 1
                    && $0.ny == 0
                    && $0.nz == 0
            }
        )
        let lengthMode = try XCTUnwrap(
            modes.first {
                $0.nx == 0
                    && $0.ny == 1
                    && $0.nz == 0
            }
        )
        let heightMode = try XCTUnwrap(
            modes.first {
                $0.nx == 0
                    && $0.ny == 0
                    && $0.nz == 1
            }
        )

        XCTAssertEqual(
            widthMode.frequencyHz,
            343 / (2 * 4.0),
            accuracy: 0.001
        )
        XCTAssertEqual(
            lengthMode.frequencyHz,
            343 / (2 * 5.0),
            accuracy: 0.001
        )
        XCTAssertEqual(
            heightMode.frequencyHz,
            343 / (2 * 2.5),
            accuracy: 0.001
        )
        XCTAssertEqual(widthMode.type, .axial)
        XCTAssertEqual(lengthMode.type, .axial)
        XCTAssertEqual(heightMode.type, .axial)
    }

    func testImageSourceFrontWallReflectionLandsOnFrontSurface() throws {
        let model = try roomModel().validated()
        let reflections =
            analyzer.firstReflections(model)

        let reflection = try XCTUnwrap(
            reflections.first {
                $0.speaker == .left
                    && $0.surface == .frontWall
            }
        )

        XCTAssertEqual(
            reflection.reflectionPoint.y,
            0,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            reflection.reflectedPathMeters,
            reflection.directPathMeters
        )
        XCTAssertGreaterThan(
            reflection.delayMilliseconds,
            0
        )
        XCTAssertGreaterThan(
            reflection.excessPathMeters,
            0
        )
    }

    func testBoundaryPredictionUsesFirstDestructivePathDifference() throws {
        let model = try roomModel().validated()
        let reflections =
            analyzer.firstReflections(model)
        let boundary =
            analyzer.boundaryPredictions(
                reflections: reflections
            )

        let item = try XCTUnwrap(
            boundary.first
        )
        XCTAssertEqual(
            item.firstCancellationHz,
            343
                / (
                    2
                    * item.excessPathMeters
                ),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThanOrEqual(
            item.firstCancellationHz,
            20
        )
        XCTAssertLessThanOrEqual(
            item.firstCancellationHz,
            500
        )
    }

    func testMeasuredRingingSupportsNearbyPredictedMode() throws {
        var model = roomModel()
        model.dimensions.length = 4.0
        model.listener.y = 3.3

        let report = report(
            findings: [
                finding(
                    id: "ringing",
                    kind: .lowFrequencyRinging,
                    frequencyHz: 42.9,
                    delayMilliseconds: nil
                ),
            ]
        )

        let analysis = try analyzer.analyze(
            model: model,
            advisorReport: report
        )

        let evidence = try XCTUnwrap(
            analysis.evidence.first {
                $0.kind == .roomMode
            }
        )
        XCTAssertEqual(
            evidence.status,
            .supported
        )
        XCTAssertTrue(
            evidence.rationale.contains(
                "close to"
            )
        )
    }

    func testMeasuredRingingConflictsWithDistantRectangularMode() throws {
        var model = roomModel()
        model.dimensions.length = 4.0
        model.listener.y = 3.3

        let report = report(
            findings: [
                finding(
                    id: "ringing",
                    kind: .lowFrequencyRinging,
                    frequencyHz: 49,
                    delayMilliseconds: nil
                ),
            ]
        )

        let analysis = try analyzer.analyze(
            model: model,
            advisorReport: report
        )

        let evidence = try XCTUnwrap(
            analysis.evidence.first {
                $0.kind == .roomMode
            }
        )
        XCTAssertEqual(
            evidence.status,
            .conflicted
        )
    }

    func testMeasuredReflectionCanSupportModeledSurfacePath() throws {
        let model = try roomModel().validated()
        let reflections =
            analyzer.firstReflections(model)
        let predicted = try XCTUnwrap(
            reflections.first
        )

        let report = report(
            findings: [
                finding(
                    id: "reflection",
                    kind: .earlyReflection,
                    frequencyHz: nil,
                    delayMilliseconds:
                        predicted.delayMilliseconds
                ),
            ]
        )

        let analysis = try analyzer.analyze(
            model: model,
            advisorReport: report
        )
        let evidence = try XCTUnwrap(
            analysis.evidence.first {
                $0.kind == .firstReflection
            }
        )

        XCTAssertEqual(
            evidence.status,
            .supported
        )
        XCTAssertTrue(
            evidence.prediction.contains(
                "predicts"
            )
        )
    }

    func testBoundaryNullCanSupportModeledSBIRCandidate() throws {
        let model = try roomModel().validated()
        let boundary =
            analyzer.boundaryPredictions(
                reflections:
                    analyzer.firstReflections(model)
            )
        let predicted = try XCTUnwrap(
            boundary.first
        )

        let report = report(
            findings: [
                finding(
                    id: "sbir",
                    kind:
                        .boundaryInterferenceCandidate,
                    frequencyHz:
                        predicted.firstCancellationHz,
                    delayMilliseconds: nil
                ),
            ]
        )

        let analysis = try analyzer.analyze(
            model: model,
            advisorReport: report
        )
        let evidence = try XCTUnwrap(
            analysis.evidence.first {
                $0.kind
                    == .boundaryInterference
            }
        )

        XCTAssertEqual(
            evidence.status,
            .supported
        )
    }

    func testPlacementSearchFindsLowerRiskListenerMoveForLengthMode() throws {
        var model = roomModel()
        model.listener = RoomGeometryPoint3D(
            x: 2.0,
            y: 4.55,
            z: 1.1
        )

        let firstLengthMode =
            343 / (2 * model.dimensions.length)
        let report = report(
            findings: [
                finding(
                    id: "length-mode",
                    kind: .lowFrequencyRinging,
                    frequencyHz:
                        firstLengthMode,
                    delayMilliseconds: nil
                ),
            ]
        )

        let analysis = try analyzer.analyze(
            model: model,
            advisorReport: report
        )

        XCTAssertFalse(
            analysis.placementCandidates.isEmpty
        )
        XCTAssertTrue(
            analysis.placementCandidates.allSatisfy {
                $0.expectedImprovementPercent > 0
                    && $0.score < $0.currentScore
            }
        )
        XCTAssertTrue(
            analysis.placementCandidates.contains {
                $0.kind == .listener
            }
        )
    }

    func testGeometryValidationRejectsPointOutsideRoom() {
        var model = roomModel()
        model.listener.x =
            model.dimensions.width + 0.1

        XCTAssertThrowsError(
            try model.validated()
        ) { error in
            XCTAssertEqual(
                error as? RoomGeometryError,
                .pointOutsideRoom("listener")
            )
        }
    }

    func testGeometryStoreIsSeparateFromRoomCorrectionProjectState() throws {
        let root =
            FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "PR93-Geometry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        let projectStore =
            RoomCorrectionProjectStore(
                rootDirectory: root
            )
        let project = RoomCorrectionProject(
            id: UUID(),
            playbackSystemID: UUID(),
            name: "Geometry Test"
        )
        try projectStore.save(project)

        let geometryStore =
            RoomGeometryStore(
                projectStore: projectStore
            )
        let geometry =
            RoomGeometryModel.template(
                projectID: project.id
            )
        try geometryStore.save(geometry)

        let reloadedProject =
            try projectStore.load(project.id)
        let reloadedGeometry =
            try XCTUnwrap(
                geometryStore.load(
                    projectID: project.id
                )
            )

        XCTAssertEqual(
            reloadedProject,
            project
        )
        XCTAssertEqual(
            reloadedGeometry.projectID,
            project.id
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    geometryStore
                    .geometryURL(for: project.id)
                    .path
            )
        )
    }

    @MainActor
    func testAdvisorGeometrySelectionDoesNotRequireProfileController() throws {
        let root =
            FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "PR93-Controller-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        let store =
            RoomCorrectionProjectStore(
                rootDirectory: root
            )
        let project = RoomCorrectionProject(
            id: UUID(),
            playbackSystemID: UUID(),
            name: "Independent Geometry"
        )
        try store.save(project)

        let controller =
            RoomTreatmentAdvisorController(
                store: store
            )
        controller.prepareForUse()
        controller.startGeometryTemplate()

        XCTAssertEqual(
            controller.geometryDraft?.projectID,
            project.id
        )
        controller.saveGeometry()
        XCTAssertNotNil(
            controller.savedGeometry
        )
        XCTAssertNotNil(
            controller.geometryAnalysis
        )
    }

    @MainActor
    func testPlacementPreviewChangesDraftWithoutMutatingSavedGeometry() throws {
        let root =
            FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "PR93-Preview-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }

        let store =
            RoomCorrectionProjectStore(
                rootDirectory: root
            )
        let project = RoomCorrectionProject(
            id: UUID(),
            playbackSystemID: UUID(),
            name: "Preview Geometry"
        )
        try store.save(project)

        let controller =
            RoomTreatmentAdvisorController(
                store: store
            )
        controller.prepareForUse()
        controller.startGeometryTemplate()
        controller.saveGeometry()

        let baseline = try XCTUnwrap(
            controller.savedGeometry
        )
        var movedListener = baseline.listener
        movedListener.y -= 0.3

        let candidate = RoomPlacementCandidate(
            id: "preview-test",
            kind: .listener,
            title: "Move listener forward",
            detail: "Test move",
            listener: movedListener,
            leftSpeaker: baseline.leftSpeaker,
            rightSpeaker: baseline.rightSpeaker,
            score: 1,
            currentScore: 2,
            expectedImprovementPercent: 50,
            rationale: "Test"
        )

        controller.previewPlacementCandidate(
            candidate
        )

        XCTAssertEqual(
            controller.savedGeometry,
            baseline
        )
        XCTAssertEqual(
            controller.geometryDraft?.listener,
            movedListener
        )
        XCTAssertTrue(
            controller.geometryHasUnsavedChanges
        )
    }

    private func roomModel() -> RoomGeometryModel {
        RoomGeometryModel(
            projectID: UUID(),
            dimensions:
                RoomGeometryDimensions(
                    width: 4.0,
                    length: 5.0,
                    height: 2.5
                ),
            listener:
                RoomGeometryPoint3D(
                    x: 2.0,
                    y: 3.5,
                    z: 1.1
                ),
            leftSpeaker:
                RoomGeometryPoint3D(
                    x: 1.15,
                    y: 0.65,
                    z: 0.9
                ),
            rightSpeaker:
                RoomGeometryPoint3D(
                    x: 2.85,
                    y: 0.65,
                    z: 0.9
                )
        )
    }

    private func finding(
        id: String,
        kind: RoomTreatmentAdvisorFindingKind,
        frequencyHz: Double?,
        delayMilliseconds: Double?
    ) -> RoomTreatmentAdvisorFinding {
        RoomTreatmentAdvisorFinding(
            id: id,
            kind: kind,
            severity: .important,
            title: id,
            measuredEvidence: "Measured",
            interpretation: "Interpretation",
            recommendation: "Recommendation",
            primaryRemedy: .placement,
            confidence: 0.9,
            frequencyHz: frequencyHz,
            delayMilliseconds:
                delayMilliseconds
        )
    }

    private func report(
        findings: [RoomTreatmentAdvisorFinding]
    ) -> RoomTreatmentAdvisorReport {
        RoomTreatmentAdvisorReport(
            projectID: UUID(),
            projectName: "Geometry",
            retainedMeasurementCount: 1,
            includedMeasurementCount: 1,
            analysisMode: .singlePosition,
            microphoneName: nil,
            calibratedMicrophone: false,
            qualityWarnings: [],
            findings: findings,
            actionPriorities: []
        )
    }
}
