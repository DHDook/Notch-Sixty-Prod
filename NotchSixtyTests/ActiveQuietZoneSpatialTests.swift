import Foundation
import XCTest
@testable import NotchSixty

final class ActiveQuietZoneSpatialTests: XCTestCase {
    private let solver = ActiveQuietZoneSpatialPlanner()

    func testUnreferencedSequentialNoiseCannotAuthorizeSpatialANC() throws {
        let (project, calibration) = fixture()
        var invalid = calibration
        invalid.surveys[0].commonPhaseReferenceValidated = false
        XCTAssertThrowsError(try invalid.validated(against: project))
        { error in
            XCTAssertEqual(error as? ActiveQuietZoneSpatialError, .inadequatePhaseReference)
        }
    }

    func testPhaseDriftOrPoorCoherenceFailsClosed() throws {
        let (project, original) = fixture()
        var calibration = original
        calibration.surveys[0].disturbances[1].coherence = 0.60
        XCTAssertThrowsError(try calibration.validated(against: project))
        var other = original
        other.surveys[0].disturbances[1].phaseClosureRadians = 0.5
        XCTAssertThrowsError(try other.validated(against: project))
        var drift = original
        drift.surveys[0].disturbances[1].frequencyDriftHz = 0.5
        XCTAssertThrowsError(try drift.validated(against: project))
    }

    func testPhaseReferencedEqualSeatsYieldBoundedSpatialReduction() throws {
        let (project, calibration) = fixture()
        let solution = try solver.solve(
            calibration: calibration,
            project: project,
            frequencyHz: 80,
            liveAnchorDisturbance: ActiveQuietZoneComplex(real: 0.025, imaginary: 0),
            availableInjectionPeak: 0.12,
            quietZoneConfiguration: permissiveConfiguration()
        )
        XCTAssertEqual(solution.predictions.count, 2)
        XCTAssertGreaterThanOrEqual(solution.weightedReductionDB, 1)
        XCTAssertGreaterThanOrEqual(solution.worstSeatReductionDB, -0.5)
        XCTAssertLessThanOrEqual(solution.leftOutput.magnitude,
            pow(10, permissiveConfiguration().maximumPerSourceTonePeakDBFS / 20) + 1.0e-8)
    }

    func testContradictorySpatialNoiseRejectsHarmfulCandidate() throws {
        let (project, original) = fixture()
        var calibration = original
        calibration.surveys[0].disturbances[1].ratioToAnchor =
            ActiveQuietZoneComplex(real: -1, imaginary: 0)
        XCTAssertThrowsError(try solver.solve(
            calibration: calibration,
            project: project,
            frequencyHz: 80,
            liveAnchorDisturbance: ActiveQuietZoneComplex(real: 0.025, imaginary: 0),
            availableInjectionPeak: 0.12,
            quietZoneConfiguration: permissiveConfiguration()
        ))
    }

    func testSpatialInjectionEnvelopeDoesNotClaimCancellation() throws {
        let (project, calibration) = fixture()
        let result = try solver.spatialInjectionEnvelope(
            project: project,
            positionIDs: calibration.positions.map(\.id),
            anchorID: calibration.anchorPositionID,
            frequencyHz: 80,
            candidateLeft: ActiveQuietZoneComplex(real: 0.005, imaginary: 0),
            candidateRight: .zero
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.values.allSatisfy { $0.isFinite && $0 > 0 })
    }

    func testSpatialCalibrationPersistsBesideProjectWithoutMutatingProject() throws {
        let (project, calibration) = fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR95-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        try store.save(project)
        let spatial = ActiveQuietZoneSpatialStore(roomStore: store)
        try spatial.save(calibration, for: project)
        XCTAssertEqual(try spatial.load(for: project), calibration)
        XCTAssertEqual(try store.load(project.id), project)
    }

    func testSubBinToneEstimatorResolves60Point04Hz() throws {
        let rate = 48_000.0
        let count = 32_768
        let samples = (0..<count).map { frame -> Float in
            Float(0.1 * sin(2 * Double.pi * 60.04
                * Double(frame) / rate))
        }
        let refined = try ActiveQuietZoneSpatialSurveyBuilder()
            .refinedToneFrequency(
                samples: samples,
                sampleRate: rate,
                near: 60
            )
        XCTAssertEqual(refined, 60.04, accuracy: 0.06)
    }

    func testSequentialMicSurveyClosesStableAnchorAndUsesSharedPhaseClock() throws {
        let (_, configuration) = fixture()
        let captures = try makeSurveyCaptures(
            calibration: configuration,
            returnPhaseOffset: 0
        )
        let survey = try ActiveQuietZoneSpatialSurveyBuilder()
            .finish(calibration: configuration, captures: captures)
        XCTAssertTrue(survey.commonPhaseReferenceValidated)
        XCTAssertEqual(survey.disturbances.count, 2)
        let neighbor = try XCTUnwrap(survey.disturbances.first {
            $0.positionID != configuration.anchorPositionID
        })
        XCTAssertEqual(neighbor.ratioToAnchor.magnitude, 0.75, accuracy: 0.10)
        XCTAssertGreaterThanOrEqual(neighbor.coherence, 0.95)
    }

    func testSequentialMicSurveyRejectsAnchorReturnPhaseDrift() throws {
        let (_, configuration) = fixture()
        let captures = try makeSurveyCaptures(
            calibration: configuration,
            returnPhaseOffset: 0.70
        )
        XCTAssertThrowsError(try ActiveQuietZoneSpatialSurveyBuilder()
            .finish(calibration: configuration, captures: captures))
    }

    func testSequentialMicSurveyRejectsInterruptedInputClock() throws {
        let (_, configuration) = fixture()
        var captures = try makeSurveyCaptures(
            calibration: configuration,
            returnPhaseOffset: 0
        )
        captures[2].epoch = UUID()
        XCTAssertThrowsError(try ActiveQuietZoneSpatialSurveyBuilder()
            .finish(calibration: configuration, captures: captures))
    }

    private func makeSurveyCaptures(
        calibration: ActiveQuietZoneSpatialCalibration,
        returnPhaseOffset: Double
    ) throws -> [ActiveQuietZoneSpatialPhaseCapture] {
        let ids = calibration.positions.map(\.id)
        let order = [
            calibration.anchorPositionID,
            ids.first { $0 != calibration.anchorPositionID }!,
            calibration.anchorPositionID
        ]
        let rate = 48_000.0
        let frequency = 80.0
        let framesPerCapture = 32_768
        var captures: [ActiveQuietZoneSpatialPhaseCapture] = []
        let epoch = UUID()
        for (visit, positionID) in order.enumerated() {
            for repeatIndex in 0..<2 {
                let firstFrame = UInt64(
                    (visit * 2 + repeatIndex) * framesPerCapture
                )
                let level = visit == 1 ? 0.075 : 0.1
                let phase = visit == 2 ? returnPhaseOffset : 0
                let data = (0..<framesPerCapture).map { frame -> Float in
                    Float(level * sin(
                        2 * Double.pi * frequency
                        * (Double(firstFrame) + Double(frame)) / rate
                        + phase
                    ))
                }
                captures.append(
                    try ActiveQuietZoneSpatialSurveyBuilder().capture(
                        positionID: positionID,
                        epoch: epoch,
                        firstSampleIndex: firstFrame,
                        samples: data,
                        sampleRate: rate,
                        frequencyHz: frequency,
                        detectedFrequencyHz: frequency,
                        tonalProminenceDB: 30,
                        stationaryScore: 0.99
                    )
                )
            }
        }
        return captures
    }

    private func permissiveConfiguration() -> ActiveQuietZoneConfiguration {
        var config = ActiveQuietZoneConfiguration()
        config.maximumPerSourceTonePeakDBFS = -12
        config.maximumAggregateSourcePeakDBFS = -9
        config.targetReductionDB = 6
        return config
    }

    private func fixture()
        -> (RoomCorrectionProject, ActiveQuietZoneSpatialCalibration) {
        let projectID = UUID()
        let systemID = UUID()
        let a = UUID()
        let b = UUID()
        var project = RoomCorrectionProject(
            id: projectID,
            playbackSystemID: systemID,
            name: "Spatial ANC")
        project.microphone = RoomCorrectionMicrophone(
            stableID: "test-mic", displayName: "Test mic")
        project.measurements = [
            position(id: a, name: "Center"),
            position(id: b, name: "Nearby"),
        ]
        let calibration = ActiveQuietZoneSpatialCalibration(
            projectID: projectID,
            playbackSystemID: systemID,
            anchorPositionID: a,
            microphoneStableID: "test-mic",
            microphoneInputChannelIndex: 0,
            sampleRate: 48_000,
            positions: [
                ActiveQuietZoneSpatialPosition(id: a, weight: 1),
                ActiveQuietZoneSpatialPosition(id: b, weight: 1),
            ],
            surveys: [
                ActiveQuietZoneSpatialToneSurvey(
                    frequencyHz: 80,
                    capturedAt: Date(),
                    commonPhaseReferenceValidated: true,
                    disturbances: [
                        ActiveQuietZoneSpatialDisturbance(
                            positionID: a,
                            ratioToAnchor: ActiveQuietZoneComplex(real: 1, imaginary: 0),
                            coherence: 0.99,
                            phaseClosureRadians: 0.01,
                            frequencyDriftHz: 0.01),
                        ActiveQuietZoneSpatialDisturbance(
                            positionID: b,
                            ratioToAnchor: ActiveQuietZoneComplex(real: 1, imaginary: 0),
                            coherence: 0.99,
                            phaseClosureRadians: 0.01,
                            frequencyDriftHz: 0.01),
                    ])
            ])
        return (project, calibration)
    }

    private func position(id: UUID, name: String) -> RoomCorrectionMeasurementPosition {
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false,
            estimatedSNRDB: 45,
            sweepComplete: true
        )
        let impulse: [Float] = [1, 0, 0, 0]
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [0],
            impulseResponse: impulse, transferFunction: nil, quality: quality)
        return RoomCorrectionMeasurementPosition(
            id: id, name: name, included: true, weight: 1,
            sampleRate: 48_000, left: channel, right: channel)
    }
}
