import XCTest
@testable import NotchSixty

final class CoherentMultiSubwooferAlignmentCommissioningTests:
    XCTestCase {
    private let playbackID = UUID(
        uuidString: "E6000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr108-multisub-commissioning-mic",
        inputChannelIndex: 0,
        calibrationFingerprint:
            "pr108-multisub-commissioning-cal"
    )

    func testProposalBindsAllSubEvidenceAndPlaybackSnapshot()
        throws {
        let profile = makeProfile()
        let groups = evidenceGroups(profile: profile)
        let candidate = try makeCandidate(
            profile: profile,
            groups: groups
        )
        let planner =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            evidenceGroups: groups,
            candidate: candidate,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(proposal.approvalRequired)
        XCTAssertTrue(proposal.readyForApproval)
        XCTAssertFalse(proposal.canApply)
        XCTAssertFalse(proposal.canDeploy)
        XCTAssertEqual(proposal.subwooferIndices, [0, 1])
        XCTAssertEqual(
            proposal.rollbackSnapshot.playbackSystemState,
            profile.state
        )
        XCTAssertEqual(
            proposal.evidenceFingerprint,
            planner.fingerprintEvidenceGroups(groups)
        )
        XCTAssertEqual(
            proposal.candidateFingerprint,
            planner.fingerprintCandidate(candidate)
        )
    }

    func testEvidenceGroupOrderDoesNotChangeFingerprint()
        throws {
        let profile = makeProfile()
        let groups = evidenceGroups(profile: profile)
        let planner =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()

        XCTAssertEqual(
            planner.fingerprintEvidenceGroups(groups),
            planner.fingerprintEvidenceGroups(
                groups.reversed()
            )
        )
    }

    func testCommissioningRegeneratesAndRejectsCandidateDrift()
        throws {
        let profile = makeProfile()
        let groups = evidenceGroups(profile: profile)
        var candidate = try makeCandidate(
            profile: profile,
            groups: groups
        )
        candidate
            .speakerCommonDelayAdjustmentMilliseconds += 0.25

        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentCommissioningPlanner()
                .proposal(
                    profile: profile,
                    evidenceGroups: groups,
                    candidate: candidate
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentCommissioningError,
                .evidenceOrCandidateDrift
            )
        }
    }

    func testEvidenceMutationChangesAtomicFingerprint()
        throws {
        let profile = makeProfile()
        var groups = evidenceGroups(profile: profile)
        let planner =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()
        let before =
            planner.fingerprintEvidenceGroups(groups)
        groups[1].reports[0]
            .wrappedRelativePhaseRadians[5] += 0.01
        let after =
            planner.fingerprintEvidenceGroups(groups)
        XCTAssertNotEqual(before, after)
    }

    func testExplicitApprovalIsFingerprintBound() throws {
        let profile = makeProfile()
        let groups = evidenceGroups(profile: profile)
        let candidate = try makeCandidate(
            profile: profile,
            groups: groups
        )
        let planner =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            evidenceGroups: groups,
            candidate: candidate
        )

        XCTAssertThrowsError(
            try planner.makeExplicitApproval(
                proposal: proposal,
                userInitiated: false
            )
        )

        var approval = try planner.makeExplicitApproval(
            proposal: proposal,
            approvedAt: Date(timeIntervalSince1970: 200),
            userInitiated: true
        )
        XCTAssertNoThrow(
            try planner.validateApproval(
                approval,
                for: proposal
            )
        )

        approval.evidenceFingerprint = "stale"
        XCTAssertThrowsError(
            try planner.validateApproval(
                approval,
                for: proposal
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentCommissioningError,
                .invalidApproval
            )
        }
    }

    private func makeCandidate(
        profile: PlaybackSystemProfile,
        groups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup]
    ) throws -> CoherentMultiSubwooferAlignmentCandidate {
        try CoherentMultiSubwooferAlignmentPlanner()
            .propose(
                evidenceGroups: groups,
                profile: try XCTUnwrap(
                    profile.state.outputDeviceProfile
                ),
                bassManagementEnabled:
                    profile.state.bassManagement.enabled,
                crossoverFrequencyHz:
                    profile.state.bassManagement.frequencyHz
            )
    }

    private func makeProfile() -> PlaybackSystemProfile {
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID:
                            "pr108-multisub-commissioning-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID:
                            "pr108-multisub-commissioning-output",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID:
                            "pr108-multisub-commissioning-output",
                        channelIndex: 2
                    )
                ),
                PhysicalSubwooferOutputAssignment(
                    index: 1,
                    destination: PhysicalOutputEndpoint(
                        deviceUID:
                            "pr108-multisub-commissioning-output",
                        channelIndex: 3
                    )
                ),
            ]
        )
        return PlaybackSystemProfile(
            id: playbackID,
            name: "PR108 Multi-Sub Commissioning",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(
                        enabled: true,
                        frequencyHz: 80
                    ),
                outputDeviceProfile: output
            )
        )
    }

    private func evidenceGroups(
        profile: PlaybackSystemProfile
    ) -> [CoherentMultiSubwooferAlignmentEvidenceGroup] {
        [
            evidenceGroup(
                profile: profile,
                subwooferIndex: 0,
                arrivalMilliseconds: 3
            ),
            evidenceGroup(
                profile: profile,
                subwooferIndex: 1,
                arrivalMilliseconds: -2
            ),
        ]
    }

    private func evidenceGroup(
        profile: PlaybackSystemProfile,
        subwooferIndex: UInt32,
        arrivalMilliseconds: Double
    ) -> CoherentMultiSubwooferAlignmentEvidenceGroup {
        CoherentMultiSubwooferAlignmentEvidenceGroup(
            subwooferIndex: subwooferIndex,
            reports: [
                makeReport(
                    profile: profile,
                    subwooferIndex: subwooferIndex,
                    arrivalMilliseconds:
                        arrivalMilliseconds
                )
            ]
        )
    }

    private func makeReport(
        profile: PlaybackSystemProfile,
        subwooferIndex: UInt32,
        arrivalMilliseconds: Double
    ) -> SpeakerMeasurementLabCoherentTimingReport {
        let frequencies = stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
        let seconds = arrivalMilliseconds / 1_000
        return SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(),
            coherentPairID: UUID(),
            playbackSystemID: profile.id,
            routingSignature:
                profile.state.outputDeviceProfile!
                    .multichannelCalibrationRoutingSignature,
            microphone: mic,
            main: .speaker(.frontLeft),
            subwoofer: .subwoofer(subwooferIndex),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians:
                frequencies.map { frequency in
                    let raw =
                        -2 * Double.pi
                        * frequency * seconds
                    return atan2(sin(raw), cos(raw))
                },
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
