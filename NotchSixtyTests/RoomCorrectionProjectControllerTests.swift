import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class RoomCorrectionProjectControllerTests: XCTestCase {
    private struct OutputCatalogFixture: OutputDeviceCataloging {
        func outputDevices() throws -> [AudioOutputDevice] { [] }
    }

    private struct Fixture {
        let root: URL
        let profiles: ProductProfileController
        let controller: RoomCorrectionProjectController
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR40-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(
            engine: engine,
            storageURL: root.appendingPathComponent("profiles-v1.json")
        )
        let store = RoomCorrectionProjectStore(
            rootDirectory: root.appendingPathComponent("Room Correction", isDirectory: true)
        )
        let controller = RoomCorrectionProjectController(profiles: profiles, store: store)
        XCTAssertNotNil(profiles.selectedSystemProfileID)
        return Fixture(root: root, profiles: profiles, controller: controller)
    }

    private func sweep(sampleRate: Double = 48_000, duration: Double = 5) -> RoomCorrectionSweepSettings {
        RoomCorrectionSweepSettings(
            sampleRate: sampleRate,
            startFrequencyHz: 20,
            endFrequencyHz: min(20_000, sampleRate * 0.45),
            durationSeconds: duration,
            levelDBFS: -18,
            leadInSeconds: 0.5,
            tailSeconds: 1,
            fadeSeconds: 0.02
        )
    }

    private func microphone(
        stableID: String = "mic-1",
        channel: Int = 0
    ) -> RoomCorrectionMicrophone {
        RoomCorrectionMicrophone(
            stableID: stableID,
            displayName: "Measurement Mic",
            manufacturer: nil,
            inputChannelIndex: channel,
            calibration: nil
        )
    }

    private func analysis(
        capturedAt: TimeInterval,
        leftMagnitude: [Double] = [0, 0],
        rightMagnitude: [Double] = [0, 0],
        frequencies: [Double] = [100, 1_000],
        sampleRate: Double = 48_000,
        clipped: Bool = false,
        snr: Double = 45,
        sweepComplete: Bool = true
    ) -> RoomCorrectionMeasurementAnalysis {
        let quality = RoomCorrectionMeasurementQuality(
            clipped: clipped,
            playbackPeakDBFS: -18,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -70,
            estimatedSNRDB: snr,
            sweepComplete: sweepComplete,
            directArrivalSeconds: 0.01,
            usableLowHz: frequencies.first,
            usableHighHz: frequencies.last,
            warnings: []
        )
        let date = Date(timeIntervalSince1970: capturedAt)
        let left = RoomCorrectionChannelMeasurement(
            capturedAt: date,
            rawCapture: [Float(capturedAt), 0.25],
            impulseResponse: [1, 0],
            transferFunction: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: leftMagnitude,
                phaseRadians: [0.1, 0.2]
            ),
            quality: quality
        )
        let right = RoomCorrectionChannelMeasurement(
            capturedAt: date,
            rawCapture: [Float(capturedAt), 0.5],
            impulseResponse: [1, 0],
            transferFunction: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: rightMagnitude,
                phaseRadians: [-0.1, -0.2]
            ),
            quality: quality
        )
        return RoomCorrectionMeasurementAnalysis(
            sampleRate: sampleRate,
            left: left,
            right: right
        )
    }

    func testDefaultNamesRemainErgonomicBeyondThreePositionsAndRawProjectReloads() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for index in 1...4 {
            try fixture.controller.retainMeasurement(
                analysis(capturedAt: TimeInterval(index)),
                sweep: sweep(),
                microphone: microphone(),
                retainedAt: Date(timeIntervalSince1970: 100 + TimeInterval(index))
            )
        }

        XCTAssertEqual(
            fixture.controller.positions.map(\.name),
            ["Center", "Left", "Right", "Position 4"]
        )
        XCTAssertEqual(fixture.controller.positions.count, 4)
        XCTAssertEqual(fixture.controller.positions[3].left.rawCapture, [4, 0.25])
        XCTAssertNotNil(fixture.controller.aggregate)
        XCTAssertNil(fixture.controller.aggregate?.leftResponse.phaseRadians)
        XCTAssertNil(fixture.controller.aggregate?.rightResponse.phaseRadians)

        let reloaded = RoomCorrectionProjectController(
            profiles: fixture.profiles,
            store: fixture.controller.store
        )
        try reloaded.reloadForSelectedPlaybackSystem()

        XCTAssertEqual(reloaded.project, fixture.controller.project)
        XCTAssertEqual(reloaded.positions[0].left.rawCapture, [1, 0.25])
        XCTAssertEqual(reloaded.positions[3].right.rawCapture, [4, 0.5])
    }

    func testWeightedAggregationUsesNormalizedDBWeightsAndDropsAggregatePhase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let firstID = try fixture.controller.retainMeasurement(
            analysis(
                capturedAt: 1,
                leftMagnitude: [0, 10],
                rightMagnitude: [2, 12]
            ),
            sweep: sweep(),
            microphone: microphone()
        )
        let secondID = try fixture.controller.retainMeasurement(
            analysis(
                capturedAt: 2,
                leftMagnitude: [10, 20],
                rightMagnitude: [12, 22]
            ),
            sweep: sweep(),
            microphone: microphone()
        )

        try fixture.controller.setMeasurementWeight(id: firstID, weight: 1)
        try fixture.controller.setMeasurementWeight(id: secondID, weight: 3)

        let aggregate = try XCTUnwrap(fixture.controller.aggregate)
        XCTAssertEqual(aggregate.leftResponse.magnitudeDB[0], 7.5, accuracy: 0.000_001)
        XCTAssertEqual(aggregate.leftResponse.magnitudeDB[1], 17.5, accuracy: 0.000_001)
        XCTAssertEqual(aggregate.rightResponse.magnitudeDB[0], 9.5, accuracy: 0.000_001)
        XCTAssertEqual(aggregate.rightResponse.magnitudeDB[1], 19.5, accuracy: 0.000_001)
        XCTAssertNil(aggregate.leftResponse.phaseRadians)
        XCTAssertNil(aggregate.rightResponse.phaseRadians)
        XCTAssertEqual(Set(aggregate.includedPositionIDs), Set([firstID, secondID]))
    }

    func testExcludedPositionIsRetainedButRemovedFromAggregate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let firstID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1, leftMagnitude: [0, 0], rightMagnitude: [1, 1]),
            sweep: sweep(),
            microphone: microphone()
        )
        let secondID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 2, leftMagnitude: [10, 10], rightMagnitude: [11, 11]),
            sweep: sweep(),
            microphone: microphone()
        )

        try fixture.controller.setMeasurementIncluded(id: firstID, included: false)
        XCTAssertEqual(fixture.controller.positions.count, 2)
        XCTAssertFalse(fixture.controller.positions[0].included)
        XCTAssertEqual(fixture.controller.aggregate?.includedPositionIDs, [secondID])
        XCTAssertEqual(fixture.controller.aggregate?.leftResponse.magnitudeDB, [10, 10])

        try fixture.controller.setMeasurementIncluded(id: secondID, included: false)
        XCTAssertEqual(fixture.controller.positions.count, 2)
        XCTAssertNil(fixture.controller.aggregate)
    }

    func testZeroTotalWeightIsValidProjectStateWithNoAggregate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let id = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setMeasurementWeight(id: id, weight: 0)

        XCTAssertEqual(fixture.controller.positions.first?.weight, 0)
        XCTAssertNil(fixture.controller.aggregate)
        let projectID = try XCTUnwrap(fixture.controller.project?.id)
        XCTAssertEqual(try fixture.controller.store.load(projectID), fixture.controller.project)
    }

    func testRenamePersistsWithoutChangingMeasurementData() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let id = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        let rawBefore = fixture.controller.positions[0].left.rawCapture
        try fixture.controller.renameMeasurement(id: id, to: "Rear Sofa")

        XCTAssertEqual(fixture.controller.positions[0].name, "Rear Sofa")
        XCTAssertEqual(fixture.controller.positions[0].left.rawCapture, rawBefore)
        let projectID = try XCTUnwrap(fixture.controller.project?.id)
        XCTAssertEqual(try fixture.controller.store.load(projectID).measurements[0].name, "Rear Sofa")
    }

    func testIncompatibleFrequencyGridFailsTransactionally() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        let before = fixture.controller.project

        XCTAssertThrowsError(
            try fixture.controller.retainMeasurement(
                analysis(capturedAt: 2, frequencies: [125, 1_000]),
                sweep: sweep(),
                microphone: microphone()
            )
        ) { error in
            guard case RoomCorrectionSpatialAggregationError.incompatibleFrequencyGrid = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fixture.controller.project, before)
        XCTAssertEqual(fixture.controller.positions.count, 1)
    }

    func testSweepAndMicrophoneChangesDoNotSilentlyMixIntoExistingProject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )

        XCTAssertThrowsError(
            try fixture.controller.retainMeasurement(
                analysis(capturedAt: 2),
                sweep: sweep(duration: 10),
                microphone: microphone()
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionProjectControllerError,
                .incompatibleSweepSettings
            )
        }

        XCTAssertThrowsError(
            try fixture.controller.retainMeasurement(
                analysis(capturedAt: 3),
                sweep: sweep(),
                microphone: microphone(stableID: "different-mic")
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionProjectControllerError,
                .incompatibleMicrophone
            )
        }
        XCTAssertEqual(fixture.controller.positions.count, 1)
    }

    func testDuplicateAnalyzedCaptureCannotBeRetainedTwice() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = analysis(capturedAt: 1)
        _ = try fixture.controller.retainMeasurement(
            result,
            sweep: sweep(),
            microphone: microphone()
        )

        XCTAssertThrowsError(
            try fixture.controller.retainMeasurement(
                result,
                sweep: sweep(),
                microphone: microphone()
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionProjectControllerError,
                .measurementAlreadyRetained
            )
        }
        XCTAssertEqual(fixture.controller.positions.count, 1)
    }

    func testTargetPreviewAndGeneratedDesignPersistTransactionally() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try fixture.controller.retainMeasurement(
            analysis(
                capturedAt: 1,
                leftMagnitude: [-2, -2],
                rightMagnitude: [2, 2]
            ),
            sweep: sweep(),
            microphone: microphone()
        )
        let target = RoomCorrectionBuiltInTarget.flat.curve
        try fixture.controller.setTarget(target)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 80,
            correctionHighHz: 2_000,
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )

        let preview = try fixture.controller.previewDesign(parameters: parameters)
        XCTAssertEqual(preview.effectiveCorrectionLowHz, 100, accuracy: 0.000_001)
        XCTAssertEqual(preview.effectiveCorrectionHighHz, 1_000, accuracy: 0.000_001)

        let design = try fixture.controller.generateDesign(
            parameters: parameters,
            name: "Fixture Design",
            createdAt: Date(timeIntervalSince1970: 900)
        )
        XCTAssertEqual(fixture.controller.selectedDesign?.id, design.id)
        XCTAssertEqual(fixture.controller.designs.count, 1)
        XCTAssertEqual(design.filter.leftTaps.count, 1_024)
        XCTAssertEqual(design.filter.rightTaps?.count, 1_024)
        XCTAssertEqual(design.filter.sampleRate, 48_000)

        let projectID = try XCTUnwrap(fixture.controller.project?.id)
        let persisted = try fixture.controller.store.load(projectID)
        XCTAssertEqual(persisted.target, target)
        XCTAssertEqual(persisted.selectedDesignID, design.id)
        XCTAssertEqual(persisted.designs, [design])
    }

    func testChangingTargetInvalidatesCandidateSelectionButKeepsDesignHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )
        let design = try fixture.controller.generateDesign(parameters: parameters)
        XCTAssertEqual(fixture.controller.selectedDesign?.id, design.id)

        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.gentleDownwardTilt.curve)
        XCTAssertNil(fixture.controller.selectedDesign)
        XCTAssertEqual(fixture.controller.designs.map(\.id), [design.id])
    }

    func testLowConfidenceMeasurementCannotSilentlyEnterCorrectionDesign() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let positionID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1, snr: 10),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )

        XCTAssertThrowsError(try fixture.controller.previewDesign(parameters: parameters)) { error in
            XCTAssertEqual(
                error as? RoomCorrectionProjectControllerError,
                .measurementNotDesignable(positionID: positionID, pass: .left)
            )
        }
        XCTAssertTrue(fixture.controller.designs.isEmpty)
    }

    func testDesignSelectionAndDeletionPersist() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )
        let first = try fixture.controller.generateDesign(parameters: parameters, name: "First")
        let second = try fixture.controller.generateDesign(parameters: parameters, name: "Second")
        XCTAssertEqual(fixture.controller.selectedDesign?.id, second.id)

        try fixture.controller.selectDesign(id: first.id)
        XCTAssertEqual(fixture.controller.selectedDesign?.id, first.id)
        try fixture.controller.deleteDesign(id: first.id)
        XCTAssertNil(fixture.controller.selectedDesign)
        XCTAssertEqual(fixture.controller.designs.map(\.id), [second.id])
    }


    func testAggregateMutationInvalidatesSelectedCandidateButRetainsDesignHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 1),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            smoothingOctaves: 0,
            maximumBoostDB: 3,
            maximumCutDB: 6,
            requestedTapCount: 1_024
        )
        let design = try fixture.controller.generateDesign(parameters: parameters)
        XCTAssertEqual(fixture.controller.selectedDesign?.id, design.id)

        try fixture.controller.setMeasurementWeight(id: id, weight: 2)
        XCTAssertNil(fixture.controller.selectedDesign)
        XCTAssertEqual(fixture.controller.designs.map(\.id), [design.id])
    }


    func testGeneratedDesignSnapshotsSourcePositionsRangeAndDeploymentSummary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 10),
            sweep: sweep(),
            microphone: microphone()
        )
        let secondID = try fixture.controller.retainMeasurement(
            analysis(capturedAt: 20),
            sweep: sweep(),
            microphone: microphone()
        )
        try fixture.controller.setMeasurementWeight(id: firstID, weight: 1)
        try fixture.controller.setMeasurementWeight(id: secondID, weight: 2)
        try fixture.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz: 80,
            correctionHighHz: 2_000,
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            requestedTapCount: 1_024
        )
        let design = try fixture.controller.generateDesign(
            parameters: parameters,
            name: "Deploy Fixture",
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            design.sourcePositions,
            [
                RoomCorrectionDesignSourcePosition(id: firstID, weight: 1),
                RoomCorrectionDesignSourcePosition(id: secondID, weight: 2),
            ]
        )
        XCTAssertEqual(try XCTUnwrap(design.effectiveCorrectionLowHz), 100, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(design.effectiveCorrectionHighHz), 1_000, accuracy: 0.000_001)
        let summary = try fixture.controller.deploymentSummary(for: design)
        XCTAssertEqual(summary.projectID, fixture.controller.project?.id)
        XCTAssertEqual(summary.activeDesignID, design.id)
        XCTAssertEqual(summary.positionCount, 2)
        XCTAssertEqual(summary.targetName, "Flat")
        XCTAssertEqual(summary.correctionLowHz, 100, accuracy: 0.000_001)
        XCTAssertEqual(summary.correctionHighHz, 1_000, accuracy: 0.000_001)
        XCTAssertEqual(summary.measurementDate, Date(timeIntervalSince1970: 20))
    }

    func testProfileRoomCorrectionDeploymentChangesOnlyRoomOwnedStateAndRestoresWithoutSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()
        let beforeSystem = try XCTUnwrap(profiles.selectedSystemProfile).state
        let filter = RoomCorrectionFilter(
            name: "Deployed Fixture",
            sampleRate: nil,
            leftTaps: [0.5, 0.5],
            rightTaps: [0.4, 0.6],
            declaredLatencyFrames: 0
        )
        let configuration = RoomCorrectionConfiguration(enabled: true, filter: filter)
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(),
            activeDesignID: UUID(),
            designDate: Date(timeIntervalSince1970: 200),
            positionCount: 2,
            correctionLowHz: 100,
            correctionHighHz: 1_000,
            targetName: "Flat",
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            recommendedHeadroomDB: 3.5,
            algorithmVersion: "fixture"
        )

        try profiles.replaceSelectedSystemRoomCorrection(configuration, calibrationSummary: summary)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration, configuration)
        var expectedSystem = beforeSystem
        expectedSystem.roomCorrection = configuration
        expectedSystem.roomCorrectionCalibration = summary
        XCTAssertEqual(profiles.selectedSystemProfile?.state, expectedSystem)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        restoredProfiles.restoreSelectedLayers()
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrection, configuration)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(restoredEngine.roomCorrectionConfiguration, configuration)
    }

    func testPersistentRoomCorrectionEnableTogglePreservesDeploymentAndContentPreset() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()
        let filter = RoomCorrectionFilter(
            name: "Persistent Toggle Fixture",
            sampleRate: nil,
            leftTaps: [0.5, 0.5],
            rightTaps: [0.4, 0.6],
            declaredLatencyFrames: 0
        )
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(),
            activeDesignID: UUID(),
            designDate: Date(timeIntervalSince1970: 300),
            positionCount: 3,
            correctionLowHz: 80,
            correctionHighHz: 12_000,
            targetName: "Gentle Tilt",
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            recommendedHeadroomDB: 2.5,
            algorithmVersion: "fixture"
        )
        let deployed = RoomCorrectionConfiguration(enabled: true, filter: filter)
        try profiles.replaceSelectedSystemRoomCorrection(
            deployed,
            calibrationSummary: summary
        )

        try profiles.setSelectedSystemRoomCorrectionEnabled(false)
        XCTAssertFalse(profiles.engine.roomCorrectionConfiguration.enabled)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration.filter, filter)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrection.filter, filter)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        try profiles.setSelectedSystemRoomCorrectionEnabled(true)
        XCTAssertTrue(profiles.engine.roomCorrectionConfiguration.enabled)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration.filter, filter)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrection, deployed)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        restoredProfiles.restoreSelectedLayers()
        XCTAssertEqual(restoredEngine.roomCorrectionConfiguration, deployed)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
    }

    func testProfileDeploymentPersistenceFailureRollsBackEngineAndProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR40-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        let storageURL = storageDirectory.appendingPathComponent("profiles-v1.json")
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(engine: engine, storageURL: storageURL)
        let beforeEngine = engine.roomCorrectionConfiguration
        let beforeProfile = try XCTUnwrap(profiles.selectedSystemProfile).state

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("not-a-directory".utf8).write(to: storageDirectory)
        let configuration = RoomCorrectionConfiguration(
            enabled: true,
            filter: RoomCorrectionFilter(
                name: "Rollback Fixture",
                sampleRate: nil,
                leftTaps: [1],
                rightTaps: nil,
                declaredLatencyFrames: 0
            )
        )

        XCTAssertThrowsError(
            try profiles.replaceSelectedSystemRoomCorrection(configuration, calibrationSummary: nil)
        )
        XCTAssertEqual(engine.roomCorrectionConfiguration, beforeEngine)
        XCTAssertEqual(profiles.selectedSystemProfile?.state, beforeProfile)
    }


    func testProfileBassManagementChangesOnlyPlaybackSystemAndRestoresWithRoomCorrectionIntact() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()

        let roomFilter = RoomCorrectionFilter(
            name: "PR41 Room Fixture",
            sampleRate: nil,
            leftTaps: [0.5, 0.5],
            rightTaps: [0.4, 0.6],
            declaredLatencyFrames: 0
        )
        let room = RoomCorrectionConfiguration(enabled: true, filter: roomFilter)
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(),
            activeDesignID: UUID(),
            designDate: Date(timeIntervalSince1970: 410),
            positionCount: 3,
            correctionLowHz: 80,
            correctionHighHz: 12_000,
            targetName: "PR41 Fixture Target",
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4,
            maximumCutDB: 8,
            recommendedHeadroomDB: 2,
            algorithmVersion: "pr41-fixture"
        )
        try profiles.replaceSelectedSystemRoomCorrection(room, calibrationSummary: summary)

        var crossover = BassManagementConfiguration()
        crossover.enabled = true
        crossover.frequencyHz = 92
        crossover.topology = .linkwitzRiley48
        crossover.monitorMode = .mainsOnly
        crossover.subGainDB = 2.5
        crossover.subPolarityInverted = true
        crossover.subPhaseAlignmentEnabled = true
        crossover.subPhaseAlignmentFrequencyHz = 88
        crossover.subPhaseAlignmentQ = 0.9

        try profiles.replaceSelectedSystemBassManagement(crossover)
        XCTAssertEqual(profiles.engine.bassManagementConfiguration, crossover)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.bassManagement, crossover)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration, room)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrection, room)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        try profiles.setSelectedSystemBassManagementEnabled(false)
        XCTAssertFalse(profiles.engine.bassManagementConfiguration.enabled)
        XCTAssertEqual(profiles.engine.bassManagementConfiguration.frequencyHz, 92, accuracy: 0.000_001)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        try profiles.setSelectedSystemBassManagementEnabled(true)
        XCTAssertEqual(profiles.engine.bassManagementConfiguration, crossover)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        restoredProfiles.restoreSelectedLayers()
        XCTAssertEqual(restoredEngine.bassManagementConfiguration, crossover)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.bassManagement, crossover)
        XCTAssertEqual(restoredEngine.roomCorrectionConfiguration, room)
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.roomCorrectionCalibration, summary)
    }

    func testProfileBassManagementPersistenceFailureRollsBackEngineAndProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR41-Crossover-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        let storageURL = storageDirectory.appendingPathComponent("profiles-v1.json")
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(engine: engine, storageURL: storageURL)
        let beforeEngine = engine.bassManagementConfiguration
        let beforeProfile = try XCTUnwrap(profiles.selectedSystemProfile).state

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("not-a-directory".utf8).write(to: storageDirectory)

        var crossover = BassManagementConfiguration()
        crossover.enabled = true
        crossover.frequencyHz = 110
        crossover.subGainDB = 1.5

        XCTAssertThrowsError(try profiles.replaceSelectedSystemBassManagement(crossover))
        XCTAssertEqual(engine.bassManagementConfiguration, beforeEngine)
        XCTAssertEqual(profiles.selectedSystemProfile?.state, beforeProfile)
    }

    func testMultiOutputRoutingSeparatesLogicalBusFromPhysicalDestination() throws {
        let sharedSubBus = SpeakerOutputBus.subMono
        let routes = [
            SpeakerOutputRoute(
                name: "Left Main",
                bus: .leftFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 0)
            ),
            SpeakerOutputRoute(
                name: "Right Main",
                bus: .rightFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 1)
            ),
            SpeakerOutputRoute(
                name: "Sub A",
                bus: sharedSubBus,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-b", channelIndex: 0)
            ),
            SpeakerOutputRoute(
                name: "Sub B",
                bus: sharedSubBus,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-b", channelIndex: 1)
            ),
        ]
        let configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: routes,
            synchronizationMode: .automatic,
            referenceDeviceUID: "dac-a"
        )

        XCTAssertNoThrow(try configuration.validateStructure())
        XCTAssertTrue(configuration.usesMultiplePhysicalDevices)
        XCTAssertEqual(configuration.requiredDeviceUIDs, Set(["dac-a", "dac-b"]))
        XCTAssertEqual(configuration.resolvedReferenceDeviceUID, "dac-a")
        XCTAssertEqual(configuration.enabledRoutes.filter { $0.bus == .subMono }.count, 2,
                       "One logical bus may intentionally feed multiple physical destinations")

        var duplicate = configuration
        duplicate.routes[3].destination = duplicate.routes[2].destination
        XCTAssertThrowsError(try duplicate.validateStructure()) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .duplicateDestination(deviceUID: "dac-b", channelIndex: 0)
            )
        }
    }

    func testMultiOutputRoutingValidatesPhysicalCapacityAndNativeRate() throws {
        let deviceA = AudioOutputDevice(
            deviceID: 101,
            uid: "dac-a",
            name: "Four Channel DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
            outputChannelCount: 4
        )
        let deviceB = AudioOutputDevice(
            deviceID: 202,
            uid: "dac-b",
            name: "Stereo DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        var configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 2)
                ),
                SpeakerOutputRoute(
                    name: "Right",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 3)
                ),
                SpeakerOutputRoute(
                    name: "Sub",
                    bus: .subMono,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac-b", channelIndex: 0)
                ),
            ],
            synchronizationMode: .aggregateDevice,
            referenceDeviceUID: "dac-a"
        )

        XCTAssertNoThrow(try configuration.validate(availableDevices: [deviceA, deviceB], sampleRate: 96_000))

        configuration.routes[2].destination.channelIndex = 2
        XCTAssertThrowsError(try configuration.validate(availableDevices: [deviceA, deviceB], sampleRate: 96_000)) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .outputChannelUnavailable(deviceUID: "dac-b", channelIndex: 2, channelCount: 2)
            )
        }

        configuration.routes[2].destination.channelIndex = 0
        XCTAssertThrowsError(try configuration.validate(availableDevices: [deviceA, deviceB], sampleRate: 192_000)) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .sampleRateUnsupported(deviceUID: "dac-b", sampleRate: 192_000)
            )
        }
    }

    func testPlaybackSystemPersistsMultiOutputRoutingWithoutMutatingDSPOrLegacySelectedOutput() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()
        let beforeBass = profiles.engine.bassManagementConfiguration
        let beforeRoom = profiles.engine.roomCorrectionConfiguration
        let beforeSelectedOutput = profiles.engine.routeConfiguration.selectedOutputUID

        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Main",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "main-dac", channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Right Main",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "main-dac", channelIndex: 1)
                ),
                SpeakerOutputRoute(
                    name: "Subwoofer",
                    bus: .subMono,
                    destination: PhysicalOutputEndpoint(deviceUID: "sub-dac", channelIndex: 0)
                ),
            ],
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: "main-dac"
        )

        try profiles.replaceSelectedSystemOutputRouting(routing)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.outputRouting, routing)
        XCTAssertEqual(profiles.selectedSystemOutputRouting, routing)
        XCTAssertEqual(profiles.engine.routeConfiguration.selectedOutputUID, beforeSelectedOutput,
                       "C1 stores routing intent only; transport activation comes in the next slice")
        XCTAssertEqual(profiles.engine.bassManagementConfiguration, beforeBass)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration, beforeRoom)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.outputRouting, routing)
        XCTAssertEqual(restoredProfiles.selectedSystemOutputRouting, routing)
    }

    func testPlaybackSystemRoutingPersistenceFailureRollsBackProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR41-Routing-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        let storageURL = storageDirectory.appendingPathComponent("profiles-v1.json")
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(engine: engine, storageURL: storageURL)
        let beforeProfile = try XCTUnwrap(profiles.selectedSystemProfile).state

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("not-a-directory".utf8).write(to: storageDirectory)

        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Right",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 1)
                ),
            ]
        )

        XCTAssertThrowsError(try profiles.replaceSelectedSystemOutputRouting(routing))
        XCTAssertEqual(profiles.selectedSystemProfile?.state, beforeProfile)
    }

    func testSameDeviceRoutePlanUsesOneClockDomainAndPreservesEnabledRouteOrder() throws {
        let device = AudioOutputDevice(
            deviceID: 303,
            uid: "eight-channel-dac",
            name: "Eight Channel DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
            outputChannelCount: 8
        )
        let disabled = SpeakerOutputRoute(
            name: "Unused",
            bus: .leftHigh,
            destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 7),
            enabled: false
        )
        let enabledRoutes = [
            SpeakerOutputRoute(
                name: "Left Main",
                bus: .leftFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 2)
            ),
            SpeakerOutputRoute(
                name: "Right Main",
                bus: .rightFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 3)
            ),
            SpeakerOutputRoute(
                name: "Sub",
                bus: .subMono,
                destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 6)
            ),
        ]
        let configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [enabledRoutes[0], disabled, enabledRoutes[1], enabledRoutes[2]],
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: device.uid
        )

        let plan = try configuration.makeSameDevicePlan(
            availableDevices: [device],
            sampleRate: 96_000
        )
        XCTAssertEqual(plan.deviceUID, device.uid)
        XCTAssertEqual(plan.physicalChannelCount, 8)
        XCTAssertEqual(plan.routes, enabledRoutes)
        XCTAssertEqual(plan.requiredPhysicalChannelCount, 7)
    }

    func testSameDeviceRoutePlanRejectsDisabledAndMultiDeviceConfigurations() throws {
        let first = AudioOutputDevice(
            deviceID: 401,
            uid: "dac-a",
            name: "DAC A",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 4
        )
        let second = AudioOutputDevice(
            deviceID: 402,
            uid: "dac-b",
            name: "DAC B",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let routes = [
            SpeakerOutputRoute(
                name: "Left",
                bus: .leftFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: first.uid, channelIndex: 0)
            ),
            SpeakerOutputRoute(
                name: "Right",
                bus: .rightFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: second.uid, channelIndex: 0)
            ),
        ]

        let disabled = MultiOutputRoutingConfiguration(enabled: false, routes: routes)
        XCTAssertThrowsError(
            try disabled.makeSameDevicePlan(availableDevices: [first, second], sampleRate: 48_000)
        ) { error in
            XCTAssertEqual(error as? MultiOutputRoutingError, .sameDeviceTransportRequiresEnabledRouting)
        }

        let multiple = MultiOutputRoutingConfiguration(enabled: true, routes: routes)
        XCTAssertThrowsError(
            try multiple.makeSameDevicePlan(availableDevices: [first, second], sampleRate: 48_000)
        ) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .sameDeviceTransportRequiresSingleDevice(["dac-a", "dac-b"])
            )
        }
    }
}
