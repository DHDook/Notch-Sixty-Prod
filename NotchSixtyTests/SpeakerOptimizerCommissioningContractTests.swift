import XCTest
@testable import NotchSixty

final class SpeakerOptimizerCommissioningContractTests: XCTestCase {
    private let systemID = UUID(uuidString: "C6000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let baselineID = UUID(uuidString: "C6100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let characterizationID = UUID(uuidString: "C6200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!

    func testPEQProposalCapturesRollbackStateAndUsesSeparateOptimizerStage() throws {
        let profile = makeProfile()
        let unchanged = profile
        let proposal = try SpeakerOptimizerCommissioningPlanner().proposal(
            profile: profile,
            plan: makePEQPlan()
        )

        XCTAssertEqual(profile, unchanged)
        XCTAssertEqual(proposal.rollbackSnapshot.playbackSystemState, profile.state)
        XCTAssertEqual(proposal.rollbackSnapshot.playbackSystemID, profile.id)
        XCTAssertTrue(proposal.approvalRequired)
        XCTAssertTrue(proposal.rollbackRequired)
        XCTAssertTrue(proposal.canApply)
        XCTAssertFalse(proposal.isMeasuredVerification)
        XCTAssertEqual(
            try XCTUnwrap(proposal.sources.first).stageStatus,
            .availableDedicatedSpeakerOptimizerPEQStage
        )
        XCTAssertTrue(
            try XCTUnwrap(proposal.sources.first).stageStatus.canInstall
        )
    }

    func testFIRProposalFailsClosedWhenCandidateIsNotRepresentable() throws {
        let proposal = try SpeakerOptimizerCommissioningPlanner().proposal(
            profile: makeProfile(),
            plan: makeFIRPlan()
        )
        XCTAssertFalse(proposal.canApply)
        XCTAssertEqual(
            try XCTUnwrap(proposal.sources.first).stageStatus,
            .blockedFIRCandidateNotRepresentable
        )
    }

    func testRepresentableFIRProposalCanApplyAndBuildsDedicatedConfiguration() throws {
        let planner = SpeakerOptimizerCommissioningPlanner()
        let profile = makeProfile()
        let plan = makeFIRPlan(
            tapCount: 257,
            maximumPositiveGainDB: 0.5,
            recommendedHeadroomDB: 1.0
        )
        let proposal = try planner.proposal(
            profile: profile,
            plan: plan
        )
        XCTAssertTrue(proposal.canApply)
        XCTAssertEqual(
            try XCTUnwrap(proposal.sources.first).stageStatus,
            .availableDedicatedSpeakerOptimizerFIRStage
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            userInitiated: true
        )
        let deployment = try planner.makeFIRDeploymentConfiguration(
            profile: profile,
            plan: plan,
            proposal: proposal,
            approval: approval
        )
        XCTAssertEqual(deployment.tapCount, 257)
        XCTAssertEqual(deployment.declaredGroupDelayFrames, 128)
        XCTAssertEqual(deployment.requiredHeadroomDB, 1.0)
        XCTAssertEqual(deployment.sources.count, 1)
        XCTAssertEqual(deployment.sources.first?.role, .frontLeft)
        XCTAssertEqual(deployment.sources.first?.taps.count, 257)
        XCTAssertNil(
            profile.state.outputDeviceProfile?.speakerOptimizerFIR,
            "Building the deployment must not mutate the Playback System."
        )
    }

    func testExplicitApprovalIsBoundToExactCandidateAndBuildsDedicatedPEQConfiguration() throws {
        let planner = SpeakerOptimizerCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: makeProfile(),
            plan: makePEQPlan()
        )
        XCTAssertThrowsError(
            try planner.makeExplicitApproval(
                proposal: proposal,
                userInitiated: false
            )
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            approvedAt: Date(timeIntervalSince1970: 1_703_500_000),
            userInitiated: true
        )
        XCTAssertEqual(approval.proposalID, proposal.id)
        XCTAssertEqual(
            approval.aggregateCandidateFingerprint,
            planner.aggregateCandidateFingerprint(proposal)
        )
        XCTAssertNoThrow(
            try planner.validateApproval(approval, for: proposal)
        )
        let profile = makeProfile()
        let deployment = try planner.makePEQDeploymentConfiguration(
            profile: profile,
            plan: makePEQPlan(),
            proposal: proposal,
            approval: approval
        )
        XCTAssertEqual(deployment.proposalID, proposal.id)
        XCTAssertEqual(
            deployment.aggregateCandidateFingerprint,
            approval.aggregateCandidateFingerprint
        )
        XCTAssertEqual(
            deployment.sources.first?.bands.first?.gainDB,
            -3
        )
        XCTAssertEqual(
            profile.state.outputDeviceProfile?
                .speakerAssignments.first?.calibration?.eqBands.count,
            1,
            "Building optimizer deployment must not mutate ordinary Speaker Calibration."
        )
    }

    func testApprovalCannotBeReusedAfterCandidateChanges() throws {
        let planner = SpeakerOptimizerCommissioningPlanner()
        let original = try planner.proposal(
            profile: makeProfile(),
            plan: makePEQPlan(gainDB: -3)
        )
        let approval = try planner.makeExplicitApproval(
            proposal: original,
            userInitiated: true
        )
        var changed = try planner.proposal(
            profile: makeProfile(),
            plan: makePEQPlan(gainDB: -4)
        )
        changed.id = original.id
        XCTAssertNotEqual(
            planner.aggregateCandidateFingerprint(original),
            planner.aggregateCandidateFingerprint(changed)
        )
        XCTAssertThrowsError(
            try planner.validateApproval(approval, for: changed)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCommissioningError,
                .invalidApproval
            )
        }
    }

    func testProfileOrClassificationIdentityDriftFailsClosed() throws {
        var plan = makePEQPlan()
        plan.classification = makeClassification(routingSignature: "stale")
        XCTAssertThrowsError(
            try SpeakerOptimizerCommissioningPlanner().proposal(
                profile: makeProfile(),
                plan: plan
            )
        )
        var profile = makeProfile()
        profile.id = UUID()
        XCTAssertThrowsError(
            try SpeakerOptimizerCommissioningPlanner().proposal(
                profile: profile,
                plan: makePEQPlan()
            )
        )
    }

    func testExistingOptimizerDeploymentMustBeResolvedBeforeNewCommissioning() throws {
        let planner = SpeakerOptimizerCommissioningPlanner()
        let initialProfile = makeProfile()
        let firPlan = makeFIRPlan(
            tapCount: 257,
            maximumPositiveGainDB: 0.5,
            recommendedHeadroomDB: 1.0
        )
        let firstProposal = try planner.proposal(
            profile: initialProfile,
            plan: firPlan
        )
        let approval = try planner.makeExplicitApproval(
            proposal: firstProposal,
            userInitiated: true
        )
        let deployment = try planner.makeFIRDeploymentConfiguration(
            profile: initialProfile,
            plan: firPlan,
            proposal: firstProposal,
            approval: approval
        )

        var activeProfile = initialProfile
        activeProfile.state.outputDeviceProfile?
            .speakerOptimizerFIR = deployment

        let secondFIRProposal = try planner.proposal(
            profile: activeProfile,
            plan: firPlan
        )
        XCTAssertFalse(secondFIRProposal.canApply)
        XCTAssertEqual(
            try XCTUnwrap(secondFIRProposal.sources.first).stageStatus,
            .blockedFIRCandidateNotRepresentable
        )

        let peqProposal = try planner.proposal(
            profile: activeProfile,
            plan: makePEQPlan()
        )
        XCTAssertFalse(peqProposal.canApply)
        XCTAssertEqual(
            try XCTUnwrap(peqProposal.sources.first).stageStatus,
            .blockedPEQCandidateNotRepresentable
        )
    }

    private func makeProfile() -> PlaybackSystemProfile {
        let outputProfile = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "commissioning-output",
                        channelIndex: 0
                    ),
                    calibration: SemanticSpeakerCalibration(
                        trimDB: -1,
                        delayMilliseconds: 0.2,
                        polarityInverted: false,
                        eqBands: [
                            OutputCalibrationEQBand(
                                frequencyHz: 500,
                                gainDB: -1,
                                q: 1
                            )
                        ]
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "commissioning-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        return PlaybackSystemProfile(
            id: systemID,
            name: "Commissioning",
            state: PlaybackSystemState(
                associatedOutputUID: "commissioning-output",
                bassManagement: BassManagementConfiguration(enabled: false),
                outputDeviceProfile: outputProfile
            )
        )
    }

    private func makeClassification(
        routingSignature: String? = nil
    ) -> SpeakerOptimizerCrossDomainReport {
        let route = routingSignature
            ?? makeProfile().state.outputDeviceProfile!
                .multichannelCalibrationRoutingSignature
        return SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID: characterizationID,
            listeningMeasurementSetID: baselineID,
            playbackSystemID: systemID,
            routingSignature: route,
            sources: [],
            warnings: []
        )
    }

    private func makePEQPlan(
        gainDB: Double = -3
    ) -> SpeakerOptimizerClassificationAwarePEQPlan {
        let rate = 48_000.0
        let band = SpeakerOptimizerPEQBand.peak(
            centerHz: 2_000,
            q: 1.2,
            gainDB: gainDB,
            sampleRate: rate
        )!
        let route = makeProfile().state.outputDeviceProfile!
            .multichannelCalibrationRoutingSignature
        let source = SpeakerOptimizerPEQSourceCandidate(
            source: .speaker(.frontLeft),
            bands: [band],
            frequenciesHz: [1_000, 2_000, 4_000],
            modeledFilterMagnitudeDB: [band.magnitudeDB(at: 1_000, sampleRate: rate), gainDB, band.magnitudeDB(at: 4_000, sampleRate: rate)],
            weightedRMSEBeforeDB: 2,
            predictedWeightedRMSEAfterDB: 1,
            worstSeatRegressionDB: 0,
            maximumPositiveGainDB: 0,
            recommendedHeadroomDB: 0,
            warnings: []
        )
        return SpeakerOptimizerClassificationAwarePEQPlan(
            classification: makeClassification(),
            candidate: SpeakerOptimizerPEQCandidatePlan(
                baselineMeasurementSetID: baselineID,
                playbackSystemID: systemID,
                routingSignature: route,
                sampleRate: rate,
                evidenceConfidence: 0.9,
                sources: [source]
            )
        )
    }

    private func makeFIRPlan(
        tapCount: Int = 3,
        maximumPositiveGainDB: Double = 0,
        recommendedHeadroomDB: Double = 0
    ) -> SpeakerOptimizerClassificationAwareFIRPlan {
        let route = makeProfile().state.outputDeviceProfile!
            .multichannelCalibrationRoutingSignature
        var taps = [Float](repeating: 0, count: tapCount)
        if tapCount > 0 {
            taps[(tapCount - 1) / 2] = 1
        }
        let source = SpeakerOptimizerFIRSourceCandidate(
            source: .speaker(.frontLeft),
            taps: taps,
            frequenciesHz: [1_000, 2_000, 4_000],
            modeledFilterMagnitudeDB: [-0.5, -2, -0.5],
            weightedRMSEBeforeDB: 2,
            predictedWeightedRMSEAfterDB: 1,
            worstSeatRegressionDB: 0,
            maximumPositiveGainDB: maximumPositiveGainDB,
            recommendedHeadroomDB: recommendedHeadroomDB,
            acceptedForPreview: true,
            blockingReasons: []
        )
        let delay = max(0, (tapCount - 1) / 2)
        return SpeakerOptimizerClassificationAwareFIRPlan(
            classification: makeClassification(),
            candidate: SpeakerOptimizerFIRCandidatePlan(
                baselineMeasurementSetID: baselineID,
                playbackSystemID: systemID,
                routingSignature: route,
                sampleRate: 48_000,
                evidenceConfidence: 0.9,
                requestedTapCount: tapCount,
                declaredGroupDelayFrames: delay,
                declaredGroupDelayMilliseconds:
                    Double(delay) / 48_000 * 1_000,
                sources: [source]
            )
        )
    }
}
