import XCTest
@testable import NotchSixty

final class CoherentMultiSubwooferAlignmentTests: XCTestCase {
    private let playbackID = UUID(
        uuidString: "E5000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr108-multisub-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr108-multisub-cal"
    )

    func testCoordinatedSolveUsesMinimumLatencyCommonSpeakerDelay()
        throws {
        let profile = makeProfile()
        let groups = [
            evidenceGroup(
                profile: profile,
                subwooferIndex: 0,
                arrivalMilliseconds: 3.0
            ),
            evidenceGroup(
                profile: profile,
                subwooferIndex: 1,
                arrivalMilliseconds: -2.0
            ),
        ]

        let candidate =
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: groups,
                    profile: profile,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )

        XCTAssertTrue(candidate.previewOnly)
        XCTAssertFalse(candidate.canDeploy)
        XCTAssertTrue(candidate.acceptedForPreview)
        XCTAssertEqual(
            candidate.speakerCommonDelayAdjustmentMilliseconds,
            3.0,
            accuracy: 0.05
        )

        let sub0 = try XCTUnwrap(
            candidate.subwoofers.first { $0.subwooferIndex == 0 }
        )
        let sub1 = try XCTUnwrap(
            candidate.subwoofers.first { $0.subwooferIndex == 1 }
        )
        XCTAssertEqual(
            sub0.signedRelativeDelayAdjustmentMilliseconds,
            -3.0,
            accuracy: 0.05
        )
        XCTAssertEqual(
            sub0.subwooferDelayAdjustmentMilliseconds,
            0,
            accuracy: 0.05
        )
        XCTAssertEqual(
            sub1.signedRelativeDelayAdjustmentMilliseconds,
            2.0,
            accuracy: 0.05
        )
        XCTAssertEqual(
            sub1.subwooferDelayAdjustmentMilliseconds,
            5.0,
            accuracy: 0.05
        )

        // D_i - C must preserve each independently measured optimum.
        XCTAssertEqual(
            sub0.subwooferDelayAdjustmentMilliseconds
                - candidate.speakerCommonDelayAdjustmentMilliseconds,
            sub0.signedRelativeDelayAdjustmentMilliseconds,
            accuracy: 0.05
        )
        XCTAssertEqual(
            sub1.subwooferDelayAdjustmentMilliseconds
                - candidate.speakerCommonDelayAdjustmentMilliseconds,
            sub1.signedRelativeDelayAdjustmentMilliseconds,
            accuracy: 0.05
        )
    }

    func testCoordinatedSolveCarriesIndependentPolarityPerSub()
        throws {
        let profile = makeProfile()
        let groups = [
            evidenceGroup(
                profile: profile,
                subwooferIndex: 0,
                arrivalMilliseconds: 0,
                additionalPhaseRadians: Double.pi
            ),
            evidenceGroup(
                profile: profile,
                subwooferIndex: 1,
                arrivalMilliseconds: 2
            ),
        ]

        let candidate =
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: groups,
                    profile: profile,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )

        let sub0 = try XCTUnwrap(
            candidate.subwoofers.first { $0.subwooferIndex == 0 }
        )
        let sub1 = try XCTUnwrap(
            candidate.subwoofers.first { $0.subwooferIndex == 1 }
        )
        XCTAssertTrue(sub0.toggleSubwooferPolarity)
        XCTAssertTrue(sub0.resultingSubwooferPolarityInverted)
        XCTAssertFalse(sub1.toggleSubwooferPolarity)
        XCTAssertEqual(
            candidate.speakerCommonDelayAdjustmentMilliseconds,
            2.0,
            accuracy: 0.05
        )
        XCTAssertEqual(
            sub0.subwooferDelayAdjustmentMilliseconds,
            2.0,
            accuracy: 0.05
        )
        XCTAssertEqual(
            sub1.subwooferDelayAdjustmentMilliseconds,
            0,
            accuracy: 0.05
        )
    }

    func testDuplicateAndIncompleteEvidenceFailClosed() throws {
        let profile = makeProfile()
        let sub0 = evidenceGroup(
            profile: profile,
            subwooferIndex: 0,
            arrivalMilliseconds: 3
        )

        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: [sub0, sub0],
                    profile: profile,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentMultiSubwooferAlignmentError,
                .duplicateSubwoofer(0)
            )
        }

        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: [sub0],
                    profile: profile,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentMultiSubwooferAlignmentError,
                .evidenceSetIncomplete
            )
        }
    }

    func testEverySubMustUseSameMainRoleSet() throws {
        let profile = makeProfile()
        let left = evidenceGroup(
            profile: profile,
            subwooferIndex: 0,
            arrivalMilliseconds: 3,
            mainRole: .frontLeft
        )
        let right = evidenceGroup(
            profile: profile,
            subwooferIndex: 1,
            arrivalMilliseconds: 3,
            mainRole: .frontRight
        )

        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: [left, right],
                    profile: profile,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentMultiSubwooferAlignmentError,
                .mainRoleSetMismatch
            )
        }
    }

    func testCoordinatedSolveRespectsRemainingSpeakerDelayCapacity()
        throws {
        var profile = makeProfile()
        for index in profile.speakerAssignments.indices {
            profile.speakerAssignments[index].calibration =
                SemanticSpeakerCalibration(
                    delayMilliseconds: 299
                )
        }
        let groups = [
            evidenceGroup(
                profile: profile,
                subwooferIndex: 0,
                arrivalMilliseconds: 3
            ),
            evidenceGroup(
                profile: profile,
                subwooferIndex: 1,
                arrivalMilliseconds: 1
            ),
        ]

        let candidate =
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: groups,
                    profile: profile,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )

        // Every single-Sub search is already constrained by the current
        // speaker-delay budget. The coordinated common delay therefore cannot
        // exceed the smallest remaining speaker headroom.
        XCTAssertLessThanOrEqual(
            candidate.speakerCommonDelayAdjustmentMilliseconds,
            1.0 + 1.0e-9
        )
        for assignment in profile.speakerAssignments
        where assignment.role != .lowFrequencyEffects {
            let current =
                assignment.calibration?.delayMilliseconds ?? 0
            XCTAssertTrue(
                SemanticSpeakerCalibration.delayRangeMilliseconds
                    .contains(
                        current
                            + candidate
                                .speakerCommonDelayAdjustmentMilliseconds
                    )
            )
        }

        for sub in candidate.subwoofers {
            XCTAssertEqual(
                sub.subwooferDelayAdjustmentMilliseconds
                    - candidate
                        .speakerCommonDelayAdjustmentMilliseconds,
                sub.signedRelativeDelayAdjustmentMilliseconds,
                accuracy: 0.001
            )
        }
    }

    /// E8 A4: coordinated alignment accepts 8 subs, with one result per sub.
    func testCoordinatedSolveAcceptsEightSubwoofers() throws {
        let profile = makeProfile(subs: 8)
        let groups = (0..<8).map {
            evidenceGroup(
                profile: profile,
                subwooferIndex: UInt32($0),
                arrivalMilliseconds: Double($0) * 0.5 - 1.0
            )
        }
        let candidate = try CoherentMultiSubwooferAlignmentPlanner().propose(
            evidenceGroups: groups,
            profile: profile,
            bassManagementEnabled: true,
            crossoverFrequencyHz: 80
        )
        XCTAssertEqual(candidate.subwoofers.map(\.subwooferIndex), (0..<8).map { UInt32($0) })
        for sub in candidate.subwoofers {
            XCTAssertEqual(
                sub.subwooferDelayAdjustmentMilliseconds
                    - candidate.speakerCommonDelayAdjustmentMilliseconds,
                sub.signedRelativeDelayAdjustmentMilliseconds,
                accuracy: 0.001
            )
        }
    }

    private func makeProfile(subs: Int = 2)
        -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multisub-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multisub-output",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: (0..<subs).map {
                PhysicalSubwooferOutputAssignment(
                    index: UInt32($0),
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multisub-output",
                        channelIndex: UInt32(2 + $0)
                    )
                )
            }
        )
    }

    private func evidenceGroup(
        profile: OutputDeviceProfileConfiguration,
        subwooferIndex: UInt32,
        arrivalMilliseconds: Double,
        additionalPhaseRadians: Double = 0,
        mainRole: OutputProgramRole = .frontLeft
    ) -> CoherentMultiSubwooferAlignmentEvidenceGroup {
        CoherentMultiSubwooferAlignmentEvidenceGroup(
            subwooferIndex: subwooferIndex,
            reports: [
                makeReport(
                    profile: profile,
                    subwooferIndex: subwooferIndex,
                    arrivalMilliseconds: arrivalMilliseconds,
                    additionalPhaseRadians:
                        additionalPhaseRadians,
                    mainRole: mainRole
                )
            ]
        )
    }

    private func makeReport(
        profile: OutputDeviceProfileConfiguration,
        subwooferIndex: UInt32,
        arrivalMilliseconds: Double,
        additionalPhaseRadians: Double,
        mainRole: OutputProgramRole
    ) -> SpeakerMeasurementLabCoherentTimingReport {
        let frequencies = stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
        let seconds = arrivalMilliseconds / 1_000
        let phase = frequencies.map { frequency in
            let raw =
                -2 * Double.pi * frequency * seconds
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
            subwoofer: .subwoofer(subwooferIndex),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians: phase,
            relativeArrivalMilliseconds:
                arrivalMilliseconds,
            referenceArrivalSpreadMilliseconds: 0.02,
            referenceMagnitudeRepeatabilityRMSDB: 0.05,
            referencePhaseConsistency: 0.999,
            evidenceConfidence: 0.95,
            warnings: []
        )
    }
}
