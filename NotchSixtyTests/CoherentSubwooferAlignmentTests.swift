import XCTest
@testable import NotchSixty

final class CoherentSubwooferAlignmentTests: XCTestCase {
    private let playbackID = UUID(
        uuidString: "E1000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr108-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr108-cal"
    )

    func testLateSubBecomesCommonSpeakerDelayInsteadOfNegativeSubDelay()
        throws {
        let profile = makeProfile()
        let report = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            relativeArrivalMilliseconds: 3.0
        )

        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [report],
                profile: profile,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )

        XCTAssertTrue(candidate.previewOnly)
        XCTAssertFalse(candidate.canDeploy)
        XCTAssertTrue(candidate.acceptedForPreview)
        XCTAssertEqual(
            candidate.signedRelativeDelayAdjustmentMilliseconds,
            -3.0,
            accuracy: 0.04
        )
        XCTAssertEqual(
            candidate.speakerCommonDelayAdjustmentMilliseconds,
            3.0,
            accuracy: 0.04
        )
        XCTAssertEqual(
            candidate.subwooferDelayAdjustmentMilliseconds,
            0,
            accuracy: 0.001
        )
        XCTAssertFalse(candidate.toggleSubwooferPolarity)
        XCTAssertGreaterThan(candidate.predictedImprovementDB, 1.0)
    }

    func testEarlySubGetsPositiveSubDelay() throws {
        let profile = makeProfile()
        let report = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            relativeArrivalMilliseconds: -2.0
        )

        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [report],
                profile: profile,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )

        XCTAssertTrue(candidate.acceptedForPreview)
        XCTAssertEqual(
            candidate.signedRelativeDelayAdjustmentMilliseconds,
            2.0,
            accuracy: 0.04
        )
        XCTAssertEqual(
            candidate.subwooferDelayAdjustmentMilliseconds,
            2.0,
            accuracy: 0.04
        )
        XCTAssertEqual(
            candidate.speakerCommonDelayAdjustmentMilliseconds,
            0,
            accuracy: 0.001
        )
    }

    func testPolarityReversalIsFoundWithoutInventingDelay() throws {
        let profile = makeProfile()
        let report = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            relativeArrivalMilliseconds: 0,
            additionalPhaseRadians: Double.pi
        )

        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [report],
                profile: profile,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )

        XCTAssertTrue(candidate.acceptedForPreview)
        XCTAssertTrue(candidate.toggleSubwooferPolarity)
        XCTAssertTrue(candidate.resultingSubwooferPolarityInverted)
        XCTAssertEqual(
            candidate.signedRelativeDelayAdjustmentMilliseconds,
            0,
            accuracy: 0.04
        )
    }

    func testTwoMainsProduceOneRobustCompromiseForSamePhysicalSub()
        throws {
        let profile = makeProfile()
        let left = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            relativeArrivalMilliseconds: 2.8
        )
        let right = makeReport(
            profile: profile,
            mainRole: .frontRight,
            relativeArrivalMilliseconds: 3.2
        )

        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [left, right],
                profile: profile,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )

        XCTAssertEqual(
            Set(candidate.mainRoles),
            Set([.frontLeft, .frontRight])
        )
        XCTAssertEqual(candidate.analyzedFrequencyCount, 22)
        XCTAssertEqual(
            candidate.signedRelativeDelayAdjustmentMilliseconds,
            -3.0,
            accuracy: 0.12
        )
        XCTAssertGreaterThan(candidate.predictedImprovementDB, 0.5)
    }

    func testAlreadyCoherentPairReturnsReviewBlockedNoOp() throws {
        let profile = makeProfile()
        let report = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            relativeArrivalMilliseconds: 0
        )

        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [report],
                profile: profile,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )

        XCTAssertFalse(candidate.acceptedForPreview)
        XCTAssertEqual(
            candidate.signedRelativeDelayAdjustmentMilliseconds,
            0,
            accuracy: 0.04
        )
        XCTAssertFalse(candidate.toggleSubwooferPolarity)
        XCTAssertTrue(candidate.blockingReasons.contains {
            $0.contains("No meaningful crossover-band coherence improvement")
        })
    }

    func testEvidenceIdentityAndBassManagementFailClosed() throws {
        let profile = makeProfile()
        var left = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            relativeArrivalMilliseconds: 3
        )
        var right = makeReport(
            profile: profile,
            mainRole: .frontRight,
            relativeArrivalMilliseconds: 3
        )
        right.routingSignature = "stale-route"

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentPlanner().propose(
                reports: [left, right],
                profile: profile,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )
        ) {
            XCTAssertEqual(
                $0 as? CoherentSubwooferAlignmentError,
                .evidenceIdentityMismatch
            )
        }

        left.routingSignature =
            profile.multichannelCalibrationRoutingSignature
        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentPlanner().propose(
                reports: [left],
                profile: profile,
                bassManagementEnabled: false,
                crossoverFrequencyHz: 80
            )
        )
    }

    private func makeProfile()
        -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-output",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-output",
                        channelIndex: 2
                    )
                )
            ]
        )
    }

    private func makeReport(
        profile: OutputDeviceProfileConfiguration,
        mainRole: OutputProgramRole,
        relativeArrivalMilliseconds: Double,
        additionalPhaseRadians: Double = 0
    ) -> SpeakerMeasurementLabCoherentTimingReport {
        let frequencies = stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
        let arrivalSeconds =
            relativeArrivalMilliseconds / 1_000
        let phase = frequencies.map { frequency in
            let raw =
                -2 * Double.pi * frequency * arrivalSeconds
                + additionalPhaseRadians
            return atan2(sin(raw), cos(raw))
        }
        return SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(),
            coherentPairID: UUID(),
            playbackSystemID: playbackID,
            routingSignature:
                profile.multichannelCalibrationRoutingSignature,
            microphone: mic,
            main: .speaker(mainRole),
            subwoofer: .subwoofer(0),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians: phase,
            relativeArrivalMilliseconds:
                relativeArrivalMilliseconds,
            referenceArrivalSpreadMilliseconds: 0.02,
            referenceMagnitudeRepeatabilityRMSDB: 0.05,
            referencePhaseConsistency: 0.999,
            evidenceConfidence: 0.95,
            warnings: []
        )
    }
}
