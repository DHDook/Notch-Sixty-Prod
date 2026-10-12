import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabNearFieldLFTests: XCTestCase {
    private let playbackSystemID = UUID(
        uuidString: "D3000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr106-nearfield-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr106-nearfield-cal"
    )
    private let source: MultichannelCalibrationSource =
        .subwoofer(0)

    func testQualifiedRadiatorAndPortProduceLocalRelativeDiagnostics()
        throws {
        let radiator = makeProtocol(
            name: "Woofer",
            kind: .radiator,
            area: 0.035,
            distance: 0.03
        )
        let port = makeProtocol(
            name: "Port",
            kind: .port,
            area: 0.006,
            distance: 0.02
        )
        let grid = frequencyGrid()
        var session = makeSession(protocols: [radiator, port])
        session.captures =
            captures(for: radiator, frequencies: grid, gainDB: 0)
            + captures(for: port, frequencies: grid, gainDB: -4)

        let report = try SpeakerMeasurementLabNearFieldLFAnalyzer()
            .analyze(session: session)

        XCTAssertEqual(report.source, source)
        XCTAssertEqual(report.traces.count, 2)
        XCTAssertEqual(
            report.traces.map { $0.component?.kind },
            [.radiator, .port]
        )
        let relative = try XCTUnwrap(report.relativeTraces.first)
        XCTAssertTrue(
            relative.relativeMagnitudeDB.allSatisfy {
                abs($0 + 4) < 0.05
            }
        )
        XCTAssertNotNil(relative.wrappedRelativePhaseRadians)
        XCTAssertTrue(
            report.mergeAssessment.effectiveAreaMetadataComplete
        )
        XCTAssertTrue(
            report.mergeAssessment.phaseComparisonAvailable
        )
        XCTAssertFalse(
            report.mergeAssessment.canSynthesizeFarFieldComposite
        )
        XCTAssertTrue(report.measurementOnly)
        XCTAssertFalse(report.isFarFieldPrediction)
        XCTAssertFalse(report.canDeploy)
    }

    func testMissingAreaMetadataFailsMergeButStillReturnsDiagnostics()
        throws {
        let radiator = makeProtocol(
            kind: .radiator,
            area: 0.035
        )
        let port = makeProtocol(
            kind: .port,
            area: nil
        )
        let grid = frequencyGrid()
        var session = makeSession(protocols: [radiator, port])
        session.captures =
            captures(for: radiator, frequencies: grid, gainDB: 0)
            + captures(for: port, frequencies: grid, gainDB: -3)

        let report = try SpeakerMeasurementLabNearFieldLFAnalyzer()
            .analyze(session: session)

        XCTAssertEqual(report.traces.count, 2)
        XCTAssertFalse(
            report.mergeAssessment.effectiveAreaMetadataComplete
        )
        XCTAssertFalse(
            report.mergeAssessment.canSynthesizeFarFieldComposite
        )
        XCTAssertTrue(
            report.mergeAssessment.blockingReasons.contains {
                $0.localizedCaseInsensitiveContains("area")
            }
        )
    }

    func testSingleNearFieldProtocolIsUsefulButNotMergeable()
        throws {
        let radiator = makeProtocol(
            kind: .radiator,
            area: 0.035
        )
        let grid = frequencyGrid()
        var session = makeSession(protocols: [radiator])
        session.captures =
            captures(for: radiator, frequencies: grid, gainDB: 0)

        let report = try SpeakerMeasurementLabNearFieldLFAnalyzer()
            .analyze(session: session)

        XCTAssertEqual(report.traces.count, 1)
        XCTAssertTrue(report.relativeTraces.isEmpty)
        XCTAssertNotNil(report.traces[0].dominantMagnitudePeakHz)
        XCTAssertFalse(
            report.mergeAssessment.canSynthesizeFarFieldComposite
        )
    }

    func testDifferentSubwooferSourcesCannotBeMerged() throws {
        let radiator = makeProtocol(
            kind: .radiator,
            area: 0.035
        )
        var port = makeProtocol(
            kind: .port,
            area: 0.006
        )
        port.request.target = .acousticSource(.subwoofer(1))
        let grid = frequencyGrid()
        var session = makeSession(protocols: [radiator, port])
        session.captures =
            captures(for: radiator, frequencies: grid, gainDB: 0)
            + captures(
                for: port,
                frequencies: grid,
                gainDB: -3,
                sourceOverride: .subwoofer(1)
            )

        XCTAssertThrowsError(
            try SpeakerMeasurementLabNearFieldLFAnalyzer()
                .analyze(session: session)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabNearFieldLFError,
                .sourceMismatch
            )
        }
    }

    func testLowSNRAndClippingFailRepeatQualification() throws {
        let radiator = makeProtocol(
            kind: .radiator,
            area: 0.035
        )
        let grid = frequencyGrid()
        var session = makeSession(protocols: [radiator])
        session.captures = captures(
            for: radiator,
            frequencies: grid,
            gainDB: 0,
            snrDB: 20
        )
        XCTAssertThrowsError(
            try SpeakerMeasurementLabNearFieldLFAnalyzer()
                .analyze(session: session)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabNearFieldLFError,
                .unqualifiedProtocol(radiator.id)
            )
        }

        var clipped = captures(
            for: radiator,
            frequencies: grid,
            gainDB: 0
        )
        clipped[1].quality.clipped = true
        session.captures = clipped
        XCTAssertThrowsError(
            try SpeakerMeasurementLabNearFieldLFAnalyzer()
                .analyze(session: session)
        )
    }

    func testAnalysisStaysInsideConfiguredLowFrequencyBand()
        throws {
        let radiator = makeProtocol(
            kind: .radiator,
            area: 0.035
        )
        let grid = frequencyGrid()
        var session = makeSession(protocols: [radiator])
        session.captures =
            captures(for: radiator, frequencies: grid, gainDB: 0)

        var options = SpeakerMeasurementLabNearFieldLFOptions()
        options.maximumAnalysisFrequencyHz = 300
        let report = try SpeakerMeasurementLabNearFieldLFAnalyzer()
            .analyze(session: session, options: options)

        XCTAssertLessThanOrEqual(
            report.commonUsableHighHz,
            300
        )
        XCTAssertTrue(
            report.traces[0].frequenciesHz.allSatisfy { $0 <= 300 }
        )
    }

    func testComponentMetadataMustBePhysicallyFinite() throws {
        var protocolValue = makeProtocol(
            kind: .port,
            area: 0.006
        )
        protocolValue.nearFieldComponent?
            .effectiveRadiatingAreaSquareMeters = .infinity
        XCTAssertThrowsError(
            try protocolValue.validateForAcquisition()
        )
    }

    private func makeProtocol(
        name: String = "Near Field",
        kind: SpeakerMeasurementLabNearFieldComponentKind,
        area: Double?,
        distance: Double = 0.03
    ) -> SpeakerMeasurementLabProtocol {
        SpeakerMeasurementLabProtocol(
            name: name,
            request: SpeakerMeasurementLabRequest(
                mode: .subwooferNearField,
                target: .acousticSource(source),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: distance
                )
            ),
            nearFieldComponent:
                SpeakerMeasurementLabNearFieldComponent(
                    kind: kind,
                    label: name,
                    effectiveRadiatingAreaSquareMeters: area
                )
        )
    }

    private func makeSession(
        protocols: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabSession {
        SpeakerMeasurementLabSession(
            playbackSystemID: playbackSystemID,
            routingSignature: "pr106-nearfield-route",
            microphone: microphone,
            sampleRate: 48_000,
            protocols: protocols,
            captures: [],
            createdAt: Date(timeIntervalSince1970: 1_704_200_000),
            modifiedAt: Date(timeIntervalSince1970: 1_704_200_000)
        )
    }

    private func frequencyGrid() -> [Double] {
        (0..<64).map { index in
            20 * pow(
                50.0,
                Double(index) / 63.0
            )
        }
    }

    private func captures(
        for labProtocol: SpeakerMeasurementLabProtocol,
        frequencies: [Double],
        gainDB: Double,
        snrDB: Double = 55,
        sourceOverride: MultichannelCalibrationSource? = nil
    ) -> [SpeakerMeasurementLabCapture] {
        let source = sourceOverride ?? self.source
        return (0..<3).map { repeatIndex in
            SpeakerMeasurementLabCapture(
                id: UUID(),
                protocolID: labProtocol.id,
                repeatIndex: repeatIndex,
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_704_200_100 + Double(repeatIndex)
                ),
                playbackSystemID: playbackSystemID,
                routingSignature: "pr106-nearfield-route",
                microphone: microphone,
                sampleRate: 48_000,
                source: source,
                impulseResponse: [0, 0.2, 1, 0.2, 0],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: frequencies.map { frequency in
                        4 * exp(
                            -0.5
                            * pow(log2(frequency / 55) / 0.8, 2)
                        )
                        + gainDB
                        + Double(repeatIndex - 1) * 0.02
                    },
                    phaseRadians: frequencies.map { frequency in
                        0.4 * log2(frequency / 60)
                            + Double(repeatIndex - 1) * 0.004
                    }
                ),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -22,
                    capturePeakDBFS: -14,
                    estimatedNoiseFloorDBFS: -72,
                    estimatedSNRDB: snrDB,
                    sweepComplete: true,
                    directArrivalSeconds:
                        0.001
                        + Double(repeatIndex) * 0.00001,
                    usableLowHz: 20,
                    usableHighHz: 800,
                    warnings: []
                )
            )
        }
    }
}
