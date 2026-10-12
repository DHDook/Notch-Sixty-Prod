import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabDirectivityTests: XCTestCase {
    private let playbackSystemID = UUID(
        uuidString: "D2000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr106-directivity-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr106-directivity-cal"
    )
    private let source: MultichannelCalibrationSource =
        .speaker(.frontLeft)

    func testQualifiedOnAxisAndOffAxisProduceRelativeDirectivityTrace()
        throws {
        let onAxis = protocolFor(
            name: "0 degrees",
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        let offAxis = protocolFor(
            name: "30 degrees",
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 30
        )
        let frequencies = frequencyGrid()
        var session = makeSession(
            protocols: [onAxis, offAxis]
        )
        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0
            )
            + captures(
                for: offAxis,
                frequencies: frequencies,
                offAxisLossDB: 6
            )

        let report = try SpeakerMeasurementLabDirectivityAnalyzer()
            .analyze(
                session: session,
                onAxisProtocolID: onAxis.id
            )

        XCTAssertEqual(report.source, source)
        XCTAssertEqual(report.traces.count, 1)
        let trace = try XCTUnwrap(report.traces.first)
        XCTAssertEqual(trace.angularOffsetDegrees, 30, accuracy: 0.001)
        XCTAssertEqual(
            trace.meanRelativeMagnitudeDB,
            -6,
            accuracy: 0.05
        )
        XCTAssertTrue(
            trace.relativeMagnitudeDB.allSatisfy {
                abs($0 + 6) < 0.05
            }
        )
        XCTAssertGreaterThanOrEqual(
            trace.evidenceConfidence,
            SpeakerOptimizerMeasurementEvidenceEvaluator
                .minimumOptimizerConfidence
        )
        XCTAssertTrue(report.measurementOnly)
        XCTAssertFalse(report.isAnechoic)
        XCTAssertFalse(report.canDeploy)
    }

    func testMultipleAnglesAreSortedByAngularOffset() throws {
        let onAxis = protocolFor(
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        let fortyFive = protocolFor(
            name: "45",
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 45
        )
        let fifteen = protocolFor(
            name: "15",
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 15
        )
        let frequencies = frequencyGrid()
        var session = makeSession(
            protocols: [onAxis, fortyFive, fifteen]
        )
        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0
            )
            + captures(
                for: fortyFive,
                frequencies: frequencies,
                offAxisLossDB: 8
            )
            + captures(
                for: fifteen,
                frequencies: frequencies,
                offAxisLossDB: 2
            )

        let report = try SpeakerMeasurementLabDirectivityAnalyzer()
            .analyze(
                session: session,
                onAxisProtocolID: onAxis.id
            )
        XCTAssertEqual(
            report.traces.map(\.angularOffsetDegrees),
            [15, 45]
        )
    }

    func testDifferentSpeakerCannotBeComparedAsDirectivity() throws {
        let onAxis = protocolFor(
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        var offAxis = protocolFor(
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 30
        )
        offAxis.request.target =
            .acousticSource(.speaker(.frontRight))
        var session = makeSession(protocols: [onAxis, offAxis])
        let frequencies = frequencyGrid()
        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0
            )
            + captures(
                for: offAxis,
                frequencies: frequencies,
                offAxisLossDB: 4,
                sourceOverride: .speaker(.frontRight)
            )

        XCTAssertThrowsError(
            try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id,
                    offAxisProtocolIDs: [offAxis.id]
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabDirectivityError,
                .sourceMismatch
            )
        }
    }

    func testDistanceMismatchFailsClosed() throws {
        let onAxis = protocolFor(
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        let offAxis = protocolFor(
            mode: .wholeSpeakerOffAxis,
            distance: 1.15,
            angle: 30
        )
        var session = makeSession(protocols: [onAxis, offAxis])
        let frequencies = frequencyGrid()
        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0
            )
            + captures(
                for: offAxis,
                frequencies: frequencies,
                offAxisLossDB: 5
            )

        XCTAssertThrowsError(
            try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabDirectivityError,
                .distanceMismatch
            )
        }
    }

    func testInsufficientRepeatsAndLowSNRFailQualification() throws {
        let onAxis = protocolFor(
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        let offAxis = protocolFor(
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 30
        )
        let frequencies = frequencyGrid()
        var session = makeSession(protocols: [onAxis, offAxis])
        session.captures =
            Array(
                captures(
                    for: onAxis,
                    frequencies: frequencies,
                    offAxisLossDB: 0
                ).prefix(2)
            )
            + captures(
                for: offAxis,
                frequencies: frequencies,
                offAxisLossDB: 5
            )

        XCTAssertThrowsError(
            try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabDirectivityError,
                .unqualifiedProtocol(onAxis.id)
            )
        }

        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0,
                snrDB: 20
            )
            + captures(
                for: offAxis,
                frequencies: frequencies,
                offAxisLossDB: 5
            )

        XCTAssertThrowsError(
            try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabDirectivityError,
                .unqualifiedProtocol(onAxis.id)
            )
        }
    }

    func testClippedOffAxisRepeatFailsQualification() throws {
        let onAxis = protocolFor(
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        let offAxis = protocolFor(
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 30
        )
        let frequencies = frequencyGrid()
        var off = captures(
            for: offAxis,
            frequencies: frequencies,
            offAxisLossDB: 5
        )
        off[1].quality.clipped = true
        var session = makeSession(protocols: [onAxis, offAxis])
        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0
            ) + off

        XCTAssertThrowsError(
            try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabDirectivityError,
                .unqualifiedProtocol(offAxis.id)
            )
        }
    }

    func testIncompatibleFrequencyGridFailsClosed() throws {
        let onAxis = protocolFor(
            mode: .wholeSpeakerOnAxis,
            distance: 1.0,
            angle: 0
        )
        let offAxis = protocolFor(
            mode: .wholeSpeakerOffAxis,
            distance: 1.0,
            angle: 30
        )
        let frequencies = frequencyGrid()
        var off = captures(
            for: offAxis,
            frequencies: frequencies,
            offAxisLossDB: 4
        )
        off[0].transferFunction.frequenciesHz[10] *= 1.01
        var session = makeSession(protocols: [onAxis, offAxis])
        session.captures =
            captures(
                for: onAxis,
                frequencies: frequencies,
                offAxisLossDB: 0
            ) + off

        XCTAssertThrowsError(
            try SpeakerMeasurementLabDirectivityAnalyzer()
                .analyze(
                    session: session,
                    onAxisProtocolID: onAxis.id
                )
        )
    }

    private func protocolFor(
        name: String = "Protocol",
        mode: SpeakerMeasurementLabMode,
        distance: Double,
        angle: Double
    ) -> SpeakerMeasurementLabProtocol {
        SpeakerMeasurementLabProtocol(
            name: name,
            request: SpeakerMeasurementLabRequest(
                mode: mode,
                target: .acousticSource(source),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: distance,
                    horizontalAngleDegrees: angle
                )
            )
        )
    }

    private func makeSession(
        protocols: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabSession {
        SpeakerMeasurementLabSession(
            playbackSystemID: playbackSystemID,
            routingSignature: "pr106-directivity-route",
            microphone: microphone,
            sampleRate: 48_000,
            protocols: protocols,
            captures: [],
            createdAt: Date(timeIntervalSince1970: 1_704_100_000),
            modifiedAt: Date(timeIntervalSince1970: 1_704_100_000)
        )
    }

    private func frequencyGrid() -> [Double] {
        (0..<64).map { index in
            100 * pow(100.0, Double(index) / 63.0)
        }
    }

    private func captures(
        for labProtocol: SpeakerMeasurementLabProtocol,
        frequencies: [Double],
        offAxisLossDB: Double,
        sourceOverride: MultichannelCalibrationSource? = nil,
        snrDB: Double = 55
    ) -> [SpeakerMeasurementLabCapture] {
        let source = sourceOverride ?? self.source
        return (0..<3).map { repeatIndex in
            SpeakerMeasurementLabCapture(
                id: UUID(),
                protocolID: labProtocol.id,
                repeatIndex: repeatIndex,
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_704_100_100 + Double(repeatIndex)
                ),
                playbackSystemID: playbackSystemID,
                routingSignature: "pr106-directivity-route",
                microphone: microphone,
                sampleRate: 48_000,
                source: source,
                impulseResponse: [0, 0.1, 1, 0.2, 0],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: frequencies.map { frequency in
                        2 * exp(
                            -0.5
                            * pow(
                                log2(frequency / 2_000) / 0.8,
                                2
                            )
                        )
                        - offAxisLossDB
                        + Double(repeatIndex - 1) * 0.02
                    },
                    phaseRadians: frequencies.map { frequency in
                        0.03 * log2(frequency / 1_000)
                            + Double(repeatIndex - 1) * 0.005
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
                        0.003
                        + Double(repeatIndex) * 0.00002,
                    usableLowHz: 100,
                    usableHighHz: 10_000,
                    warnings: []
                )
            )
        }
    }
}
