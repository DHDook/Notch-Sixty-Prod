import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabCoherentTimingTests: XCTestCase {
    private let playbackID = UUID(
        uuidString: "D9000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let pairID = UUID(
        uuidString: "D9100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "coherent-interface",
        inputChannelIndex: 0,
        calibrationFingerprint: "coherent-cal"
    )
    private let main: MultichannelCalibrationSource =
        .speaker(.frontLeft)
    private let sub: MultichannelCalibrationSource =
        .subwoofer(0)

    func testLinkedMainSubPairWithStableReferenceAuthenticatesTiming()
        throws {
        let session = try makeSession()
        let report = try SpeakerMeasurementLabCoherentTimingAnalyzer()
            .analyze(session: session, coherentPairID: pairID)

        XCTAssertTrue(report.crossSourceClockProvenanceAuthenticated)
        XCTAssertTrue(report.measurementOnly)
        XCTAssertFalse(report.canDeploy)
        XCTAssertFalse(report.canMutateDSP)
        XCTAssertEqual(report.main, main)
        XCTAssertEqual(report.subwoofer, sub)
        XCTAssertEqual(
            report.relativeArrivalMilliseconds,
            3.0,
            accuracy: 0.08
        )
        XCTAssertLessThan(
            report.referenceArrivalSpreadMilliseconds,
            0.1
        )
        XCTAssertLessThan(
            report.referenceMagnitudeRepeatabilityRMSDB,
            0.1
        )
        XCTAssertGreaterThan(report.referencePhaseConsistency, 0.999)

        let index = try XCTUnwrap(
            report.frequenciesHz.indices.min {
                abs(report.frequenciesHz[$0] - 80)
                    < abs(report.frequenciesHz[$1] - 80)
            }
        )
        let expected = atan2(
            sin(-2 * Double.pi * report.frequenciesHz[index] * 0.003),
            cos(-2 * Double.pi * report.frequenciesHz[index] * 0.003)
        )
        XCTAssertEqual(
            report.wrappedRelativePhaseRadians[index],
            expected,
            accuracy: 0.08
        )
    }

    func testReferenceArrivalDriftFailsClosed() throws {
        var session = try makeSession()
        let subProtocol = try XCTUnwrap(
            session.protocols.first { $0.coherentLeg == .subwoofer }
        )
        for index in session.captures.indices
            where session.captures[index].protocolID == subProtocol.id {
            var reference = try XCTUnwrap(
                session.captures[index].sharedClockReference
            )
            reference.directArrivalSeconds += 0.001
            reference.quality.directArrivalSeconds =
                reference.directArrivalSeconds
            session.captures[index].sharedClockReference = reference
        }
        XCTAssertNoThrow(try session.validateStructure())
        XCTAssertThrowsError(
            try SpeakerMeasurementLabCoherentTimingAnalyzer()
                .analyze(session: session, coherentPairID: pairID)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabCoherentTimingError,
                .referencePathUnstable
            )
        }
    }

    func testReferenceMagnitudeOrPhaseInstabilityFailsClosed() throws {
        var session = try makeSession()
        let last = session.captures.indices.last!
        var magnitudeReference = try XCTUnwrap(
            session.captures[last].sharedClockReference
        )
        magnitudeReference.transferFunction.magnitudeDB =
            magnitudeReference.transferFunction.magnitudeDB.map {
                $0 + 3
            }
        session.captures[last].sharedClockReference =
            magnitudeReference
        XCTAssertThrowsError(
            try SpeakerMeasurementLabCoherentTimingAnalyzer()
                .analyze(session: session, coherentPairID: pairID)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabCoherentTimingError,
                .referencePathUnstable
            )
        }

        session = try makeSession()
        let phaseIndex = session.captures.indices.last!
        var phaseReference = try XCTUnwrap(
            session.captures[phaseIndex].sharedClockReference
        )
        phaseReference.transferFunction.phaseRadians =
            try XCTUnwrap(
                phaseReference.transferFunction.phaseRadians
            ).map {
                $0 + Double.pi
            }
        session.captures[phaseIndex].sharedClockReference =
            phaseReference
        XCTAssertThrowsError(
            try SpeakerMeasurementLabCoherentTimingAnalyzer()
                .analyze(session: session, coherentPairID: pairID)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabCoherentTimingError,
                .referencePathUnstable
            )
        }
    }

    func testCoherentSessionRequiresReferenceAndMatchedPairGeometryLevel()
        throws {
        let pair = coherentProtocols()
        var noReference = makeEmptySession(protocols: pair)
        noReference.sharedClockReferenceConfiguration = nil
        XCTAssertThrowsError(try noReference.validateStructure()) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabSessionError,
                .coherentPairInvalid
            )
        }

        var badGeometry = makeEmptySession(protocols: pair)
        badGeometry.protocols[1].request.geometry.distanceMeters = 2.1
        XCTAssertThrowsError(try badGeometry.validateStructure())

        var badLevel = makeEmptySession(protocols: pair)
        badLevel.protocols[1].excitationLevelDBFS = -30
        XCTAssertThrowsError(try badLevel.validateStructure())
    }

    func testCapabilityStillBlocksCoherentRequestWithoutLinkedReferenceLeg()
        throws {
        let request = coherentProtocols()[0].request
        let route = routePlan()
        let blocked = try SpeakerMeasurementLabCapabilityPlanner().plan(
            request,
            routePlan: route,
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )
        XCTAssertFalse(blocked.canStartMeasurement)
        XCTAssertTrue(blocked.blockReasons.contains {
            if case .authenticatedSharedClockRequired = $0 {
                return true
            }
            return false
        })

        let allowedLeg = try SpeakerMeasurementLabCapabilityPlanner()
            .plan(
                request,
                routePlan: route,
                multiOutputRouting: nil,
                speakerDriverProcessing: nil,
                coherentLeg: .main,
                sharedClockReferenceAvailable: true
            )
        XCTAssertTrue(allowedLeg.canStartMeasurement)
        XCTAssertFalse(allowedLeg.phaseReferenceAuthenticated)
        XCTAssertFalse(allowedLeg.canDeploy)
    }

    private func makeSession() throws -> SpeakerMeasurementLabSession {
        let protocols = coherentProtocols()
        var session = makeEmptySession(protocols: protocols)
        let frequencies = (0..<96).map { index in
            30 * pow(10.0, Double(index) / 95.0)
        }
        for labProtocol in protocols {
            let acousticArrival =
                labProtocol.coherentLeg == .main ? 0.010 : 0.013
            for repeatIndex in 0..<3 {
                let referenceArrival =
                    0.002 + Double(repeatIndex) * 0.00001
                let reference = referenceEvidence(
                    frequencies: frequencies,
                    arrival: referenceArrival,
                    repeatIndex: repeatIndex
                )
                session.captures.append(
                    SpeakerMeasurementLabCapture(
                        protocolID: labProtocol.id,
                        repeatIndex: repeatIndex,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_704_500_000
                                + Double(
                                    (labProtocol.coherentLeg == .main ? 0 : 10)
                                    + repeatIndex
                                )
                        ),
                        playbackSystemID: playbackID,
                        routingSignature: "coherent-route",
                        microphone: mic,
                        excitationLevelDBFS: -24,
                        sampleRate: 48_000,
                        source: labProtocol.captureSource!,
                        sharedClockReference: reference,
                        impulseResponse: [0, 0.1, 1, 0.2, 0],
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: frequencies,
                                magnitudeDB: frequencies.map { frequency in
                                    let base = labProtocol.coherentLeg == .main
                                        ? -2.0 : -4.0
                                    return base
                                        - 0.2 * pow(log2(frequency / 80), 2)
                                        + Double(repeatIndex - 1) * 0.01
                                },
                                phaseRadians: frequencies.map { _ in
                                    0.02 * Double(repeatIndex - 1)
                                }
                            ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false,
                            playbackPeakDBFS: -24,
                            capturePeakDBFS: -14,
                            estimatedNoiseFloorDBFS: -75,
                            estimatedSNRDB: 60,
                            sweepComplete: true,
                            directArrivalSeconds:
                                acousticArrival
                                + Double(repeatIndex) * 0.00001,
                            usableLowHz: 30,
                            usableHighHz: 300,
                            warnings: []
                        )
                    )
                )
            }
        }
        try session.validateStructure()
        return session
    }

    private func referenceEvidence(
        frequencies: [Double],
        arrival: Double,
        repeatIndex: Int
    ) -> SpeakerMeasurementLabSharedClockReferenceEvidence {
        SpeakerMeasurementLabSharedClockReferenceEvidence(
            inputDeviceUID: mic.deviceUID,
            inputChannelIndex: 1,
            outputReferenceDeviceUID: "coherent-output",
            sampleRate: 48_000,
            directArrivalSeconds: arrival,
            transferFunction: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: frequencies.map { _ in
                    Double(repeatIndex - 1) * 0.01
                },
                phaseRadians: frequencies.map { _ in
                    0.005 * Double(repeatIndex - 1)
                }
            ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -24,
                capturePeakDBFS: -8,
                estimatedNoiseFloorDBFS: -75,
                estimatedSNRDB: 65,
                sweepComplete: true,
                directArrivalSeconds: arrival,
                usableLowHz: 30,
                usableHighHz: 300,
                warnings: []
            )
        )
    }

    private func coherentProtocols()
        -> [SpeakerMeasurementLabProtocol] {
        let request = SpeakerMeasurementLabRequest(
            mode: .coherentMainsSubTiming,
            target: .sourcePair(main: main, subwoofer: sub),
            geometry: SpeakerMeasurementLabGeometry(
                distanceMeters: 2.0
            ),
            repeatCount: 3
        )
        return [
            SpeakerMeasurementLabProtocol(
                name: "Main coherent leg",
                request: request,
                excitationLevelDBFS: -24,
                coherentPairID: pairID,
                coherentLeg: .main
            ),
            SpeakerMeasurementLabProtocol(
                name: "Sub coherent leg",
                request: request,
                excitationLevelDBFS: -24,
                coherentPairID: pairID,
                coherentLeg: .subwoofer
            ),
        ]
    }

    private func makeEmptySession(
        protocols: [SpeakerMeasurementLabProtocol]
    ) -> SpeakerMeasurementLabSession {
        SpeakerMeasurementLabSession(
            playbackSystemID: playbackID,
            routingSignature: "coherent-route",
            microphone: mic,
            sharedClockReferenceConfiguration:
                SpeakerMeasurementLabSharedClockReferenceConfiguration(
                    inputDeviceUID: mic.deviceUID,
                    inputChannelIndex: 1,
                    outputReferenceDeviceUID: "coherent-output",
                    minimumSNRDB: 35
                ),
            sampleRate: 48_000,
            protocols: protocols,
            captures: []
        )
    }

    private func routePlan() -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["coherent-output"],
            referenceDeviceUID: "coherent-output",
            physicalChannelCount: 3,
            programPhysicalChannels: [0, 1]
                + Array(
                    repeating: UInt32.max,
                    count: Int(N60_MAX_PROGRAM_CHANNELS) - 2
                ),
            subwooferPhysicalChannels: [2]
                + Array(
                    repeating: UInt32.max,
                    count: Int(N60_MAX_SUBWOOFER_OUTPUTS) - 1
                ),
            subwooferCount: 1,
            bassManagementEnabled: true,
            speakerCalibrations: [:],
            subwooferCalibrations: Array(
                repeating: nil,
                count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
            )
        )
    }
}
