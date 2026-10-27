import XCTest
@testable import NotchSixty

/// A bi-amp left speaker as routed ways: a low way (low-pass 1 kHz) and a high way (high-pass 1 kHz), both limited.
enum ProtectedWayFixtures {
    static let speakerID = UUID(uuidString:
        "11100000-0000-0000-0000-000000000001")!
    static let lowID = UUID(uuidString:
        "11100000-0000-0000-0000-000000000010")!
    static let highID = UUID(uuidString:
        "11100000-0000-0000-0000-000000000011")!

    static func lowWay() -> RoutedWay {
        RoutedWay(
            id: lowID, name: "Left Low",
            endpoint: PhysicalOutputEndpoint(
                deviceUID: "PR111 Device", channelIndex: 0),
            lowPass: .init(family: .linkwitzRiley, order: 4, cornerHz: 1_000),
            limiter: RoutingLimiter(ceilingDB: -30)
        )
    }

    static func highWay() -> RoutedWay {
        RoutedWay(
            id: highID, name: "Left High",
            endpoint: PhysicalOutputEndpoint(
                deviceUID: "PR111 Device", channelIndex: 1),
            highPass: .init(family: .linkwitzRiley, order: 4, cornerHz: 1_000),
            limiter: RoutingLimiter(ceilingDB: -30)
        )
    }

    static func routing() -> SpeakerRoutingConfiguration {
        SpeakerRoutingConfiguration(speakers: [
            RoutedSpeaker(
                id: speakerID, name: "Left", source: .program(0),
                ways: [lowWay(), highWay()])
        ])
    }
}

final class ProtectedDriverPEQRecommendationTests: XCTestCase {
    private let systemID = UUID(uuidString:
        "11100000-0000-0000-0000-000000000001")!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr111-calibrated-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr111-mic-cal"
    )
    private let analyzer = ProtectedDriverPEQRecommendationAnalyzer()

    private func provenance(
        way: RoutedWay
    ) -> SpeakerMeasurementLabRoutedWayCaptureProvenance {
        let band = way.protectedPassband(sampleRate: 48_000)
        return SpeakerMeasurementLabRoutedWayCaptureProvenance(
            way: way,
            speakerID: ProtectedWayFixtures.speakerID,
            physicalDestination: way.endpoint,
            passbandLowHz: band?.lowerBound ?? 100,
            passbandHighHz: band?.upperBound ?? 1_000,
            inputPeakDBFS: -30,
            renderedPeakDBFS: -32,
            sourceFrameCount: 4_800,
            renderedFrameCount: 16_800
        )
    }

    private func fixture(
        peakDB: Double = 5,
        snrDB: Double = 55,
        repeats: Int = 3,
        limiter: Bool = true,
        crossover: Bool = true,
        fullRange: Bool = false
    ) -> (SpeakerMeasurementLabSession, UUID) {
        var way = ProtectedWayFixtures.highWay()
        if !limiter { way.limiter = nil }
        if !crossover || fullRange { way.highPass = nil }
        if fullRange { way.lowPass = nil }
        let labProtocol = SpeakerMeasurementLabProtocol(
            name: "PR111 Protected High",
            request: SpeakerMeasurementLabRequest(
                mode: .protectedDriverNearField,
                target: .protectedRoutedWay(way.id),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 0.05
                )
            ),
            excitationLevelDBFS: -30,
            driverCaptureSource: .speaker(.frontLeft)
        )
        let grid = (0..<100).map { i in
            400.0 * pow(35, Double(i) / 99)
        }
        let receipt = provenance(way: way)
        var captures: [SpeakerMeasurementLabCapture] = []
        for repeatIndex in 0..<repeats {
            let magnitudes = grid.map { hz in
                let broadPeak = peakDB * exp(
                    -0.5 * pow(log2(hz / 4_000) / 0.23, 2)
                )
                return 0.1 * log2(hz / 2_000)
                    + broadPeak
                    + Double(repeatIndex - 1) * 0.03
            }
            let response = RoomCorrectionFrequencyResponse(
                frequenciesHz: grid,
                magnitudeDB: magnitudes,
                phaseRadians: grid.map { 0.02 * log2($0 / 1_000) }
            )
            let quality = RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -30,
                capturePeakDBFS: -20,
                estimatedNoiseFloorDBFS: -85,
                estimatedSNRDB: snrDB,
                sweepComplete: true,
                directArrivalSeconds: 0.003,
                usableLowHz: 400,
                usableHighHz: 14_000,
                warnings: []
            )
            captures.append(
                SpeakerMeasurementLabCapture(
                    protocolID: labProtocol.id,
                    repeatIndex: repeatIndex,
                    capturedAt: Date(
                        timeIntervalSince1970:
                            1_700_000_000 + Double(repeatIndex)
                    ),
                    playbackSystemID: systemID,
                    routingSignature: "pr111-active-route",
                    microphone: mic,
                    excitationLevelDBFS: -30,
                    sampleRate: 48_000,
                    source: .speaker(.frontLeft),
                    routedWayProvenance: receipt,
                    impulseResponse: [0.0, 0.3, 1.0, 0.2],
                    transferFunction: response,
                    quality: quality
                )
            )
        }
        return (
            SpeakerMeasurementLabSession(
                playbackSystemID: systemID,
                routingSignature: "pr111-active-route",
                microphone: mic,
                sampleRate: 48_000,
                protocols: [labProtocol],
                captures: captures
            ),
            labProtocol.id
        )
    }

    func testBroadRepeatStablePeakProducesBoundedCutOnlyReview() throws {
        let (session, protocolID) = fixture()
        let advice = try analyzer.recommend(
            session: session, protocolID: protocolID
        )
        XCTAssertEqual(advice.wayID, ProtectedWayFixtures.highID)
        XCTAssertEqual(advice.repeatedCaptureIDs.count, 3)
        XCTAssertFalse(advice.cuts.isEmpty)
        XCTAssertLessThanOrEqual(advice.cuts.count, 3)
        XCTAssertTrue(advice.cuts.allSatisfy {
            $0.frequencyHz > 1_500 && $0.frequencyHz < 14_000
                && $0.gainDB < 0 && $0.gainDB >= -2.5
                && $0.q > 0 && $0.q <= 1.4
        })
        XCTAssertFalse(advice.canDeploy)
        XCTAssertFalse(advice.canChangeDelayOrPolarity)
        XCTAssertFalse(advice.canAlterCrossoverOrLimiter)
        XCTAssertTrue(advice.requiresNewMeasuredVerification)
    }

    func testSmoothResponseDoesNotInventPEQ() throws {
        let (session, protocolID) = fixture(peakDB: 0)
        XCTAssertTrue(
            try analyzer.recommend(
                session: session, protocolID: protocolID
            ).cuts.isEmpty
        )
    }

    func testClippedLowSNRMissingRepeatsAndBadGridReject() throws {
        var (session, protocolID) = fixture()
        session.captures[0].quality.clipped = true
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(snrDB: 14)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(repeats: 2)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture()
        session.captures[1].transferFunction.frequenciesHz[13] *= 1.001
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testMandatoryCrossoverAndLimiterAreNeverBypassed() throws {
        var (session, protocolID) = fixture(limiter: false)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(crossover: false)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
        (session, protocolID) = fixture(fullRange: true)
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testWrongProtocolOrAlteredRouteCannotBecomeRecommendation() throws {
        var (session, protocolID) = fixture()
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: UUID()
        ))
        session.captures[0].routingSignature = "other-route"
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testUnstableRepeatsDoNotAuthorizeCuts() throws {
        var (session, protocolID) = fixture()
        session.captures[1].transferFunction.magnitudeDB =
            session.captures[1].transferFunction.magnitudeDB.map {
                $0 + 2.5
            }
        XCTAssertThrowsError(try analyzer.recommend(
            session: session, protocolID: protocolID
        ))
    }

    func testLabReportPublishesDriverCutReviewWithoutDSPDeployment() throws {
        let (session, _) = fixture(peakDB: 5)
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let summary = try XCTUnwrap(report.analysisSummaries.first {
            $0.kind == .protectedDriverOptimization
        })
        XCTAssertTrue(summary.available)
        XCTAssertTrue(summary.title.contains("Protected High"))
        XCTAssertEqual(summary.metrics.first {
            $0.name == "Driver"
        }?.value, "Left High")
        XCTAssertEqual(summary.metrics.first {
            $0.name == "Limiting"
        }?.value, "Required / preserved")
        XCTAssertEqual(summary.metrics.first {
            $0.name == "Deployment"
        }?.value, "Never · review only")
        XCTAssertTrue(summary.metrics.contains {
            $0.name.hasPrefix("Cut ")
                && $0.value.contains("dB, Q")
        })
        XCTAssertTrue(summary.warnings.contains {
            $0.contains("no live Apply")
        })
        XCTAssertFalse(report.canDeploy)

        let csv = try SpeakerMeasurementLabReportExporter()
            .csvData(report)
        let csvText = try XCTUnwrap(
            String(data: csv, encoding: .utf8)
        )
        XCTAssertTrue(csvText.contains("protectedDriverOptimization"))
        XCTAssertTrue(csvText.contains("review only"))
        XCTAssertFalse(csvText.contains("impulseResponse"))
        let json = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let jsonText = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(jsonText.contains("protectedDriverOptimization"))
        XCTAssertFalse(jsonText.contains("transferFunction"))
    }

    func testLabReportSurfacesInconclusiveDriverOnMissingRepeats() throws {
        var (session, _) = fixture()
        session.captures.removeLast()
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let matching = report.analysisSummaries.filter {
            $0.kind == .protectedDriverOptimization
        }
        XCTAssertEqual(matching.count, 1)
        XCTAssertFalse(matching[0].available)
        XCTAssertTrue(matching[0].metrics.isEmpty)
        XCTAssertFalse(matching[0].warnings.isEmpty)
        XCTAssertFalse(report.canDeploy)
    }

    func testLabReportSurfacedProtectedDriverWithoutFabricatingBands() throws {
        let (session, _) = fixture(peakDB: 0)
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let advice = try XCTUnwrap(report.analysisSummaries.first {
            $0.kind == .protectedDriverOptimization
        })
        XCTAssertTrue(advice.available)
        XCTAssertEqual(advice.metrics.first {
            $0.name == "Suggested cuts"
        }?.value, "0")
        XCTAssertFalse(advice.metrics.contains {
            $0.name.hasPrefix("Cut ")
        })
        XCTAssertFalse(report.canDeploy)
    }

    func testReportRejectsUnprotectedLimiterCaptureEvenIfGridLooksGood() throws {
        let (session, _) = fixture(limiter: false)
        XCTAssertThrowsError(
            try SpeakerMeasurementLabReportBuilder().build(
                session: session
            )
        )
    }


    private func timingFixture(
        relativeArrivalMilliseconds: Double = 0.8,
        secondResidualPhaseRadians: Double = 0,
        referenceDriftMilliseconds: Double = 0.02,
        includeReference: Bool = true
    ) -> (SpeakerMeasurementLabSession, UUID, UUID) {
        let lowProtocol = SpeakerMeasurementLabProtocol(
            name: "PR111 Left Low timing",
            request: SpeakerMeasurementLabRequest(
                mode: .protectedDriverNearField,
                target: .protectedRoutedWay(ProtectedWayFixtures.lowID),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 0.05
                )
            ),
            excitationLevelDBFS: -30,
            driverCaptureSource: .speaker(.frontLeft)
        )
        let highProtocol = SpeakerMeasurementLabProtocol(
            name: "PR111 Left High timing",
            request: SpeakerMeasurementLabRequest(
                mode: .protectedDriverNearField,
                target: .protectedRoutedWay(ProtectedWayFixtures.highID),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 0.05
                )
            ),
            excitationLevelDBFS: -30,
            driverCaptureSource: .speaker(.frontLeft)
        )
        let grid = (0..<120).map { i in
            200.0 * pow(50.0, Double(i) / 119)
        }
        let lowReceipt = provenance(way: ProtectedWayFixtures.lowWay())
        let highReceipt = provenance(way: ProtectedWayFixtures.highWay())
        var captures: [SpeakerMeasurementLabCapture] = []
        for (labProtocol, receipt, arrival, phase) in [
            (
                lowProtocol,
                lowReceipt,
                0.010,
                0.0
            ),
            (
                highProtocol,
                highReceipt,
                0.010 + relativeArrivalMilliseconds / 1_000,
                secondResidualPhaseRadians
            ),
        ] {
            for repeatIndex in 0..<3 {
                let referenceArrival = 0.002
                    + Double(repeatIndex)
                        * referenceDriftMilliseconds / 2_000
                let shared = includeReference
                    ? SpeakerMeasurementLabSharedClockReferenceEvidence(
                        inputDeviceUID: mic.deviceUID,
                        inputChannelIndex: 1,
                        outputReferenceDeviceUID: "PR111 Device",
                        sampleRate: 48_000,
                        directArrivalSeconds: referenceArrival,
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: grid,
                                magnitudeDB: grid.map { _ in
                                    Double(repeatIndex - 1) * 0.01
                                },
                                phaseRadians: grid.map { _ in
                                    Double(repeatIndex - 1) * 0.004
                                }
                            ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false,
                            playbackPeakDBFS: -30,
                            capturePeakDBFS: -8,
                            estimatedNoiseFloorDBFS: -85,
                            estimatedSNRDB: 65,
                            sweepComplete: true,
                            directArrivalSeconds: referenceArrival,
                            usableLowHz: 200,
                            usableHighHz: 10_000,
                            warnings: []
                        )
                    ) : nil
                let transferPhase = grid.map { frequency in
                    // The measured phase includes the acoustic time-of-flight.
                    // Slice 3 removes that delay slope before residual
                    // polarity comparison.
                    2 * Double.pi * frequency * arrival
                        + phase
                        + Double(repeatIndex - 1) * 0.002
                }
                captures.append(
                    SpeakerMeasurementLabCapture(
                        protocolID: labProtocol.id,
                        repeatIndex: repeatIndex,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_710_000_000
                                + Double(repeatIndex)
                        ),
                        playbackSystemID: systemID,
                        routingSignature: "pr111-active-route",
                        microphone: mic,
                        excitationLevelDBFS: -30,
                        sampleRate: 48_000,
                        source: .speaker(.frontLeft),
                        routedWayProvenance: receipt,
                        sharedClockReference: shared,
                        impulseResponse: [0, 0.1, 1, 0.2, 0],
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: grid,
                                magnitudeDB: grid.map { frequency in
                                    -1.5
                                        - 0.15
                                            * abs(log2(frequency / 1_000))
                                        + Double(repeatIndex - 1) * 0.01
                                },
                                phaseRadians: transferPhase
                            ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false,
                            playbackPeakDBFS: -30,
                            capturePeakDBFS: -18,
                            estimatedNoiseFloorDBFS: -85,
                            estimatedSNRDB: 58,
                            sweepComplete: true,
                            directArrivalSeconds:
                                arrival
                                    + Double(repeatIndex) * 0.00001,
                            usableLowHz: 250,
                            usableHighHz: 8_000,
                            warnings: []
                        )
                    )
                )
            }
        }
        return (
            SpeakerMeasurementLabSession(
                playbackSystemID: systemID,
                routingSignature: "pr111-active-route",
                microphone: mic,
                sharedClockReferenceConfiguration:
                    includeReference
                    ? SpeakerMeasurementLabSharedClockReferenceConfiguration(
                        inputDeviceUID: mic.deviceUID,
                        inputChannelIndex: 1,
                        outputReferenceDeviceUID: "PR111 Device",
                        minimumSNRDB: 35
                    )
                    : nil,
                sampleRate: 48_000,
                protocols: [lowProtocol, highProtocol],
                captures: captures
            ),
            lowProtocol.id,
            highProtocol.id
        )
    }

    func testSharedReferenceTimingSuggestsBoundedDelayForEarlierDriver() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let result = try ProtectedDriverTimingRecommendationAnalyzer()
            .recommend(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(result.firstWayID, ProtectedWayFixtures.lowID)
        XCTAssertEqual(result.secondWayID, ProtectedWayFixtures.highID)
        XCTAssertEqual(result.crossoverFrequencyHz, 1_000, accuracy: 0.001)
        XCTAssertEqual(result.relativeArrivalMilliseconds, 0.8, accuracy: 0.03)
        XCTAssertEqual(result.delayWayID, ProtectedWayFixtures.lowID)
        XCTAssertEqual(
            try XCTUnwrap(result.additionalDelayMilliseconds),
            0.8,
            accuracy: 0.03
        )
        XCTAssertEqual(result.polarityHypothesis, .retainCurrent)
        XCTAssertTrue(result.measurementOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.canChangeCrossoverOrLimiter)
        XCTAssertTrue(result.requiresCombinedDriverVerification)
    }

    func testResidualPiPhaseProducesOnlyPolarityHypothesis() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.2,
            secondResidualPhaseRadians: .pi
        )
        let result = try ProtectedDriverTimingRecommendationAnalyzer()
            .recommend(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(
            result.polarityHypothesis,
            .invertComparedDriver
        )
        XCTAssertFalse(result.canDeploy)
    }

    func testMissingOrUnstableSharedReferenceFailsClosed() throws {
        var (session, lowID, highID) = timingFixture(
            includeReference: false
        )
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
        (session, lowID, highID) = timingFixture(
            referenceDriftMilliseconds: 0.7
        )
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        ) {
            XCTAssertEqual(
                $0 as? ProtectedDriverTimingRecommendationError,
                .referencePathUnstable
            )
        }
    }

    func testLargeArrivalMismatchDoesNotInventSafeDelayAdjustment() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 3.5
        )
        let result = try ProtectedDriverTimingRecommendationAnalyzer()
            .recommend(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertNil(result.delayWayID)
        XCTAssertNil(result.additionalDelayMilliseconds)
        XCTAssertFalse(result.canDeploy)
    }

    func testCrossSpeakerOrUnprotectedPairCannotProduceTimingAdvice() throws {
        var (session, lowID, highID) = timingFixture()
        session.protocols[1].request.target =
            .protectedRoutedWay(UUID())
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
        (session, lowID, highID) = timingFixture()
        session.captures[3].routedWayProvenance?.physicalDestination
            .deviceUID = "other-device"
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }


    func testLabReportPublishesProtectedTimingAsReviewOnly() throws {
        let (session, _, _) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let timing = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverTiming
            }
        )
        XCTAssertTrue(timing.available)
        XCTAssertTrue(timing.title.contains("Left Low"))
        XCTAssertTrue(timing.title.contains("Left High"))
        XCTAssertEqual(
            timing.metrics.first { $0.name == "Deployment" }?.value,
            "Never · review only"
        )
        XCTAssertTrue(timing.metrics.contains {
            $0.name == "Delay hypothesis"
                && $0.value.contains("Left Low")
        })
        XCTAssertTrue(timing.metrics.contains {
            $0.name == "Polarity hypothesis"
                && $0.value.contains("Retain")
        })
        XCTAssertTrue(timing.warnings.contains {
            $0.contains("Combined-driver crossover summation")
        })
        XCTAssertFalse(report.canDeploy)

        let csv = try SpeakerMeasurementLabReportExporter()
            .csvData(report)
        let text = try XCTUnwrap(String(data: csv, encoding: .utf8))
        XCTAssertTrue(text.contains("protectedDriverTiming"))
        XCTAssertTrue(text.contains("Never"))
        let json = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let jsonText = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(jsonText.contains("protectedDriverTiming"))
        XCTAssertFalse(jsonText.contains("impulseResponse"))
    }

    func testLabReportShowsUnqualifiedTimingWhenReferenceIsUnstable() throws {
        let (session, _, _) = timingFixture(
            referenceDriftMilliseconds: 0.7
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let timing = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverTiming
            }
        )
        XCTAssertFalse(timing.available)
        XCTAssertTrue(timing.metrics.isEmpty)
        XCTAssertTrue(timing.warnings.contains {
            $0.localizedCaseInsensitiveContains("reference")
        })
        XCTAssertFalse(report.canDeploy)
    }

    func testNonAdjacentWaysCannotBecomeATimingPair() throws {
        // A high way whose high-pass sits at 4 kHz does not meet the low way's 1 kHz low-pass.
        var (session, lowID, highID) = timingFixture()
        for index in session.captures.indices
        where session.captures[index].routedWayProvenance?.way.id
            == ProtectedWayFixtures.highID {
            session.captures[index].routedWayProvenance?.way
                .highPass?.cornerHz = 4_000
        }
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }

    func testPairsOnDifferentSpeakersCannotBecomeATimingPair() throws {
        var (session, lowID, highID) = timingFixture()
        for index in session.captures.indices
        where session.captures[index].routedWayProvenance?.way.id
            == ProtectedWayFixtures.highID {
            session.captures[index].routedWayProvenance?.speakerID = UUID()
        }
        XCTAssertThrowsError(
            try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }

    func testCrossoverSumModelSelectsBoundedDelayWhenItReducesCancellation()
        throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let result = try ProtectedDriverCrossoverSumModelAnalyzer()
            .analyze(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(result.firstWayID, ProtectedWayFixtures.lowID)
        XCTAssertEqual(result.secondWayID, ProtectedWayFixtures.highID)
        XCTAssertEqual(result.bestHypothesis, .addBoundedDelay)
        XCTAssertEqual(
            try XCTUnwrap(result.modeledAdditionalDelayMilliseconds),
            0.8,
            accuracy: 0.03
        )
        XCTAssertFalse(result.modeledInvertsComparedDriver)
        XCTAssertGreaterThan(result.modeledDeficitReductionDB, 0.25)
        XCTAssertLessThan(
            result.candidateMeanCoherenceDeficitDB,
            result.currentMeanCoherenceDeficitDB
        )
        XCTAssertTrue(result.measurementOnly)
        XCTAssertTrue(result.modelOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.combinedDriverCaptureVerified)
        XCTAssertTrue(result.requiresPhysicalCombinedDriverCapture)
    }

    func testCrossoverSumModelCanCompareCombinedDelayAndPolarityHypothesis()
        throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 0.2,
            secondResidualPhaseRadians: .pi
        )
        let result = try ProtectedDriverCrossoverSumModelAnalyzer()
            .analyze(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertTrue(result.modeledInvertsComparedDriver)
        XCTAssertTrue(
            result.bestHypothesis == .invertComparedDriver
                || result.bestHypothesis
                    == .addDelayAndInvertComparedDriver
        )
        XCTAssertGreaterThan(result.modeledDeficitReductionDB, 0.25)
        XCTAssertFalse(result.canDeploy)
    }

    func testCrossoverSumModelWithoutQualifiedReferenceFailsClosed() throws {
        let (session, lowID, highID) = timingFixture(
            includeReference: false
        )
        XCTAssertThrowsError(
            try ProtectedDriverCrossoverSumModelAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        ) {
            XCTAssertEqual(
                $0 as? ProtectedDriverCrossoverSumModelError,
                .timingEvidenceUnavailable
            )
        }
    }

    func testLargeTimingMismatchDoesNotBecomeModeledSafeAdjustment() throws {
        let (session, lowID, highID) = timingFixture(
            relativeArrivalMilliseconds: 3.5
        )
        let result = try ProtectedDriverCrossoverSumModelAnalyzer()
            .analyze(
                session: session,
                firstProtocolID: lowID,
                secondProtocolID: highID
            )
        XCTAssertEqual(result.bestHypothesis, .retainCurrent)
        XCTAssertNil(result.modeledAdditionalDelayMilliseconds)
        XCTAssertFalse(result.modeledInvertsComparedDriver)
        XCTAssertEqual(result.modeledDeficitReductionDB, 0, accuracy: 0.0001)
        XCTAssertFalse(result.canDeploy)
    }

    func testCrossoverSumModelRejectsMismatchedComplexGrid() throws {
        var (session, lowID, highID) = timingFixture()
        session.captures[3]
            .sharedClockReference?
            .transferFunction.frequenciesHz[15] *= 1.001
        XCTAssertThrowsError(
            try ProtectedDriverCrossoverSumModelAnalyzer()
                .analyze(
                    session: session,
                    firstProtocolID: lowID,
                    secondProtocolID: highID
                )
        )
    }


    func testLabReportPublishesCrossoverSumModelAsModelOnly() throws {
        let (session, _, _) = timingFixture(
            relativeArrivalMilliseconds: 0.8
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let summary = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverCrossoverSum
            }
        )
        XCTAssertTrue(summary.available)
        XCTAssertEqual(
            summary.metrics.first {
                $0.name == "Combined-driver capture"
            }?.value,
            "REQUIRED · not yet verified"
        )
        XCTAssertEqual(
            summary.metrics.first {
                $0.name == "Deployment"
            }?.value,
            "Never · model only"
        )
        XCTAssertTrue(summary.metrics.contains {
            $0.name == "Modeled reduction"
                && $0.value.contains("dB")
        })
        XCTAssertTrue(summary.warnings.contains {
            $0.contains("MODEL ONLY")
        })
        XCTAssertTrue(summary.warnings.contains {
            $0.contains("combined-driver crossover capture")
        })
        XCTAssertFalse(report.canDeploy)

        let json = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let jsonText = try XCTUnwrap(
            String(data: json, encoding: .utf8)
        )
        XCTAssertTrue(
            jsonText.contains("protectedDriverCrossoverSum")
        )
        XCTAssertFalse(jsonText.contains("impulseResponse"))
    }

    func testLabReportCrossoverSumIsUnavailableWithoutTimingEvidence() throws {
        let (session, _, _) = timingFixture(
            includeReference: false
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let summary = try XCTUnwrap(
            report.analysisSummaries.first {
                $0.kind == .protectedDriverCrossoverSum
            }
        )
        XCTAssertFalse(summary.available)
        XCTAssertTrue(summary.metrics.isEmpty)
        XCTAssertFalse(summary.warnings.isEmpty)
        XCTAssertFalse(report.canDeploy)
    }

    // MARK: - Goldens at the standard rates

    private func at(
        _ rate: Double, _ s: SpeakerMeasurementLabSession
    ) -> SpeakerMeasurementLabSession {
        var s = s
        s.sampleRate = rate
        for i in s.captures.indices {
            s.captures[i].sampleRate = rate
            s.captures[i].sharedClockReference?.sampleRate = rate
        }
        return s
    }

    /// Values recorded from the bus analysers before they were ported (E8 A2c); the way analysers must reproduce them
    /// at every standard rate: 0.01 dB, 0.1 degrees, one sample.
    func testWayAnalysersMatchLegacyGoldensAtStandardRates() throws {
        let rates: [Double] = [
            44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800,
            384_000,
        ]
        for rate in rates {
            let oneSampleMs = 1_000 / rate
            let (peqSession, peqID) = fixture(peakDB: 5)
            let peq = try analyzer.recommend(
                session: at(rate, peqSession), protocolID: peqID)
            XCTAssertEqual(peq.passbandLowHz, 1_500, accuracy: 0.01, "\(rate)")
            XCTAssertEqual(peq.passbandHighHz, 14_000, accuracy: 0.01)
            XCTAssertEqual(peq.cuts.count, 1, "\(rate)")
            let cut = try XCTUnwrap(peq.cuts.first)
            XCTAssertEqual(cut.frequencyHz, 3_983.3218, accuracy: 0.5)
            XCTAssertEqual(cut.gainDB, -2.3187, accuracy: 0.01, "\(rate)")
            XCTAssertEqual(cut.q, 1.4, accuracy: 0.001)

            // (arrival ms, residual phase, golden relative phase, delay, deficit, candidate, hypothesis, inverts)
            let cases: [(Double, Double, Double, Double, Double, Double,
                         ProtectedDriverTimingPolarityHypothesis,
                         ProtectedDriverCrossoverSumHypothesis, Bool)] = [
                (0.8, 0.0, 0.0, 0.8, 3.0607, 0.0,
                 .retainCurrent, .addBoundedDelay, false),
                (0.2, Double.pi, Double.pi, 0.2, 4.6453, 0.0,
                 .invertComparedDriver, .addDelayAndInvertComparedDriver,
                 true),
            ]
            for c in cases {
                let (ts, lo, hi) = timingFixture(
                    relativeArrivalMilliseconds: c.0,
                    secondResidualPhaseRadians: c.1)
                let session = at(rate, ts)
                let t = try ProtectedDriverTimingRecommendationAnalyzer()
                    .recommend(
                        session: session, firstProtocolID: lo,
                        secondProtocolID: hi)
                XCTAssertEqual(t.crossoverFrequencyHz, 1_000, accuracy: 0.001)
                XCTAssertEqual(
                    t.relativeArrivalMilliseconds, c.0,
                    accuracy: oneSampleMs, "\(rate)")
                let phaseError = abs(
                    abs(t.wrappedRelativePhaseAtCrossoverRadians) - c.2)
                XCTAssertLessThan(phaseError * 180 / .pi, 0.1, "\(rate)")
                XCTAssertEqual(t.delayWayID, ProtectedWayFixtures.lowID)
                XCTAssertEqual(
                    try XCTUnwrap(t.additionalDelayMilliseconds), c.3,
                    accuracy: oneSampleMs)
                XCTAssertEqual(t.polarityHypothesis, c.6)

                let m = try ProtectedDriverCrossoverSumModelAnalyzer()
                    .analyze(
                        session: session, firstProtocolID: lo,
                        secondProtocolID: hi)
                XCTAssertEqual(
                    m.modeledDeficitReductionDB, c.4, accuracy: 0.01,
                    "\(rate)")
                XCTAssertEqual(m.bestHypothesis, c.7)
                XCTAssertEqual(m.modeledInvertsComparedDriver, c.8)
                XCTAssertEqual(
                    try XCTUnwrap(m.modeledAdditionalDelayMilliseconds),
                    c.3, accuracy: oneSampleMs)
            }
        }
    }

    // MARK: - Commissioning on ways

    private func legacyFields() -> (
        BassManagementConfiguration, MultiOutputRoutingConfiguration
    ) {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.frequencyHz = 1_000
        bass.physicalOutputMode = .biAmp
        let routes = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    id: ProtectedWayFixtures.lowID, name: "Left Low",
                    bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 0)),
                SpeakerOutputRoute(
                    id: ProtectedWayFixtures.highID, name: "Left High",
                    bus: .leftHigh,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 1)),
            ],
            referenceDeviceUID: "PR111 Device")
        return (bass, routes)
    }

    private func commissioningProfile(
        normalizing session: inout SpeakerMeasurementLabSession,
        withRouting: Bool = true
    ) -> PlaybackSystemProfile {
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 0)),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "PR111 Device", channelIndex: 1)),
            ],
            referenceDeviceUID: "PR111 Device")
        let signature = output.multichannelCalibrationRoutingSignature
        session.routingSignature = signature
        for index in session.captures.indices {
            session.captures[index].routingSignature = signature
        }
        let (bass, routes) = legacyFields()
        return PlaybackSystemProfile(
            id: systemID,
            name: "PR111 Commissioning",
            state: PlaybackSystemState(
                bassManagement: bass,
                outputRouting: routes,
                outputDeviceProfile: output,
                speakerRouting: withRouting
                    ? ProtectedWayFixtures.routing() : nil))
    }

    func testCommissioningChangesOnlyTheTargetWayAndLegacyFieldsStayIdentical()
        throws {
        var (session, _) = fixture(peakDB: 5)
        let profile = commissioningProfile(normalizing: &session)
        let draft = try ProtectedDriverCommissioningPlanner().draft(
            profile: profile, session: session,
            createdAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(draft.affectedWayIDs, [ProtectedWayFixtures.highID])
        XCTAssertEqual(draft.rollbackPlaybackSystemState, profile.state)
        XCTAssertFalse(draft.canApply)
        XCTAssertFalse(draft.canDeploy)
        XCTAssertFalse(draft.readyForApproval)
        XCTAssertFalse(draft.physicalCombinedDriverVerificationComplete)

        let before = ProtectedWayFixtures.routing().speakers[0].ways
        let after = draft.previewRouting.speakers[0].ways
        XCTAssertEqual(after[0], before[0])
        XCTAssertGreaterThan(after[1].eq.count, before[1].eq.count)
        var stripped = after[1]
        stripped.eq = before[1].eq
        XCTAssertEqual(stripped, before[1])
        XCTAssertTrue(after[1].eq.allSatisfy {
            $0.type == 0 && $0.gainDB < 0 && $0.gainDB >= -2.5 && $0.q <= 1.4
        })

        // The legacy bus fields in the rollback state are byte-identical to the profile's.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(draft.rollbackPlaybackSystemState.outputRouting),
            try encoder.encode(profile.state.outputRouting))
        XCTAssertEqual(
            try encoder.encode(draft.rollbackPlaybackSystemState.bassManagement),
            try encoder.encode(profile.state.bassManagement))
    }

    func testCommissioningRetainsModelOnlyTimingReviewsForAdjacentWays()
        throws {
        var (session, _, _) = timingFixture(relativeArrivalMilliseconds: 0.8)
        let profile = commissioningProfile(normalizing: &session)
        let draft = try ProtectedDriverCommissioningPlanner().draft(
            profile: profile, session: session)
        let review = try XCTUnwrap(draft.timingReviews.first)
        XCTAssertEqual(review.firstWayID, ProtectedWayFixtures.lowID)
        XCTAssertEqual(review.secondWayID, ProtectedWayFixtures.highID)
        XCTAssertEqual(review.crossoverFrequencyHz, 1_000, accuracy: 0.001)
        XCTAssertTrue(draft.timingReviews.allSatisfy {
            !$0.combinedDriverCaptureVerified
        })
        XCTAssertTrue(draft.evidenceSummary.contains("PR112 hardware acceptance"))
    }

    func testCommissioningDriftAndIdentityFailClosed() throws {
        var (session, _) = fixture(peakDB: 5)
        let profile = commissioningProfile(normalizing: &session)
        let planner = ProtectedDriverCommissioningPlanner()
        let draft = try planner.draft(profile: profile, session: session)
        XCTAssertNoThrow(try planner.validateCurrentState(profile, against: draft))

        var drifted = profile
        drifted.state.speakerRouting?.speakers[0].ways[1].trimDB = -3
        XCTAssertThrowsError(
            try planner.validateCurrentState(drifted, against: draft)
        ) { XCTAssertEqual($0 as? ProtectedDriverCommissioningError, .currentStateDrift) }
        // The measured way changed after the capture: no draft.
        XCTAssertThrowsError(
            try planner.draft(profile: drifted, session: session)
        ) { XCTAssertEqual($0 as? ProtectedDriverCommissioningError, .protectedStateDrift) }

        var other = profile
        other.id = UUID()
        XCTAssertThrowsError(try planner.draft(profile: other, session: session))
    }

    func testCommissioningFailsWhenTheWayHasNoEQCapacity() throws {
        var (session, _) = fixture(peakDB: 5)
        var profile = commissioningProfile(normalizing: &session)
        // Fill the way, then re-measure it as filled so the drift check passes.
        let full = (0..<Int(N60_PEQ_MAX_SECTIONS)).map {
            RoutingEQSection(
                type: 0, frequencyHz: 200 + Double($0) * 50,
                gainDB: -0.5, q: 1)
        }
        profile.state.speakerRouting?.speakers[0].ways[1].eq = full
        for i in session.captures.indices {
            session.captures[i].routedWayProvenance?.way.eq = full
        }
        XCTAssertThrowsError(
            try ProtectedDriverCommissioningPlanner().draft(
                profile: profile, session: session)
        ) { XCTAssertEqual($0 as? ProtectedDriverCommissioningError, .insufficientEQCapacity) }
    }

    func testCommissioningDraftStoreRoundTripAndTamperBlock() throws {
        var (session, _) = fixture(peakDB: 5)
        let profile = commissioningProfile(normalizing: &session)
        let draft = try ProtectedDriverCommissioningPlanner().draft(
            profile: profile, session: session,
            createdAt: Date(timeIntervalSince1970: 200))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProtectedDriverCommissioningDraftStore(rootDirectory: root)
        try store.save(draft)
        XCTAssertEqual(try store.load(session.id), draft)

        var hidden = draft
        hidden.affectedWayIDs = []
        XCTAssertThrowsError(try store.save(hidden))
        var applying = draft
        applying.schemaVersion = 99
        XCTAssertThrowsError(try applying.validated())
        var extra = draft
        extra.previewRouting.speakers[0].ways[0].trimDB = 3
        XCTAssertThrowsError(try extra.validated())
    }

    // MARK: - Drafts saved against the legacy buses

    private func writeLegacyDraft(
        _ draft: ProtectedDriverLegacyCommissioningDraft,
        into store: ProtectedDriverCommissioningDraftStore
    ) throws {
        try FileManager.default.createDirectory(
            at: store.rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(draft).write(to: store.url(for: draft.sessionID))
    }

    func testBusKeyedDraftsMapToTheirWaysAndUnmappableOnesAreKeptNotApplicable()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProtectedDriverCommissioningDraftStore(rootDirectory: root)
        let (bass, routes) = legacyFields()
        let state = PlaybackSystemState(
            bassManagement: bass, outputRouting: routes)

        let mappable = ProtectedDriverLegacyCommissioningDraft(
            schemaVersion: 1, id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            playbackSystemID: systemID, sessionID: UUID(),
            rollbackPlaybackSystemState: state,
            affectedBuses: [.leftHigh, .leftLow])
        try writeLegacyDraft(mappable, into: store)
        guard case .legacy(let loaded)? = try store.entry(mappable.sessionID)
        else { return XCTFail("expected a legacy draft") }
        XCTAssertEqual(loaded.mappedWayIDs, [
            ProtectedWayFixtures.highID, ProtectedWayFixtures.lowID,
        ])
        XCTAssertTrue(loaded.isApplicable)
        XCTAssertNil(try store.load(mappable.sessionID))

        // A bus with no enabled route cannot be mapped: the draft is kept, shown as not applicable.
        let unmappable = ProtectedDriverLegacyCommissioningDraft(
            schemaVersion: 1, id: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            playbackSystemID: systemID, sessionID: UUID(),
            rollbackPlaybackSystemState: state,
            affectedBuses: [.rightHigh])
        try writeLegacyDraft(unmappable, into: store)
        guard case .legacy(let kept)? = try store.entry(unmappable.sessionID)
        else { return XCTFail("the unmappable draft must be kept") }
        XCTAssertNil(kept.mappedWayIDs)
        XCTAssertFalse(kept.isApplicable)
        XCTAssertTrue(kept.statusText.hasPrefix("Not applicable"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.url(for: unmappable.sessionID).path))

        // Drafts with no routing at all are also not applicable.
        let bare = ProtectedDriverLegacyCommissioningDraft(
            schemaVersion: 1, id: UUID(), createdAt: Date(),
            playbackSystemID: systemID, sessionID: UUID(),
            rollbackPlaybackSystemState: PlaybackSystemState(),
            affectedBuses: [.leftHigh])
        XCTAssertFalse(bare.isApplicable)
    }

    // MARK: - No protected-driver target from legacy fields alone

    func testLegacyFieldsWithoutRoutingOfferNoProtectedDriverTarget() throws {
        var (session, _) = fixture(peakDB: 5)
        let profile = commissioningProfile(
            normalizing: &session, withRouting: false)
        // biAmp, two enabled bus routes and driver processing are all present; none of it is read.
        XCTAssertEqual(profile.state.bassManagement.physicalOutputMode, .biAmp)
        XCTAssertThrowsError(
            try ProtectedDriverCommissioningPlanner().draft(
                profile: profile, session: session)
        ) { XCTAssertEqual($0 as? ProtectedDriverCommissioningError, .protectedStateDrift) }

        let request = SpeakerMeasurementLabRequest(
            mode: .protectedDriverNearField,
            target: .protectedRoutedWay(ProtectedWayFixtures.highID),
            geometry: .init(distanceMeters: 0.05))
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: LiveNChannelOutputRoutePlan(
                programLayout: .stereo,
                orderedDeviceUIDs: ["PR111 Device"],
                referenceDeviceUID: "PR111 Device",
                physicalChannelCount: 2,
                programPhysicalChannels: [0, 1],
                subwooferPhysicalChannels: [],
                subwooferCount: 0,
                bassManagementEnabled: false,
                speakerCalibrations: [:],
                subwooferCalibrations: [],
                speakerOptimizerPEQ: [:]),
            multiOutputRouting: profile.state.outputRouting,
            speakerDriverProcessing: nil,
            speakerRouting: profile.state.speakerRouting)
        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertFalse(plan.blockReasons.isEmpty)
    }
}
