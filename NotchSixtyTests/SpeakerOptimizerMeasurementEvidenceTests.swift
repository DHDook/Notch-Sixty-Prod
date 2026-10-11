import XCTest
@testable import NotchSixty

final class SpeakerOptimizerMeasurementEvidenceTests: XCTestCase {
    private let playbackSystemID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let positionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr103-test-microphone",
        inputChannelIndex: 0,
        calibrationFingerprint: "calibration-sha256"
    )
    private let source: MultichannelCalibrationSource = .speaker(.frontLeft)

    func testThreeStableRepeatsAreOptimizerReady() throws {
        let set = makeSet(captures: [
            makeCapture(offsetDB: 0.0, arrivalSeconds: 0.01000, phaseOffset: 0.00),
            makeCapture(offsetDB: 0.2, arrivalSeconds: 0.01005, phaseOffset: 0.02),
            makeCapture(offsetDB: -0.2, arrivalSeconds: 0.01010, phaseOffset: -0.02),
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertTrue(report.optimizerReady, report.blockingReasons.joined(separator: "\n"))
        XCTAssertEqual(report.groupReports.count, 1)
        let group = try XCTUnwrap(report.groupReports.first)
        XCTAssertEqual(group.repeatCount, 3)
        XCTAssertEqual(group.minimumSNRDB, 50)
        XCTAssertLessThan(try XCTUnwrap(group.magnitudeRepeatabilityRMSDB), 0.2)
        XCTAssertEqual(try XCTUnwrap(group.arrivalSpreadMilliseconds), 0.1, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(group.phaseConsistency), 0.99)
        XCTAssertGreaterThan(report.confidence, 0.85)
    }

    func testTwoRepeatsFailClosed() throws {
        let set = makeSet(captures: [
            makeCapture(),
            makeCapture(offsetDB: 0.1),
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("at least 3")
        })
    }

    func testLowSNRAndClippingFailClosed() throws {
        var lowSNR = makeCapture(snrDB: 25)
        var clipped = makeCapture(offsetDB: 0.1)
        clipped.quality.clipped = true
        let set = makeSet(captures: [
            lowSNR,
            clipped,
            makeCapture(offsetDB: -0.1),
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("SNR")
        })
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("clipped")
        })
    }

    func testMagnitudeRepeatabilityRegressionFailsClosed() throws {
        let set = makeSet(captures: [
            makeCapture(offsetDB: -4),
            makeCapture(offsetDB: 0),
            makeCapture(offsetDB: 4),
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        let rms = try XCTUnwrap(report.groupReports.first?.magnitudeRepeatabilityRMSDB)
        XCTAssertGreaterThan(rms, SpeakerOptimizerMeasurementEvidenceEvaluator.maximumMagnitudeRepeatabilityRMSDB)
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("magnitude repeatability")
        })
    }

    func testArrivalInstabilityFailsClosed() throws {
        let set = makeSet(captures: [
            makeCapture(arrivalSeconds: 0.0100),
            makeCapture(arrivalSeconds: 0.0101),
            makeCapture(arrivalSeconds: 0.0110),
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        XCTAssertGreaterThan(
            try XCTUnwrap(report.groupReports.first?.arrivalSpreadMilliseconds),
            SpeakerOptimizerMeasurementEvidenceEvaluator.maximumArrivalSpreadMilliseconds
        )
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("arrival")
        })
    }

    func testPhaseConsistencyIsCircularAndFailsForIncoherentRepeats() throws {
        let twoPiOverThree = 2.0 * Double.pi / 3.0
        let set = makeSet(captures: [
            makeCapture(phaseOffset: 0),
            makeCapture(phaseOffset: twoPiOverThree),
            makeCapture(phaseOffset: -twoPiOverThree),
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        XCTAssertLessThan(
            try XCTUnwrap(report.groupReports.first?.phaseConsistency),
            0.01
        )
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("phase consistency")
        })
    }

    func testIdentityContinuityRejectsMixedRoutingOrMicrophone() throws {
        var wrongRoute = makeCapture(offsetDB: 0.1)
        wrongRoute.routingSignature = "other-route"

        var wrongMic = makeCapture(offsetDB: -0.1)
        wrongMic.microphone = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "different-microphone",
            inputChannelIndex: 0,
            calibrationFingerprint: "calibration-sha256"
        )

        let set = makeSet(captures: [
            makeCapture(),
            wrongRoute,
            wrongMic,
        ])

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("identity changed")
        })
    }

    func testMissingPlannedSourceCoverageFailsClosed() throws {
        let right: MultichannelCalibrationSource = .speaker(.frontRight)
        var set = makeSet(captures: [
            makeCapture(),
            makeCapture(offsetDB: 0.1),
            makeCapture(offsetDB: -0.1),
        ])
        set.plannedSources = [source, right]

        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set)

        XCTAssertFalse(report.optimizerReady)
        XCTAssertEqual(report.groupReports.count, 2)
        XCTAssertTrue(report.groupReports.contains {
            $0.source == right && $0.repeatCount == 0 && !$0.optimizerReady
        })
    }

    func testCompactionRetainsAnalyzedEvidenceWithoutRawSweepStorage() throws {
        let response = makeResponse(offsetDB: 0, phaseOffset: 0)
        let measurement = MultichannelCalibrationMeasurement(
            id: UUID(),
            seatID: positionID,
            source: source,
            sampleRate: 48_000,
            channel: RoomCorrectionChannelMeasurement(
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                rawCapture: [0.1, 0.2, 0.3],
                impulseResponse: [1, 0.1],
                transferFunction: response,
                quality: makeQuality()
            )
        )

        let compact = try SpeakerOptimizerMeasurementCapture(
            compacting: measurement,
            playbackSystemID: playbackSystemID,
            routingSignature: "stable-route",
            microphone: microphone
        )

        XCTAssertEqual(compact.id, measurement.id)
        XCTAssertEqual(compact.positionID, positionID)
        XCTAssertEqual(compact.source, source)
        XCTAssertEqual(compact.response, response)
        XCTAssertEqual(compact.quality, measurement.channel.quality)

        let encoded = try JSONEncoder().encode(compact)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("rawCapture"))
        XCTAssertFalse(json.contains("impulseResponse"))
    }

    func testBaselineCandidateVerificationRolesRemainDistinct() throws {
        let captures = [
            makeCapture(),
            makeCapture(offsetDB: 0.1),
            makeCapture(offsetDB: -0.1),
        ]
        let baseline = makeSet(role: .baseline, captures: captures)
        let candidate = makeSet(role: .candidate, captures: captures)
        let verification = makeSet(role: .verification, captures: captures)

        XCTAssertNotEqual(baseline.id, candidate.id)
        XCTAssertNotEqual(candidate.id, verification.id)
        XCTAssertEqual(
            [baseline.role, candidate.role, verification.role],
            [.baseline, .candidate, .verification]
        )
    }


    func testWholeSpeakerCanReuseExistingTargetedCalibrationTransport() throws {
        let routePlan = makeRoutePlan()
        let plan = SpeakerOptimizerMeasurementTransportPlanner().plan(
            target: .acousticSource(.speaker(.frontLeft)),
            routePlan: routePlan,
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )

        XCTAssertTrue(plan.canStartMeasurement)
        XCTAssertTrue(plan.usesExistingTargetedCalibrationTransport)
        XCTAssertTrue(plan.preservesMandatoryProtection)
        XCTAssertEqual(plan.physicalOutputChannelIndex, 0)
        XCTAssertNil(plan.blockReason)
    }

    func testSubwooferCanReuseExistingTargetedCalibrationTransport() throws {
        let routePlan = makeRoutePlan()
        let plan = SpeakerOptimizerMeasurementTransportPlanner().plan(
            target: .acousticSource(.subwoofer(0)),
            routePlan: routePlan,
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )

        XCTAssertTrue(plan.canStartMeasurement)
        XCTAssertEqual(plan.physicalOutputChannelIndex, 2)
    }

    func testProtectedDriverBusFailsClosedInsteadOfRawPhysicalSweep() throws {
        let plan = SpeakerOptimizerMeasurementTransportPlanner().plan(
            target: .protectedDriverBus(.leftLow),
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )

        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertFalse(plan.usesExistingTargetedCalibrationTransport)
        XCTAssertFalse(plan.preservesMandatoryProtection)
        XCTAssertEqual(
            plan.blockReason,
            .protectedDriverPathRequired(.leftLow)
        )
    }

    func testActiveSplitDriverRoutingBlocksDirectCalibrationReuse() throws {
        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Low",
                    bus: .leftLow,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr103-output",
                        channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Left High",
                    bus: .leftHigh,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr103-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let plan = SpeakerOptimizerMeasurementTransportPlanner().plan(
            target: .acousticSource(.speaker(.frontLeft)),
            routePlan: makeRoutePlan(),
            multiOutputRouting: routing,
            speakerDriverProcessing: nil
        )

        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertEqual(plan.blockReason, .activeCrossoverRoutingPresent)
    }

    func testConfiguredDriverLimiterBlocksDirectCalibrationReuse() throws {
        let protection = SpeakerDriverProcessingConfiguration(
            buses: [
                SpeakerDriverBusProcessingConfiguration(
                    bus: .leftFullRange,
                    limiterEnabled: true,
                    limiterThresholdDBFS: -6
                ),
            ]
        )
        let plan = SpeakerOptimizerMeasurementTransportPlanner().plan(
            target: .acousticSource(.speaker(.frontLeft)),
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: protection
        )

        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertEqual(plan.blockReason, .configuredLimiterWouldBeBypassed)
    }

    func testUnavailablePhysicalRouteFailsClosed() throws {
        var routePlan = makeRoutePlan()
        routePlan = LiveNChannelOutputRoutePlan(
            programLayout: routePlan.programLayout,
            orderedDeviceUIDs: routePlan.orderedDeviceUIDs,
            referenceDeviceUID: routePlan.referenceDeviceUID,
            physicalChannelCount: routePlan.physicalChannelCount,
            programPhysicalChannels: [UInt32.max, 1] + Array(
                repeating: UInt32.max,
                count: routePlan.programPhysicalChannels.count - 2
            ),
            subwooferPhysicalChannels: routePlan.subwooferPhysicalChannels,
            subwooferCount: routePlan.subwooferCount,
            bassManagementEnabled: routePlan.bassManagementEnabled,
            speakerCalibrations: routePlan.speakerCalibrations,
            subwooferCalibrations: routePlan.subwooferCalibrations
        )

        let plan = SpeakerOptimizerMeasurementTransportPlanner().plan(
            target: .acousticSource(.speaker(.frontLeft)),
            routePlan: routePlan,
            multiOutputRouting: nil,
            speakerDriverProcessing: nil
        )

        XCTAssertFalse(plan.canStartMeasurement)
        XCTAssertNotNil(plan.blockReason)
    }


    func testSessionPlanIsPositionMajorToMinimizeMicrophoneMoves() throws {
        let secondPosition = SpeakerOptimizerMeasurementPosition(
            name: "Second Seat"
        )
        var set = makeSet(captures: [])
        set.positions.append(secondPosition)
        set.plannedSources = [
            .speaker(.frontLeft),
            .speaker(.frontRight),
        ]

        let orchestrator = try SpeakerOptimizerMeasurementSessionOrchestrator()
        let steps = try orchestrator.steps(for: set)

        XCTAssertEqual(steps.count, 12)
        XCTAssertTrue(steps[0...5].allSatisfy {
            $0.position.id == positionID
        })
        XCTAssertTrue(steps[6...11].allSatisfy {
            $0.position.id == secondPosition.id
        })
        XCTAssertEqual(
            Array(steps[0...2].map(\.repeatIndex)),
            [0, 1, 2]
        )
    }

    func testSessionResumesAtFirstIncompleteRepeatAfterReloadStyleState() throws {
        let orchestrator = try SpeakerOptimizerMeasurementSessionOrchestrator()
        var set = makeSet(captures: [])
        let first = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
        set = try orchestrator.appending(
            makeCapture(),
            to: set,
            for: first
        )
        let second = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
        XCTAssertEqual(second.repeatIndex, 1)

        set = try orchestrator.appending(
            makeCapture(offsetDB: 0.1),
            to: set,
            for: second
        )
        let resumed = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
        XCTAssertEqual(resumed.position.id, positionID)
        XCTAssertEqual(resumed.source, source)
        XCTAssertEqual(resumed.repeatIndex, 2)
    }

    func testSessionRejectsCaptureIdentityDrift() throws {
        let orchestrator = try SpeakerOptimizerMeasurementSessionOrchestrator()
        let set = makeSet(captures: [])
        let step = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
        var wrong = makeCapture()
        wrong.routingSignature = "different-route"

        XCTAssertThrowsError(
            try orchestrator.appending(wrong, to: set, for: step)
        ) { error in
            XCTAssertEqual(
                error as? SpeakerOptimizerMeasurementSessionError,
                .captureIdentityMismatch
            )
        }
    }

    func testRetryLatestCaptureMakesThatRepeatPendingAgain() throws {
        let orchestrator = try SpeakerOptimizerMeasurementSessionOrchestrator()
        var set = makeSet(captures: [])
        for offset in [0.0, 0.1, -0.1] {
            let step = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
            set = try orchestrator.appending(
                makeCapture(offsetDB: offset),
                to: set,
                for: step
            )
        }
        XCTAssertTrue(try orchestrator.progress(for: set).complete)

        set = try orchestrator.retryLatestCapture(
            in: set,
            positionID: positionID,
            source: source
        )
        let retry = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
        XCTAssertEqual(retry.repeatIndex, 2)
        XCTAssertFalse(try orchestrator.progress(for: set).complete)
    }

    func testMeasurementSetStoreRoundTripPreservesCompactEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PR103-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SpeakerOptimizerMeasurementSetStore(
            rootDirectory: root
        )
        let original = makeSet(captures: [
            makeCapture(),
            makeCapture(offsetDB: 0.1),
        ])
        try store.save(original)
        let loaded = try XCTUnwrap(store.load(original.id))

        XCTAssertEqual(loaded, original)
        let data = try Data(contentsOf: store.url(for: original.id))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("rawCapture"))
        XCTAssertFalse(json.contains("impulseResponse"))
    }

    func testPersistenceRejectsCaptureOutsideSessionIdentity() throws {
        var set = makeSet(captures: [makeCapture()])
        set.captures[0].playbackSystemID = UUID()

        XCTAssertThrowsError(try set.validatePersistenceStructure()) {
            error in
            XCTAssertEqual(
                error as? SpeakerOptimizerMeasurementSessionError,
                .persistenceInvalid
            )
        }
    }

    private func makeRoutePlan() -> LiveNChannelOutputRoutePlan {
        var program = Array(
            repeating: UInt32.max,
            count: Int(N60_MAX_PROGRAM_CHANNELS)
        )
        program[0] = 0
        program[1] = 1
        var subs = Array(
            repeating: UInt32.max,
            count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
        )
        subs[0] = 2
        return LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["pr103-output"],
            referenceDeviceUID: "pr103-output",
            physicalChannelCount: 3,
            programPhysicalChannels: program,
            subwooferPhysicalChannels: subs,
            subwooferCount: 1,
            bassManagementEnabled: true,
            speakerCalibrations: [:],
            subwooferCalibrations: Array(
                repeating: nil,
                count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
            )
        )
    }

    private func makeSet(
        role: SpeakerOptimizerMeasurementRole = .baseline,
        captures: [SpeakerOptimizerMeasurementCapture]
    ) -> SpeakerOptimizerMeasurementSet {
        SpeakerOptimizerMeasurementSet(
            role: role,
            playbackSystemID: playbackSystemID,
            routingSignature: "stable-route",
            microphone: microphone,
            sampleRate: 48_000,
            positions: [
                SpeakerOptimizerMeasurementPosition(
                    id: positionID,
                    name: "Main Seat"
                ),
            ],
            plannedSources: [source],
            captures: captures,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeCapture(
        offsetDB: Double = 0,
        snrDB: Double = 50,
        arrivalSeconds: Double = 0.010,
        phaseOffset: Double = 0
    ) -> SpeakerOptimizerMeasurementCapture {
        SpeakerOptimizerMeasurementCapture(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetDB + arrivalSeconds),
            playbackSystemID: playbackSystemID,
            routingSignature: "stable-route",
            microphone: microphone,
            positionID: positionID,
            source: source,
            sampleRate: 48_000,
            response: makeResponse(offsetDB: offsetDB, phaseOffset: phaseOffset),
            quality: makeQuality(snrDB: snrDB, arrivalSeconds: arrivalSeconds)
        )
    }

    private func makeResponse(
        offsetDB: Double,
        phaseOffset: Double
    ) -> RoomCorrectionFrequencyResponse {
        let count = 64
        let low = 20.0
        let high = 20_000.0
        let ratio = high / low
        let frequencies = (0..<count).map { index in
            low * pow(ratio, Double(index) / Double(count - 1))
        }
        let magnitudes = frequencies.map { frequency in
            offsetDB + 0.5 * sin(log(frequency / 100.0))
        }
        let phases = frequencies.map { frequency in
            phaseOffset - 0.05 * log(frequency / 20.0)
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: magnitudes,
            phaseRadians: phases
        )
    }

    private func makeQuality(
        snrDB: Double = 50,
        arrivalSeconds: Double = 0.010
    ) -> RoomCorrectionMeasurementQuality {
        RoomCorrectionMeasurementQuality(
            clipped: false,
            playbackPeakDBFS: -18,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -62,
            estimatedSNRDB: snrDB,
            sweepComplete: true,
            directArrivalSeconds: arrivalSeconds,
            usableLowHz: 20,
            usableHighHz: 20_000,
            warnings: []
        )
    }
}
