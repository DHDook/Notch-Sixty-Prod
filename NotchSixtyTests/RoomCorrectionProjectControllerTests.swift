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

}
