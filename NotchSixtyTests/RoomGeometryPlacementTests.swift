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


// PR110 Slice 1: offline-only advanced placement candidate safety.
final class AdvancedRoomPlacementExperimentsTests: XCTestCase {
    private let explorer = RoomAdvancedPlacementExplorer()

    private func sample() -> RoomAdvancedPlacementState {
        let room = RoomGeometryModel.template(
            projectID: UUID(uuidString:
                "11000000-0000-0000-0000-000000000001")!
        )
        return RoomAdvancedPlacementState(
            room: room,
            secondarySeats: [
                RoomGeometryPoint3D(x: 1.4, y: 3.5, z: 1.1),
                RoomGeometryPoint3D(x: 2.6, y: 3.5, z: 1.1),
            ],
            leftToeInDegrees: 12,
            rightToeInDegrees: -12,
            subwooferPositions: [
                RoomGeometryPoint3D(x: 0.5, y: 0.5, z: 0.2),
            ]
        )
    }

    func testIndependentLeftMoveDoesNotChangeRightOrSub() throws {
        let before = sample()
        let candidates = try explorer.experiments(for: before)
        let moved = try XCTUnwrap(
            candidates.first { $0.id == "left-left" }
        )
        XCTAssertEqual(moved.move, .leftSpeaker)
        XCTAssertEqual(moved.trial.room.rightSpeaker, before.room.rightSpeaker)
        XCTAssertEqual(moved.trial.subwooferPositions, before.subwooferPositions)
        XCTAssertEqual(moved.trial.room.leftSpeaker.x,
                       before.room.leftSpeaker.x - 0.15, accuracy: 0.000001)
        XCTAssertEqual(moved.trial.room.projectID, before.room.projectID)
        XCTAssertTrue(moved.requiresMeasuredVerification)
        XCTAssertEqual(moved.evidenceLabel,
                       "Geometry hypothesis — measurement required")
    }

    func testSubMoveOnlyChangesSelectedSubPosition() throws {
        let before = sample()
        let trial = try XCTUnwrap(
            explorer.experiments(for: before).first {
                $0.id == "sub-0-right"
            }
        )
        XCTAssertEqual(trial.move, .subwoofer)
        XCTAssertEqual(trial.trial.room, before.room)
        XCTAssertEqual(trial.trial.subwooferPositions[0].x,
                       before.subwooferPositions[0].x + 0.30,
                       accuracy: 0.000001)
    }

    func testToeInChangesOrientationWithoutMovingSpeakers() throws {
        let before = sample()
        let trial = try XCTUnwrap(
            explorer.experiments(for: before).first {
                $0.id == "right-toe-clockwise"
            }
        )
        XCTAssertEqual(trial.trial.room, before.room)
        XCTAssertEqual(trial.trial.leftToeInDegrees, before.leftToeInDegrees)
        XCTAssertEqual(trial.trial.rightToeInDegrees,
                       before.rightToeInDegrees - 5, accuracy: 0.000001)
    }

    func testHeightChangesOnlySelectedSpeaker() throws {
        let before = sample()
        let trial = try XCTUnwrap(
            explorer.experiments(for: before).first {
                $0.id == "left-height-higher"
            }
        )
        XCTAssertEqual(trial.move, .leftHeight)
        XCTAssertEqual(trial.trial.room.leftSpeaker.z,
                       before.room.leftSpeaker.z + 0.1, accuracy: 0.000001)
        XCTAssertEqual(trial.trial.room.rightSpeaker, before.room.rightSpeaker)
    }

    func testInvalidOutOfRoomTrialsAreOmitted() throws {
        var nearWall = sample()
        nearWall.room.leftSpeaker.x = 0.05
        let trials = try explorer.experiments(for: nearWall)
        XCTAssertFalse(trials.contains { $0.id == "left-left" })
        XCTAssertTrue(trials.contains { $0.id == "left-right" })
        XCTAssertEqual(trials.count, Set(trials.map(\.id)).count)
        XCTAssertTrue(trials.allSatisfy {
            (try? $0.trial.validated()) != nil
        })
    }

    func testNoSubProducesNoInventedSubwooferTrials() throws {
        var state = sample()
        state.subwooferPositions = []
        XCTAssertFalse(
            try explorer.experiments(for: state).contains {
                $0.move == .subwoofer
            }
        )
    }

    func testInvalidGeometryAndAnglesFailClosed() throws {
        var state = sample()
        state.leftToeInDegrees = .infinity
        XCTAssertThrowsError(try explorer.experiments(for: state))
        state = sample()
        state.secondarySeats[0].x = -1
        XCTAssertThrowsError(try explorer.experiments(for: state))
        state = sample()
        state.subwooferPositions = Array(
            repeating: RoomGeometryPoint3D(x: 1, y: 1, z: 0.2),
            count: 5
        )
        XCTAssertThrowsError(try explorer.experiments(for: state))
    }

    func testCandidateEnumerationIsDeterministicAndDoesNotMutateState() throws {
        let before = sample()
        let unchanged = before
        let first = try explorer.experiments(for: before)
        let second = try explorer.experiments(for: before)
        XCTAssertEqual(first, second)
        XCTAssertEqual(before, unchanged)
        XCTAssertFalse(first.isEmpty)
        XCTAssertLessThanOrEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy {
            $0.maximumSeatPathImbalanceMeters.isFinite
                && $0.maximumSeatPathImbalanceMeters >= 0
        })
    }

    func testMultiSeatPathMetricIsGeometryOnlyAndNonNegative() {
        var state = sample()
        let original = explorer.maximumSeatPathImbalance(state)
        state.secondarySeats = []
        let primaryOnly = explorer.maximumSeatPathImbalance(state)
        XCTAssertGreaterThanOrEqual(original, primaryOnly)
        XCTAssertGreaterThanOrEqual(primaryOnly, 0)
    }
}


// PR110 Slice 2 — separate project-sidecar persistence and UI controller.
final class AdvancedPlacementSidecarTests: XCTestCase {
    private func makeFixture() throws -> (
        RoomCorrectionProjectStore, RoomCorrectionProject, URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PR110-Advanced-\(UUID().uuidString)", isDirectory: true
            )
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        let project = RoomCorrectionProject(
            id: UUID(), playbackSystemID: UUID(),
            name: "Advanced Placement"
        )
        try store.save(project)
        return (store, project, root)
    }

    func testProjectSidecarRoundTripDoesNotChangeLegacyGeometryOrProject() throws {
        let (store, project, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let geometryStore = RoomGeometryStore(projectStore: store)
        let advancedStore = RoomAdvancedPlacementStore(projectStore: store)
        let original = RoomGeometryModel.template(projectID: project.id)
        try geometryStore.save(original)
        let legacyJSON = try Data(contentsOf:
            geometryStore.geometryURL(for: project.id))
        var settings = RoomAdvancedPlacementSettings(projectID: project.id)
        settings.leftToeInDegrees = 14
        settings.rightToeInDegrees = -12
        settings.secondarySeats = [
            RoomGeometryPoint3D(x: 1.5, y: 3.4, z: 1.1)
        ]
        settings.subwooferPositions = [
            RoomGeometryPoint3D(x: 0.35, y: 0.55, z: 0.2)
        ]
        let advancedURL = try advancedStore.save(settings, room: original)
        XCTAssertTrue(advancedURL.lastPathComponent.contains("advanced-placement"))
        XCTAssertEqual(
            try advancedStore.load(projectID: project.id, room: original),
            settings
        )
        XCTAssertEqual(
            try Data(contentsOf: geometryStore.geometryURL(for: project.id)),
            legacyJSON
        )
        XCTAssertEqual(try store.load(project.id), project)
        XCTAssertEqual(
            try geometryStore.load(projectID: project.id), original
        )
    }

    func testMissingSidecarLeavesExistingRoomUntouched() throws {
        let (store, project, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let geometry = RoomGeometryModel.template(projectID: project.id)
        let advancedStore = RoomAdvancedPlacementStore(projectStore: store)
        XCTAssertNil(
            try advancedStore.load(projectID: project.id, room: geometry)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath:
                advancedStore.settingsURL(for: project.id).path)
        )
    }

    func testCorruptedSidecarCannotSilentlyResetOrDamageLegacyRoom() throws {
        let (store, project, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let geometryStore = RoomGeometryStore(projectStore: store)
        let advancedStore = RoomAdvancedPlacementStore(projectStore: store)
        let geometry = RoomGeometryModel.template(projectID: project.id)
        try geometryStore.save(geometry)
        try Data("{bad-json".utf8).write(
            to: advancedStore.settingsURL(for: project.id)
        )
        XCTAssertThrowsError(try advancedStore.load(
            projectID: project.id, room: geometry
        )) { error in
            XCTAssertEqual(
                error as? RoomAdvancedPlacementError, .corruptSettings
            )
        }
        XCTAssertEqual(
            try geometryStore.load(projectID: project.id), geometry
        )
    }

    func testCrossProjectAndUnsupportedVersionSettingsRejected() throws {
        let (store, project, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let geometry = RoomGeometryModel.template(projectID: project.id)
        let advancedStore = RoomAdvancedPlacementStore(projectStore: store)
        var wrong = RoomAdvancedPlacementSettings(projectID: UUID())
        XCTAssertThrowsError(try advancedStore.save(wrong, room: geometry))
        wrong.projectID = project.id
        wrong.schemaVersion = 5
        XCTAssertThrowsError(try advancedStore.save(wrong, room: geometry))
        XCTAssertThrowsError(try advancedStore.load(
            projectID: UUID(), room: geometry
        ))
    }

    @MainActor
    func testControllerDraftSaveReloadAndPureProposalPreview() throws {
        let (store, project, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RoomTreatmentAdvisorController(store: store)
        first.prepareForUse()
        first.startGeometryTemplate()
        first.saveGeometry()
        let baseline = try XCTUnwrap(first.savedGeometry)
        first.setAdvancedToeIn(.left, degrees: 16)
        first.addAdvancedSeat()
        first.addAdvancedSubwoofer()
        XCTAssertTrue(first.advancedPlacementHasUnsavedChanges)
        first.saveAdvancedPlacement()
        XCTAssertFalse(first.advancedPlacementHasUnsavedChanges)
        XCTAssertEqual(first.savedGeometry, baseline)

        let second = RoomTreatmentAdvisorController(store: store)
        second.prepareForUse()
        XCTAssertEqual(second.savedGeometry, baseline)
        XCTAssertEqual(second.advancedPlacementDraft?.leftToeInDegrees, 16)
        XCTAssertEqual(second.advancedPlacementDraft?.secondarySeats.count, 1)
        XCTAssertEqual(second.advancedPlacementDraft?.subwooferPositions.count, 1)
        let trial = try XCTUnwrap(second.advancedPlacementExperiments.first)
        second.previewAdvancedExperiment(trial)
        XCTAssertEqual(second.selectedAdvancedExperiment, trial)
        XCTAssertEqual(second.savedGeometry, baseline)
        XCTAssertEqual(second.geometryDraft, baseline)
        XCTAssertEqual(second.advancedPlacementDraft, second.savedAdvancedPlacement)
    }

    @MainActor
    func testAdvancedSaveBlockedWhileBaseGeometryIsUnsaved() throws {
        let (store, _, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RoomTreatmentAdvisorController(store: store)
        controller.prepareForUse()
        controller.startGeometryTemplate()
        controller.setAdvancedToeIn(.right, degrees: 20)
        controller.saveAdvancedPlacement()
        XCTAssertNil(controller.savedAdvancedPlacement)
        XCTAssertNotNil(controller.advancedPlacementMessage)
        controller.saveGeometry()
        controller.saveAdvancedPlacement()
        XCTAssertEqual(controller.savedAdvancedPlacement?.rightToeInDegrees, 20)
    }

    @MainActor
    func testAdvancedDraftRevertDoesNotTouchSavedGeometry() throws {
        let (store, _, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RoomTreatmentAdvisorController(store: store)
        controller.prepareForUse()
        controller.startGeometryTemplate()
        controller.saveGeometry()
        controller.setAdvancedToeIn(.left, degrees: 15)
        controller.saveAdvancedPlacement()
        let baseline = try XCTUnwrap(controller.savedGeometry)
        controller.setAdvancedToeIn(.left, degrees: 23)
        controller.addAdvancedSeat()
        controller.revertAdvancedPlacement()
        XCTAssertEqual(controller.advancedPlacementDraft?.leftToeInDegrees, 15)
        XCTAssertEqual(controller.advancedPlacementDraft?.secondarySeats.count, 0)
        XCTAssertEqual(controller.geometryDraft, baseline)
    }

    @MainActor
    func testClearingGeometryRemovesOnlyCorrespondingAdvancedSidecar() throws {
        let (store, project, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RoomTreatmentAdvisorController(store: store)
        controller.prepareForUse()
        controller.startGeometryTemplate()
        controller.saveGeometry()
        controller.saveAdvancedPlacement()
        let url = RoomAdvancedPlacementStore(projectStore: store)
            .settingsURL(for: project.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        controller.clearGeometry()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(controller.savedGeometry)
        XCTAssertNil(controller.advancedPlacementDraft)
        XCTAssertEqual(try store.load(project.id), project)
    }
}


// PR110 Slice 3: only PR106-qualified directivity may inform physical
// placement hypotheses. Positive similarity scores are NOT SPL improvements.
final class AdvancedPlacementDirectivityTests: XCTestCase {
    private let systemID = UUID(
        uuidString: "AB110000-0000-0000-0000-000000000001")!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr110-mic", inputChannelIndex: 0,
        calibrationFingerprint: "pr110-mic-cal"
    )
    private let analyzer = RoomAdvancedToeInEvidenceAnalyzer()

    private func roomState() -> RoomAdvancedPlacementState {
        var room = RoomGeometryModel.template(
            projectID: UUID(uuidString:
                "AB110000-0000-0000-0000-000000000002")!
        )
        // Left speaker bearing to center listener is 0° from +Y.
        room.leftSpeaker.x = room.listener.x - 0.02
        room.rightSpeaker.x = room.listener.x + 0.3
        return RoomAdvancedPlacementState(
            room: room, leftToeInDegrees: 6, rightToeInDegrees: -6
        )
    }

    private func protocolItem(
        _ side: RoomGeometrySpeaker,
        mode: SpeakerMeasurementLabMode,
        angle: Double,
        radius: Double = 1.0
    ) -> SpeakerMeasurementLabProtocol {
        SpeakerMeasurementLabProtocol(
            name: "PR110 \(angle)",
            request: SpeakerMeasurementLabRequest(
                mode: mode,
                target: .acousticSource(
                    .speaker(side == .left ? .frontLeft : .frontRight)
                ),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: radius,
                    horizontalAngleDegrees: angle
                )
            )
        )
    }

    private func makeSession(
        speaker: RoomGeometrySpeaker = .left,
        angles: [Double] = [-15, 15],
        offAxisLoss: Double = 4,
        snrDB: Double = 55
    ) -> (SpeakerMeasurementLabSession, UUID) {
        let on = protocolItem(speaker, mode: .wholeSpeakerOnAxis, angle: 0)
        let others = angles.map {
            protocolItem(speaker, mode: .wholeSpeakerOffAxis, angle: $0)
        }
        let frequencyGrid = (0..<64).map { n in
            100.0 * pow(100.0, Double(n) / 63)
        }
        let protocols = [on] + others
        let source: MultichannelCalibrationSource = .speaker(
            speaker == .left ? .frontLeft : .frontRight
        )
        let captures = protocols.flatMap { item in
            (0..<3).map { i in
                SpeakerMeasurementLabCapture(
                    protocolID: item.id,
                    repeatIndex: i,
                    capturedAt: Date(timeIntervalSince1970:
                        1_704_100_100 + Double(i)),
                    playbackSystemID: systemID,
                    routingSignature: "pr110-same-route",
                    microphone: microphone,
                    sampleRate: 48_000,
                    source: source,
                    impulseResponse: [0, 0.1, 1, 0.2, 0],
                    transferFunction: RoomCorrectionFrequencyResponse(
                        frequenciesHz: frequencyGrid,
                        magnitudeDB: frequencyGrid.map { hz in
                            2 * exp(-0.5 * pow(log2(hz / 2_000) / 0.8, 2))
                                - (item.id == on.id ? 0 : offAxisLoss)
                                + Double(i - 1) * 0.02
                        },
                        phaseRadians: frequencyGrid.map { hz in
                            0.03 * log2(hz / 1_000)
                                + Double(i - 1) * 0.005
                        }
                    ),
                    quality: RoomCorrectionMeasurementQuality(
                        clipped: false,
                        playbackPeakDBFS: -20,
                        capturePeakDBFS: -12,
                        estimatedNoiseFloorDBFS: -70,
                        estimatedSNRDB: snrDB,
                        sweepComplete: true,
                        directArrivalSeconds:
                            0.003 + Double(i) * 0.00002,
                        usableLowHz: 100,
                        usableHighHz: 10_000,
                        warnings: []
                    )
                )
            }
        }
        return (
            SpeakerMeasurementLabSession(
                playbackSystemID: systemID,
                routingSignature: "pr110-same-route",
                microphone: microphone,
                sampleRate: 48_000,
                protocols: protocols,
                captures: captures,
                createdAt: Date(timeIntervalSince1970: 1_704_100_000),
                modifiedAt: Date(timeIntervalSince1970: 1_704_100_000)
            ),
            on.id
        )
    }

    func testQualifiedSignedAnglesProduceExplicitlyNonDeployableComparisons()
        throws {
        let state = roomState()
        let (session, onAxis) = makeSession()
        let ranked = try analyzer.evaluate(
            state: state, playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        )
        XCTAssertEqual(ranked.count, 2)
        XCTAssertTrue(ranked.allSatisfy {
            $0.status == .measuredComparison
        })
        XCTAssertTrue(ranked.allSatisfy {
            $0.sessionID == session.id && $0.sourceProtocolID == onAxis
        })
        XCTAssertTrue(ranked.allSatisfy {
            $0.currentAbsoluteDeviationDB != nil
                && $0.trialAbsoluteDeviationDB != nil
                && $0.indicatedSpectralChangeDB?.isFinite == true
        })
        XCTAssertFalse(ranked[0].note.contains("SPL"))
        XCTAssertEqual(ranked.first?.experimentID, "left-toe-clockwise")
        XCTAssertGreaterThan(ranked[0].indicatedSpectralChangeDB ?? -1, 0)
        XCTAssertLessThan(ranked[1].indicatedSpectralChangeDB ?? 1, 0)
    }

    func testSingleAngleDoesNotExtrapolateMissingNegativeSide() throws {
        let state = roomState()
        let (session, onAxis) = makeSession(angles: [15])
        let ranked = try analyzer.evaluate(
            state: state, playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        )
        XCTAssertEqual(ranked.count, 2)
        XCTAssertTrue(ranked.contains { $0.status == .inconclusive })
        XCTAssertTrue(ranked.filter {
            $0.status == .inconclusive
        }.allSatisfy { $0.indicatedSpectralChangeDB == nil })
    }

    func testWideAngleGapDoesNotInventInterpolation() throws {
        let (session, onAxis) = makeSession(angles: [-35, 35])
        let ranked = try analyzer.evaluate(
            state: roomState(), playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        )
        XCTAssertTrue(ranked.allSatisfy {
            $0.status == .inconclusive
        })
    }

    func testWrongPlaybackSystemRejectedBeforeLabAnalysis() throws {
        let (session, onAxis) = makeSession()
        XCTAssertThrowsError(try analyzer.evaluate(
            state: roomState(), playbackSystemID: UUID(),
            session: session, onAxisProtocolID: onAxis, speaker: .left
        )) {
            XCTAssertEqual($0 as? RoomAdvancedDirectivityError,
                           .invalidProjectIdentity)
        }
    }

    func testWrongSpeakerRejectedDespiteOtherSideHavingValidData() throws {
        let (session, onAxis) = makeSession(speaker: .right)
        XCTAssertThrowsError(try analyzer.evaluate(
            state: roomState(), playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        )) {
            XCTAssertEqual($0 as? RoomAdvancedDirectivityError,
                           .invalidSource)
        }
    }

    func testLowSNRNotConvertedIntoPlacementScore() throws {
        let (session, onAxis) = makeSession(snrDB: 12)
        XCTAssertThrowsError(try analyzer.evaluate(
            state: roomState(), playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        )) {
            XCTAssertEqual($0 as? RoomAdvancedDirectivityError,
                           .unqualifiedLabEvidence)
        }
    }

    func testClippedDirectivityCannotInformToeIn() throws {
        var (session, onAxis) = makeSession()
        session.captures[4].quality.clipped = true
        XCTAssertThrowsError(try analyzer.evaluate(
            state: roomState(), playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        ))
    }

    func testUndersampledDirectivityCannotInformToeIn() throws {
        var (session, onAxis) = makeSession()
        session.captures.removeAll {
            $0.protocolID == onAxis && $0.repeatIndex == 2
        }
        XCTAssertThrowsError(try analyzer.evaluate(
            state: roomState(), playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        ))
    }

    func testMismatchedMeasurementRadiusCannotInformToeIn() throws {
        var (session, onAxis) = makeSession()
        session.protocols[1].request.geometry.distanceMeters = 1.4
        XCTAssertThrowsError(try analyzer.evaluate(
            state: roomState(), playbackSystemID: systemID,
            session: session, onAxisProtocolID: onAxis, speaker: .left
        ))
    }

    @MainActor
    func testControllerRequiresExplicitSavedGeometryConfirmation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR110-Directivity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        let project = RoomCorrectionProject(
            id: UUID(), playbackSystemID: systemID, name: "PR110 Toe-In"
        )
        try store.save(project)
        let controller = RoomTreatmentAdvisorController(store: store)
        controller.prepareForUse()
        controller.startGeometryTemplate()
        controller.saveGeometry()
        controller.inspectRecentDirectivity(physicalGeometryMatchesCapture: false)
        XCTAssertTrue(controller.toeInMeasurementEvidence.isEmpty)
        XCTAssertNotNil(controller.toeInEvidenceMessage)
    }
}


// PR110 Slice 4: real A/B sub placement evidence, no unmeasured predictions.
final class AdvancedSubPlacementABTests: XCTestCase {
    private let systemID = UUID(uuidString:
        "44000000-0000-0000-0000-000000000001")!
    private let seatIDs = [
        UUID(uuidString: "44000000-0000-0000-0000-000000000002")!,
        UUID(uuidString: "44000000-0000-0000-0000-000000000003")!,
        UUID(uuidString: "44000000-0000-0000-0000-000000000004")!,
    ]
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr110-multi-seat-mic", inputChannelIndex: 0,
        calibrationFingerprint: "pr110-calibrated-mic"
    )
    private let source: MultichannelCalibrationSource = .subwoofer(0)

    private func scenario() throws -> (
        RoomAdvancedPlacementState, RoomAdvancedPlacementExperiment
    ) {
        let room = RoomGeometryModel.template(
            projectID: UUID(uuidString:
                "44000000-0000-0000-0000-000000000005")!
        )
        let state = RoomAdvancedPlacementState(
            room: room,
            secondarySeats: [
                RoomGeometryPoint3D(x: 1.5, y: 3.5, z: 1.1),
                RoomGeometryPoint3D(x: 2.5, y: 3.5, z: 1.1),
            ],
            subwooferPositions: [
                RoomGeometryPoint3D(x: 0.5, y: 0.5, z: 0.2)
            ]
        )
        let experiment = try XCTUnwrap(
            RoomAdvancedPlacementExplorer()
                .experiments(for: state)
                .first { $0.id == "sub-0-right" }
        )
        return (state, experiment)
    }

    private func captures(
        role: SpeakerOptimizerMeasurementRole,
        spread: Double
    ) -> SpeakerOptimizerMeasurementSet {
        let grid = (0..<80).map { i in
            20.0 * pow(20.0, Double(i) / 79)
        }
        let offsets = [-spread, 0.0, spread]
        var samples: [SpeakerOptimizerMeasurementCapture] = []
        let baseTime: Double = role == .baseline
            ? 1_700_000_000 : 1_700_000_600
        for (seatIndex, positionID) in seatIDs.enumerated() {
            for repeatIndex in 0..<3 {
                let drift = Double(repeatIndex - 1) * 0.02
                let magnitude: [Double] = grid.map { hz in
                    offsets[seatIndex] + 0.1 * log2(hz / 75) + drift
                }
                let phase: [Double] = grid.map { hz in
                    0.03 * log2(hz / 100)
                        + Double(repeatIndex - 1) * 0.005
                }
                let response = RoomCorrectionFrequencyResponse(
                    frequenciesHz: grid,
                    magnitudeDB: magnitude,
                    phaseRadians: phase
                )
                let quality = RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -20,
                    capturePeakDBFS: -12,
                    estimatedNoiseFloorDBFS: -70,
                    estimatedSNRDB: 54,
                    sweepComplete: true,
                    directArrivalSeconds:
                        0.010 + Double(repeatIndex) * 0.00002,
                    usableLowHz: 25,
                    usableHighHz: 300,
                    warnings: []
                )
                let timestamp = baseTime
                    + Double(seatIndex * 6 + repeatIndex)
                let capture = SpeakerOptimizerMeasurementCapture(
                    capturedAt: Date(timeIntervalSince1970: timestamp),
                    playbackSystemID: systemID,
                    routingSignature: "pr110-route-one",
                    microphone: mic,
                    positionID: positionID,
                    source: source,
                    sampleRate: 48_000,
                    response: response,
                    quality: quality
                )
                samples.append(capture)
            }
        }
        return SpeakerOptimizerMeasurementSet(
            role: role,
            playbackSystemID: systemID,
            routingSignature: "pr110-route-one",
            microphone: mic,
            sampleRate: 48_000,
            positions: seatIDs.enumerated().map { n, id in
                SpeakerOptimizerMeasurementPosition(id: id,
                    name: "Seat \(n + 1)")
            },
            plannedSources: [source],
            captures: samples
        )
    }

    private func measure(
        _ baseline: SpeakerOptimizerMeasurementSet,
        _ candidate: SpeakerOptimizerMeasurementSet,
        physicalSetupConfirmed: Bool = true
    ) throws -> RoomAdvancedSubPlacementComparison {
        let (state, trial) = try scenario()
        return try RoomAdvancedSubPlacementComparisonAnalyzer().compare(
            baseline: baseline, candidate: candidate, state: state,
            experiment: trial, playbackSystemID: systemID,
            physicalSetupConfirmed: physicalSetupConfirmed
        )
    }

    func testMeasuredSubMoveComparesActualThreeSeatLFVariation() throws {
        let result = try measure(captures(role: .baseline, spread: 6),
                                 captures(role: .candidate, spread: 2))
        XCTAssertEqual(result.experimentID, "sub-0-right")
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.seatCount, 3)
        XCTAssertGreaterThanOrEqual(result.commonFrequencyPointCount, 12)
        XCTAssertGreaterThan(result.reductionInInterseatSpreadDB, 2)
        XCTAssertGreaterThan(result.evidenceConfidence, 0.5)
        XCTAssertTrue(result.measurementOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertTrue(result.requiresRealWorldListeningVerification)
    }

    func testMovingSubCanWorsenMeasuredSeatConsistency() throws {
        let result = try measure(captures(role: .baseline, spread: 1),
                                 captures(role: .candidate, spread: 5))
        XCTAssertLessThan(result.reductionInInterseatSpreadDB, -2)
    }

    func testCommonGainShiftDoesNotFabricateSeatImprovement() throws {
        let prior = captures(role: .baseline, spread: 3)
        var after = captures(role: .candidate, spread: 3)
        for i in after.captures.indices {
            after.captures[i].response.magnitudeDB =
                after.captures[i].response.magnitudeDB.map { $0 + 7 }
        }
        let result = try measure(prior, after)
        XCTAssertEqual(result.reductionInInterseatSpreadDB, 0,
                       accuracy: 0.0001)
    }

    func testMissingHumanAttestationFailsClosed() throws {
        XCTAssertThrowsError(try measure(
            captures(role: .baseline, spread: 5),
            captures(role: .candidate, spread: 2),
            physicalSetupConfirmed: false
        )) {
            XCTAssertEqual(
                $0 as? RoomAdvancedSubPlacementComparisonError,
                .missingPhysicalAttestation
            )
        }
    }

    func testWrongMicrophoneRouteOrSeatIdentityFailsClosed() throws {
        let before = captures(role: .baseline, spread: 5)
        var after = captures(role: .candidate, spread: 2)
        after.microphone.deviceUID = "other-microphone"
        XCTAssertThrowsError(try measure(before, after))
        after = captures(role: .candidate, spread: 2)
        after.routingSignature = "other-route"
        XCTAssertThrowsError(try measure(before, after))
        after = captures(role: .candidate, spread: 2)
        after.positions.swapAt(0, 1)
        XCTAssertThrowsError(try measure(before, after))
    }

    func testIncompleteRepeatsAndClippingFailClosed() throws {
        let before = captures(role: .baseline, spread: 5)
        var after = captures(role: .candidate, spread: 2)
        // Clipping or a missing repeated capture is always rejected.
        after.captures[0].quality.clipped = true
        XCTAssertThrowsError(try measure(before, after))
        after = captures(role: .candidate, spread: 2)
        after.captures.remove(at: 0)
        XCTAssertThrowsError(try measure(before, after))
    }

    func testCandidateMustBeCapturedAfterIndependentBaseline() throws {
        let before = captures(role: .baseline, spread: 5)
        var after = captures(role: .candidate, spread: 2)
        for i in after.captures.indices {
            after.captures[i].capturedAt =
                Date(timeIntervalSince1970: 1_600_000_000 + Double(i))
        }
        XCTAssertThrowsError(try measure(before, after))
        after = captures(role: .candidate, spread: 2)
        after.captures[0].id = before.captures[0].id
        XCTAssertThrowsError(try measure(before, after))
    }

    func testUnqualifiedSourceOrNoRealSubMoveRejected() throws {
        let prior = captures(role: .baseline, spread: 5)
        let after = captures(role: .candidate, spread: 2)
        let (state, trial) = try scenario()
        var bad = trial
        bad.trial.subwooferPositions = state.subwooferPositions
        XCTAssertThrowsError(try RoomAdvancedSubPlacementComparisonAnalyzer()
            .compare(baseline: prior, candidate: after, state: state,
                     experiment: bad, playbackSystemID: systemID,
                     physicalSetupConfirmed: true))
        var main = after
        main.plannedSources = [.speaker(.frontLeft)]
        XCTAssertThrowsError(try measure(prior, main))
    }

    func testResponseGridMismatchOrMissingBassCoverageRejected() throws {
        let prior = captures(role: .baseline, spread: 5)
        var after = captures(role: .candidate, spread: 2)
        after.captures[0].response.frequenciesHz[7] *= 1.01
        XCTAssertThrowsError(try measure(prior, after))
        after = captures(role: .candidate, spread: 2)
        for i in after.captures.indices {
            after.captures[i].quality.usableLowHz = 120
        }
        XCTAssertThrowsError(try measure(prior, after))
    }
}


// PR110 Slice 5: append-only physical placement review, never DSP authority.
final class AdvancedPlacementReviewHistoryTests: XCTestCase {
    private func fixture() throws -> (
        RoomCorrectionProjectStore, RoomCorrectionProject,
        RoomAdvancedPlacementState, RoomAdvancedPlacementExperiment, URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR110-PlacementHistory-\(UUID())")
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        let project = RoomCorrectionProject(
            id: UUID(), playbackSystemID: UUID(), name: "Review History"
        )
        try store.save(project)
        let room = RoomGeometryModel.template(projectID: project.id)
        let state = RoomAdvancedPlacementState(
            room: room,
            secondarySeats: [
                RoomGeometryPoint3D(x: 1.5, y: 3.4, z: 1.1)
            ],
            subwooferPositions: [
                RoomGeometryPoint3D(x: 0.5, y: 0.5, z: 0.2)
            ]
        )
        let trial = try XCTUnwrap(
            RoomAdvancedPlacementExplorer().experiments(for: state)
                .first { $0.id == "sub-0-right" }
        )
        return (store, project, state, trial, root)
    }

    private func unverified(
        _ project: RoomCorrectionProject,
        _ state: RoomAdvancedPlacementState,
        _ trial: RoomAdvancedPlacementExperiment
    ) throws -> RoomAdvancedPlacementReviewRecord {
        try RoomAdvancedPlacementReviewFactory().make(
            playbackSystemID: project.playbackSystemID,
            state: state,
            experiment: trial,
            comparison: nil
        )
    }

    func testReviewHistoryRoundTripsWithoutTouchingOriginalGeometry() throws {
        let (store, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let geometryStore = RoomGeometryStore(projectStore: store)
        try geometryStore.save(state.room)
        let before = try Data(contentsOf:
            geometryStore.geometryURL(for: project.id))
        let archive = RoomAdvancedPlacementReviewStore(projectStore: store)
        let record = try unverified(project, state, trial)
        XCTAssertEqual(record.outcome, .inconclusive)
        XCTAssertFalse(record.hardwareAcceptanceComplete)
        XCTAssertFalse(record.canDeploy)
        XCTAssertNil(record.measuredSpreadReductionDB)
        XCTAssertEqual(record.beforeGeometry, state.room)
        XCTAssertEqual(record.afterGeometry, trial.trial.room)
        try archive.append(record)
        XCTAssertEqual(
            try archive.load(projectID: project.id).records,
            [record]
        )
        XCTAssertEqual(
            try Data(contentsOf: geometryStore.geometryURL(for: project.id)),
            before
        )
        XCTAssertEqual(try store.load(project.id), project)
    }

    func testArchiveIsAppendOnlyAndRejectsDuplicateIDs() throws {
        let (store, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RoomAdvancedPlacementReviewStore(projectStore: store)
        let first = try unverified(project, state, trial)
        try archive.append(first)
        XCTAssertThrowsError(try archive.append(first)) {
            XCTAssertEqual(
                $0 as? RoomAdvancedPlacementReviewError, .duplicateRecord
            )
        }
        let second = try unverified(project, state, trial)
        try archive.append(second)
        XCTAssertEqual(
            try archive.load(projectID: project.id).records.map(\.id),
            [first.id, second.id]
        )
    }

    func testCorruptionFailsClosedWithoutOverwritingHistory() throws {
        let (store, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RoomAdvancedPlacementReviewStore(projectStore: store)
        let path = archive.historyURL(for: project.id)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let broken = Data("{broken".utf8)
        try broken.write(to: path)
        XCTAssertThrowsError(try archive.load(projectID: project.id)) {
            XCTAssertEqual(
                $0 as? RoomAdvancedPlacementReviewError, .corruptedHistory
            )
        }
        XCTAssertThrowsError(
            try archive.append(unverified(project, state, trial))
        )
        XCTAssertEqual(try Data(contentsOf: path), broken)
    }

    func testCrossProjectHistoryNeverLeaks() throws {
        let (store, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RoomAdvancedPlacementReviewStore(projectStore: store)
        try archive.append(unverified(project, state, trial))
        let otherProject = UUID()
        XCTAssertTrue(
            try archive.load(projectID: otherProject).records.isEmpty
        )
    }

    func testTamperingCannotDeclareHardwareAcceptanceOrForgeGeometry() throws {
        let (_, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try unverified(project, state, trial)
        record.hardwareAcceptanceComplete = true
        XCTAssertThrowsError(try record.validated(for: project.id))
        record.hardwareAcceptanceComplete = false
        record.afterGeometry.rightSpeaker.x += 0.5
        XCTAssertThrowsError(try record.validated(for: project.id))
        record = try unverified(project, state, trial)
        record.outcome = .improved
        record.measuredSpreadReductionDB = 5
        XCTAssertThrowsError(try record.validated(for: project.id))
    }

    func testMeasuredOutcomesConveyRelativeLFSpreadOnly() throws {
        let (_, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let beforeID = UUID()
        let afterID = UUID()
        let comparison = RoomAdvancedSubPlacementComparison(
            experimentID: trial.id,
            source: .subwoofer(0),
            baselineMeasurementSetID: beforeID,
            candidateMeasurementSetID: afterID,
            seatCount: 3,
            commonFrequencyPointCount: 27,
            commonLowHz: 35,
            commonHighHz: 160,
            baselineInterseatSpreadRMSDB: 5,
            candidateInterseatSpreadRMSDB: 2,
            reductionInInterseatSpreadDB: 3,
            evidenceConfidence: 0.9
        )
        let factory = RoomAdvancedPlacementReviewFactory()
        let improved = try factory.make(
            playbackSystemID: project.playbackSystemID,
            state: state, experiment: trial, comparison: comparison
        )
        XCTAssertEqual(improved.outcome, .improved)
        XCTAssertEqual(improved.baselineMeasurementSetID, beforeID)
        XCTAssertEqual(improved.candidateMeasurementSetID, afterID)
        XCTAssertEqual(improved.measuredSeatCount, 3)
        XCTAssertFalse(improved.hardwareAcceptanceComplete)
        var worse = comparison
        worse.reductionInInterseatSpreadDB = -3
        worse.baselineInterseatSpreadRMSDB = 2
        worse.candidateInterseatSpreadRMSDB = 5
        XCTAssertEqual(
            try factory.make(
                playbackSystemID: project.playbackSystemID,
                state: state, experiment: trial, comparison: worse
            ).outcome,
            .regressed
        )
        var small = comparison
        small.reductionInInterseatSpreadDB = 0.1
        small.candidateInterseatSpreadRMSDB = 4.9
        let uncertain = try factory.make(
            playbackSystemID: project.playbackSystemID,
            state: state, experiment: trial, comparison: small
        )
        XCTAssertEqual(uncertain.outcome, .inconclusive)
        XCTAssertNil(uncertain.measuredSpreadReductionDB)
    }

    func testInconclusiveReviewPreservesAttemptedCaptureReferences() throws {
        let (_, project, state, trial, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = UUID()
        let candidate = UUID()
        let record = try RoomAdvancedPlacementReviewFactory().make(
            playbackSystemID: project.playbackSystemID,
            state: state,
            experiment: trial,
            comparison: nil,
            attemptedBaselineID: baseline,
            attemptedCandidateID: candidate,
            inconclusiveReason: "Insufficient repeat-qualified seat captures"
        )
        XCTAssertEqual(record.outcome, .inconclusive)
        XCTAssertEqual(record.baselineMeasurementSetID, baseline)
        XCTAssertEqual(record.candidateMeasurementSetID, candidate)
        XCTAssertNil(record.measuredSpreadReductionDB)
    }

    @MainActor
    func testControllerRequiresPhysicalConfirmationAndPreservesProjectHistory()
        throws {
        let (store, project, state, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RoomTreatmentAdvisorController(store: store)
        controller.prepareForUse()
        controller.startGeometryTemplate()
        controller.saveGeometry()
        controller.addAdvancedSeat()
        controller.addAdvancedSubwoofer()
        controller.saveAdvancedPlacement()
        let trial = try XCTUnwrap(controller.advancedPlacementExperiments
            .first { $0.id == "sub-0-right" })
        controller.previewAdvancedExperiment(trial)
        let before = controller.savedGeometry
        controller.recordPlacementReview(
            physicalMoveConfirmed: false,
            fixedMicrophoneSeatsAndSignalChainConfirmed: false
        )
        XCTAssertTrue(controller.placementReviewHistory.isEmpty)
        controller.recordPlacementReview(
            physicalMoveConfirmed: true,
            fixedMicrophoneSeatsAndSignalChainConfirmed: false
        )
        XCTAssertEqual(controller.placementReviewHistory.count, 1)
        XCTAssertEqual(controller.placementReviewHistory[0].outcome,
                       .inconclusive)
        XCTAssertEqual(controller.savedGeometry, before)
        XCTAssertEqual(controller.geometryDraft, before)

        let reloaded = RoomTreatmentAdvisorController(store: store)
        reloaded.prepareForUse()
        XCTAssertEqual(reloaded.placementReviewHistory,
                       controller.placementReviewHistory)
        XCTAssertEqual(reloaded.selectedProjectID, project.id)
        XCTAssertEqual(reloaded.savedGeometry, state.room)
    }

    @MainActor
    func testUncommittedRoomCannotRecordPlacementReview() throws {
        let (store, _, _, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RoomTreatmentAdvisorController(store: store)
        controller.prepareForUse()
        controller.startGeometryTemplate()
        let trial = try XCTUnwrap(
            controller.advancedPlacementExperiments.first
        )
        controller.previewAdvancedExperiment(trial)
        controller.recordPlacementReview(
            physicalMoveConfirmed: true,
            fixedMicrophoneSeatsAndSignalChainConfirmed: true
        )
        XCTAssertTrue(controller.placementReviewHistory.isEmpty)
        XCTAssertNotNil(controller.placementReviewMessage)
    }
}
