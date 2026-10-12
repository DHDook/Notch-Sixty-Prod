import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabLevelDependenceTests:
    XCTestCase {
    private let playbackSystemID = UUID(
        uuidString: "D6000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr106-level-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: nil
    )
    private let source: MultichannelCalibrationSource =
        .speaker(.frontLeft)

    func testBoundedTwoLevelTransferDetectsLocalizedCompression()
        throws {
        let low = labProtocol(level: -30)
        let high = labProtocol(level: -18)
        let grid = frequencyGrid()
        var session = makeSession(protocols: [low, high])
        session.captures =
            captures(
                for: low,
                frequencies: grid,
                localizedChangeDB: 0
            )
            + captures(
                for: high,
                frequencies: grid,
                localizedChangeDB: -1.5
            )

        let report =
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: low.id,
                    secondProtocolID: high.id
                )

        XCTAssertEqual(report.excitationStepDB, 12, accuracy: 0.001)
        XCTAssertGreaterThan(report.shapeChangeRMSDB, 0.1)
        XCTAssertGreaterThan(
            report.maximumLocalizedCompressionDB,
            0.5
        )
        XCTAssertGreaterThan(
            report.materialLocalizedCompressionPointCount,
            0
        )
        XCTAssertTrue(report.measurementOnly)
        XCTAssertFalse(report.isTHDMeasurement)
        XCTAssertFalse(report.isIMDMeasurement)
        XCTAssertFalse(report.isCalibratedSPLMeasurement)
        XCTAssertFalse(report.canDeploy)
    }

    func testIdenticalNormalizedTransferIsNearLinearAcrossLevels()
        throws {
        let low = labProtocol(level: -30)
        let high = labProtocol(level: -18)
        let grid = frequencyGrid()
        var session = makeSession(protocols: [low, high])
        session.captures =
            captures(for: low, frequencies: grid)
            + captures(for: high, frequencies: grid)

        let report =
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: high.id,
                    secondProtocolID: low.id
                )
        XCTAssertEqual(
            report.broadbandTransferShiftDB,
            0,
            accuracy: 0.03
        )
        XCTAssertLessThan(report.shapeChangeRMSDB, 0.03)
        XCTAssertLessThan(
            report.maximumLocalizedCompressionDB,
            0.03
        )
    }

    func testExplicitLevelsAndBoundedStepAreRequired() throws {
        var low = labProtocol(level: -30)
        let high = labProtocol(level: -18)
        low.excitationLevelDBFS = nil
        var session = makeSession(protocols: [low, high])
        let grid = frequencyGrid()
        session.captures =
            captures(for: low, frequencies: grid)
            + captures(for: high, frequencies: grid)

        XCTAssertThrowsError(
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: low.id,
                    secondProtocolID: high.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabLevelDependenceError,
                .explicitExcitationLevelsRequired
            )
        }

        let closeLow = labProtocol(level: -24)
        let closeHigh = labProtocol(level: -21)
        session = makeSession(protocols: [closeLow, closeHigh])
        session.captures =
            captures(for: closeLow, frequencies: grid)
            + captures(for: closeHigh, frequencies: grid)
        XCTAssertThrowsError(
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: closeLow.id,
                    secondProtocolID: closeHigh.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabLevelDependenceError,
                .excitationStepOutOfRange
            )
        }
    }

    func testGeometryAndSourceMustMatch() throws {
        let low = labProtocol(level: -30)
        var high = labProtocol(level: -18)
        high.request.geometry.distanceMeters = 1.10
        var session = makeSession(protocols: [low, high])
        let grid = frequencyGrid()
        session.captures =
            captures(for: low, frequencies: grid)
            + captures(for: high, frequencies: grid)

        XCTAssertThrowsError(
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: low.id,
                    secondProtocolID: high.id
                )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabLevelDependenceError,
                .geometryMismatch
            )
        }
    }

    func testLowSNRClippingAndCaptureLevelMismatchFailClosed()
        throws {
        let low = labProtocol(level: -30)
        let high = labProtocol(level: -18)
        let grid = frequencyGrid()
        var session = makeSession(protocols: [low, high])
        session.captures =
            captures(
                for: low,
                frequencies: grid,
                snrDB: 20
            )
            + captures(for: high, frequencies: grid)
        XCTAssertThrowsError(
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: low.id,
                    secondProtocolID: high.id
                )
        )

        var clipped = captures(for: low, frequencies: grid)
        clipped[1].quality.clipped = true
        session.captures =
            clipped + captures(for: high, frequencies: grid)
        XCTAssertThrowsError(
            try SpeakerMeasurementLabLevelDependenceAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: low.id,
                    secondProtocolID: high.id
                )
        )

        var wrong = captures(for: low, frequencies: grid)
        wrong[0].excitationLevelDBFS = -29
        session.captures =
            wrong + captures(for: high, frequencies: grid)
        XCTAssertThrowsError(try session.validateStructure())
    }

    func testProtocolLevelIsPersistedAndResolvedForAcquisition()
        throws {
        let explicit = labProtocol(level: -24)
        XCTAssertEqual(
            explicit.resolvedExcitationLevelDBFS(default: -18),
            -24
        )

        var legacy = labProtocol(level: -24)
        legacy.excitationLevelDBFS = nil
        XCTAssertEqual(
            legacy.resolvedExcitationLevelDBFS(default: -18),
            -18
        )

        var invalid = labProtocol(level: -24)
        invalid.excitationLevelDBFS = -6
        XCTAssertThrowsError(try invalid.validateForAcquisition())
    }

    private func labProtocol(
        level: Double
    ) -> SpeakerMeasurementLabProtocol {
        SpeakerMeasurementLabProtocol(
            name: "On-axis \(level) dBFS",
            request: SpeakerMeasurementLabRequest(
                mode: .wholeSpeakerOnAxis,
                target: .acousticSource(source),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 1.0
                )
            ),
            excitationLevelDBFS: level
        )
    }

    private func makeSession(
        protocols: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabSession {
        SpeakerMeasurementLabSession(
            playbackSystemID: playbackSystemID,
            routingSignature: "pr106-level-route",
            microphone: microphone,
            sampleRate: 48_000,
            protocols: protocols,
            captures: [],
            createdAt: Date(timeIntervalSince1970: 1_704_600_000),
            modifiedAt: Date(timeIntervalSince1970: 1_704_600_000)
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
        localizedChangeDB: Double = 0,
        snrDB: Double = 55
    ) -> [SpeakerMeasurementLabCapture] {
        (0..<3).map { repeatIndex in
            SpeakerMeasurementLabCapture(
                id: UUID(),
                protocolID: labProtocol.id,
                repeatIndex: repeatIndex,
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_704_600_100 + Double(repeatIndex)
                ),
                playbackSystemID: playbackSystemID,
                routingSignature: "pr106-level-route",
                microphone: microphone,
                excitationLevelDBFS: labProtocol.excitationLevelDBFS,
                sampleRate: 48_000,
                source: source,
                impulseResponse: [0, 0.1, 1, 0.2, 0],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: frequencies.map { frequency in
                        let base = 2 * exp(
                            -0.5 * pow(
                                log2(frequency / 1_200) / 1.1,
                                2
                            )
                        )
                        let localized =
                            localizedChangeDB * exp(
                                -0.5 * pow(
                                    log2(frequency / 2_500) / 0.18,
                                    2
                                )
                            )
                        return base + localized
                            + Double(repeatIndex - 1) * 0.01
                    },
                    phaseRadians: frequencies.map {
                        0.02 * log2($0 / 1_000)
                            + Double(repeatIndex - 1) * 0.003
                    }
                ),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS:
                        (labProtocol.excitationLevelDBFS ?? -18) + 1,
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
