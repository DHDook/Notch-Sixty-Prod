import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabSessionTests: XCTestCase {
    private let playbackSystemID = UUID(
        uuidString: "D1000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr106-lab-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr106-lab-cal"
    )

    func testSessionSupportsOnlyCurrentlySafeAcquisitionModes() throws {
        XCTAssertNoThrow(
            try makeProtocol(
                mode: .wholeSpeakerOnAxis,
                target: .acousticSource(.speaker(.frontLeft)),
                distance: 1.0
            ).validateForAcquisition()
        )
        XCTAssertNoThrow(
            try makeProtocol(
                mode: .wholeSpeakerOffAxis,
                target: .acousticSource(.speaker(.frontLeft)),
                distance: 1.0,
                horizontalAngle: 30
            ).validateForAcquisition()
        )
        XCTAssertNoThrow(
            try makeProtocol(
                mode: .subwooferNearField,
                target: .acousticSource(.subwoofer(0)),
                distance: 0.05
            ).validateForAcquisition()
        )

        XCTAssertThrowsError(
            try makeProtocol(
                mode: .protectedDriverNearField,
                target: .protectedDriverBus(.leftLow),
                distance: 0.05
            ).validateForAcquisition()
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabSessionError,
                .unsupportedAcquisitionMode(.protectedDriverNearField)
            )
        }
    }

    func testGuidedStepsFinishAllStationaryRepeatsBeforeNextProtocol() throws {
        let first = makeProtocol(
            name: "Left On Axis",
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            distance: 1.0
        )
        let second = makeProtocol(
            name: "Left 30 Degrees",
            mode: .wholeSpeakerOffAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            distance: 1.0,
            horizontalAngle: 30
        )
        let session = makeSession(protocols: [first, second])
        let steps = try SpeakerMeasurementLabSessionOrchestrator()
            .steps(for: session)

        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(
            Array(steps.prefix(3).map(\.labProtocol.id)),
            Array(repeating: first.id, count: 3)
        )
        XCTAssertEqual(
            Array(steps.suffix(3).map(\.labProtocol.id)),
            Array(repeating: second.id, count: 3)
        )
        XCTAssertEqual(
            Array(steps.prefix(3).map(\.repeatIndex)),
            [0, 1, 2]
        )
        XCTAssertTrue(steps[0].instruction.contains("1.00 m"))
        XCTAssertTrue(steps[3].instruction.contains("30.00°"))
    }

    func testAnalyzedCaptureBuilderKeepsImpulseButNotRawSweepModel() throws {
        let labProtocol = makeProtocol(
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            distance: 1.0
        )
        let session = makeSession(protocols: [labProtocol])
        let step = try XCTUnwrap(
            SpeakerMeasurementLabSessionOrchestrator()
                .nextPendingStep(for: session)
        )
        let channel = makeChannel(
            capturedAt: Date(timeIntervalSince1970: 1_704_000_000)
        )
        let capture = try SpeakerMeasurementLabCaptureBuilder().build(
            analyzed: channel,
            session: session,
            step: step
        )

        XCTAssertEqual(capture.protocolID, labProtocol.id)
        XCTAssertEqual(capture.repeatIndex, 0)
        XCTAssertEqual(capture.source, .speaker(.frontLeft))
        XCTAssertEqual(capture.impulseResponse, channel.impulseResponse)
        XCTAssertEqual(
            capture.transferFunction,
            channel.transferFunction
        )
    }

    func testAppendEnforcesRepeatSequenceAndCaptureIdentity() throws {
        let labProtocol = makeProtocol(
            mode: .wholeSpeakerOnAxis,
            target: .acousticSource(.speaker(.frontLeft)),
            distance: 1.0
        )
        let session = makeSession(protocols: [labProtocol])
        let orchestrator = SpeakerMeasurementLabSessionOrchestrator()
        let step = try XCTUnwrap(
            orchestrator.nextPendingStep(for: session)
        )
        var capture = try SpeakerMeasurementLabCaptureBuilder().build(
            analyzed: makeChannel(),
            session: session,
            step: step
        )

        var wrong = capture
        wrong.repeatIndex = 1
        XCTAssertThrowsError(
            try orchestrator.appending(
                wrong,
                to: session,
                for: step
            )
        )

        let updated = try orchestrator.appending(
            capture,
            to: session,
            for: step
        )
        XCTAssertEqual(updated.captures.count, 1)
        XCTAssertEqual(
            try orchestrator.progress(for: updated)
                .completedCaptureCount,
            1
        )

        capture.id = UUID()
        XCTAssertThrowsError(
            try orchestrator.appending(
                capture,
                to: updated,
                for: step
            )
        )
    }

    func testRetryLatestCaptureReturnsProtocolToThatRepeat() throws {
        let labProtocol = makeProtocol(
            mode: .subwooferNearField,
            target: .acousticSource(.subwoofer(0)),
            distance: 0.05
        )
        var session = makeSession(protocols: [labProtocol])
        let orchestrator = SpeakerMeasurementLabSessionOrchestrator()

        for repeatIndex in 0..<3 {
            let step = SpeakerMeasurementLabSessionStep(
                labProtocol: labProtocol,
                repeatIndex: repeatIndex
            )
            let capture = try SpeakerMeasurementLabCaptureBuilder()
                .build(
                    analyzed: makeChannel(
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_704_000_000
                                + Double(repeatIndex)
                        )
                    ),
                    session: session,
                    step: step
                )
            session = try orchestrator.appending(
                capture,
                to: session,
                for: step
            )
        }

        XCTAssertTrue(try orchestrator.progress(for: session).complete)
        let retried = try orchestrator.retryLatestCapture(
            in: session,
            protocolID: labProtocol.id
        )
        let progress = try orchestrator.progress(for: retried)
        XCTAssertFalse(progress.complete)
        XCTAssertEqual(progress.nextStep?.repeatIndex, 2)
    }

    func testLabSessionPersistenceRoundTripKeepsGeometryAndCompactAnalysis()
        throws {
        let labProtocol = makeProtocol(
            mode: .wholeSpeakerOffAxis,
            target: .acousticSource(.speaker(.frontRight)),
            distance: 1.25,
            horizontalAngle: 45
        )
        var session = makeSession(protocols: [labProtocol])
        let step = try XCTUnwrap(
            SpeakerMeasurementLabSessionOrchestrator()
                .nextPendingStep(for: session)
        )
        let capture = try SpeakerMeasurementLabCaptureBuilder().build(
            analyzed: makeChannel(
                capturedAt: Date(
                    timeIntervalSince1970: 1_704_000_100
                )
            ),
            session: session,
            step: step
        )
        session = try SpeakerMeasurementLabSessionOrchestrator()
            .appending(
                capture,
                to: session,
                for: step,
                modifiedAt: Date(
                    timeIntervalSince1970: 1_704_000_200
                )
            )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PR106-Lab-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SpeakerMeasurementLabSessionStore(
            rootDirectory: root
        )
        try store.save(session)
        let loaded = try XCTUnwrap(store.load(session.id))
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(
            loaded.protocols[0].request.geometry.distanceMeters,
            1.25
        )
        XCTAssertEqual(
            loaded.protocols[0].request.geometry
                .horizontalAngleDegrees,
            45
        )

        let json = try XCTUnwrap(
            String(
                data: Data(contentsOf: store.url(for: session.id)),
                encoding: .utf8
            )
        )
        XCTAssertTrue(json.contains("impulseResponse"))
        XCTAssertFalse(json.contains("rawCapture"))
    }

    private func makeProtocol(
        name: String = "Lab Protocol",
        mode: SpeakerMeasurementLabMode,
        target: SpeakerMeasurementLabTarget,
        distance: Double,
        horizontalAngle: Double = 0
    ) -> SpeakerMeasurementLabProtocol {
        SpeakerMeasurementLabProtocol(
            name: name,
            request: SpeakerMeasurementLabRequest(
                mode: mode,
                target: target,
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: distance,
                    horizontalAngleDegrees: horizontalAngle
                )
            )
        )
    }

    private func makeSession(
        protocols: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabSession {
        SpeakerMeasurementLabSession(
            playbackSystemID: playbackSystemID,
            routingSignature: "pr106-lab-route",
            microphone: microphone,
            sampleRate: 48_000,
            protocols: protocols,
            captures: [],
            createdAt: Date(timeIntervalSince1970: 1_704_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_704_000_000)
        )
    }

    private func makeChannel(
        capturedAt: Date = Date(
            timeIntervalSince1970: 1_704_000_000
        )
    ) -> RoomCorrectionChannelMeasurement {
        let frequencies = (0..<32).map { index in
            100 * pow(
                100.0,
                Double(index) / 31.0
            )
        }
        return RoomCorrectionChannelMeasurement(
            capturedAt: capturedAt,
            rawCapture: [0, 0.1, 0.2, 0.1, 0],
            impulseResponse: [0, 0.2, 1, 0.3, 0.1],
            transferFunction: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: frequencies.map {
                    2 * exp(
                        -0.5
                        * pow(log2($0 / 2_000) / 0.8, 2)
                    )
                },
                phaseRadians: frequencies.map {
                    0.03 * log2($0 / 1_000)
                }
            ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -20,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -70,
                estimatedSNRDB: 55,
                sweepComplete: true,
                directArrivalSeconds: 0.003,
                usableLowHz: 100,
                usableHighHz: 10_000,
                warnings: []
            )
        )
    }
}
