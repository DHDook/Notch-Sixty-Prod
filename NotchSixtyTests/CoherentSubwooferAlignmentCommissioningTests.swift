import XCTest
@testable import NotchSixty

final class CoherentSubwooferAlignmentCommissioningTests:
    XCTestCase {
    private let playbackID = UUID(
        uuidString: "E2000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr108-commissioning-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr108-commissioning-cal"
    )

    func testProposalBindsExactEvidenceCandidateAndPlaybackSnapshot()
        throws {
        let profile = makePlaybackProfile()
        let reports = [
            makeReport(
                profile: profile,
                mainRole: .frontLeft,
                arrivalMilliseconds: 3.0
            ),
            makeReport(
                profile: profile,
                mainRole: .frontRight,
                arrivalMilliseconds: 3.2
            ),
        ]
        let candidate = try candidate(
            profile: profile,
            reports: reports
        )
        let planner =
            CoherentSubwooferAlignmentCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            reports: reports,
            candidate: candidate,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertTrue(proposal.approvalRequired)
        XCTAssertTrue(proposal.readyForApproval)
        XCTAssertTrue(proposal.canApply)
        XCTAssertTrue(proposal.canDeploy)
        XCTAssertEqual(proposal.playbackSystemID, profile.id)
        XCTAssertEqual(
            proposal.rollbackSnapshot.playbackSystemState,
            profile.state
        )
        XCTAssertEqual(
            proposal.candidateFingerprint,
            planner.fingerprintCandidate(candidate)
        )
        XCTAssertEqual(
            proposal.evidenceFingerprint,
            planner.fingerprintReports(reports)
        )
    }

    func testCommissioningRecomputesCandidateAndRejectsDrift()
        throws {
        let profile = makePlaybackProfile()
        let reports = [
            makeReport(
                profile: profile,
                mainRole: .frontLeft,
                arrivalMilliseconds: 3.0
            )
        ]
        var candidate = try candidate(
            profile: profile,
            reports: reports
        )
        candidate.signedRelativeDelayAdjustmentMilliseconds
            += 0.5

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentCommissioningPlanner()
                .proposal(
                    profile: profile,
                    reports: reports,
                    candidate: candidate
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentCommissioningError,
                .evidenceOrCandidateDrift
            )
        }
    }

    func testCrossoverChangeInvalidatesCommissioning() throws {
        let profile = makePlaybackProfile()
        let reports = [
            makeReport(
                profile: profile,
                mainRole: .frontLeft,
                arrivalMilliseconds: 3.0
            )
        ]
        let candidate = try candidate(
            profile: profile,
            reports: reports
        )
        var changed = profile
        changed.state.bassManagement.frequencyHz = 90

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentCommissioningPlanner()
                .proposal(
                    profile: changed,
                    reports: reports,
                    candidate: candidate
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentCommissioningError,
                .bassManagementMismatch
            )
        }
    }

    func testExplicitApprovalIsRequiredAndFingerprintBound()
        throws {
        let profile = makePlaybackProfile()
        let reports = [
            makeReport(
                profile: profile,
                mainRole: .frontLeft,
                arrivalMilliseconds: 3.0
            )
        ]
        let candidate = try candidate(
            profile: profile,
            reports: reports
        )
        let planner =
            CoherentSubwooferAlignmentCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            reports: reports,
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
            approvedAt: Date(timeIntervalSince1970: 20),
            userInitiated: true
        )
        XCTAssertNoThrow(
            try planner.validateApproval(
                approval,
                for: proposal
            )
        )

        approval.candidateFingerprint = "tampered"
        XCTAssertThrowsError(
            try planner.validateApproval(
                approval,
                for: proposal
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentCommissioningError,
                .invalidApproval
            )
        }
    }

    func testEvidenceFingerprintChangesWhenMeasuredPhaseChanges()
        throws {
        let profile = makePlaybackProfile()
        var report = makeReport(
            profile: profile,
            mainRole: .frontLeft,
            arrivalMilliseconds: 3.0
        )
        let planner =
            CoherentSubwooferAlignmentCommissioningPlanner()
        let before = planner.fingerprintReports([report])
        report.wrappedRelativePhaseRadians[5] += 0.01
        let after = planner.fingerprintReports([report])
        XCTAssertNotEqual(before, after)
    }

    private func candidate(
        profile: PlaybackSystemProfile,
        reports: [SpeakerMeasurementLabCoherentTimingReport]
    ) throws -> CoherentSubwooferAlignmentCandidate {
        try CoherentSubwooferAlignmentPlanner().propose(
            reports: reports,
            profile: try XCTUnwrap(
                profile.state.outputDeviceProfile
            ),
            bassManagementEnabled:
                profile.state.bassManagement.enabled,
            crossoverFrequencyHz:
                profile.state.bassManagement.frequencyHz
        )
    }

    private func makePlaybackProfile()
        -> PlaybackSystemProfile {
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-commissioning-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-commissioning-output",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-commissioning-output",
                        channelIndex: 2
                    )
                )
            ]
        )
        return PlaybackSystemProfile(
            id: playbackID,
            name: "PR108 Commissioning",
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

    private func makeReport(
        profile: PlaybackSystemProfile,
        mainRole: OutputProgramRole,
        arrivalMilliseconds: Double
    ) -> SpeakerMeasurementLabCoherentTimingReport {
        let output = profile.state.outputDeviceProfile!
        let frequencies = stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
        let seconds = arrivalMilliseconds / 1_000
        let phase = frequencies.map { frequency in
            let raw =
                -2 * Double.pi * frequency * seconds
            return atan2(sin(raw), cos(raw))
        }
        return SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(
                uuidString:
                    mainRole == .frontLeft
                    ? "E2100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
                    : "E2200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            coherentPairID: UUID(),
            playbackSystemID: profile.id,
            routingSignature:
                output.multichannelCalibrationRoutingSignature,
            microphone: mic,
            main: .speaker(mainRole),
            subwoofer: .subwoofer(0),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians: phase,
            relativeArrivalMilliseconds: arrivalMilliseconds,
            referenceArrivalSpreadMilliseconds: 0.02,
            referenceMagnitudeRepeatabilityRMSDB: 0.05,
            referencePhaseConsistency: 0.999,
            evidenceConfidence: 0.95,
            warnings: []
        )
    }
}
