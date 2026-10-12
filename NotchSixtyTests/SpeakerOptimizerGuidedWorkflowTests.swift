import XCTest
@testable import NotchSixty

@MainActor
final class SpeakerOptimizerGuidedWorkflowTests: XCTestCase {
    func testGuidedReviewExplicitApplyMeasuredAcceptanceAndRollback() throws {
        let fixture = try makeGuidedFixture()
        let store = GuidedFakeProfileStore(profile: fixture.profile)
        let controller = SpeakerOptimizerGuidedPEQController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )

        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization
        )
        XCTAssertEqual(controller.state, .reviewReady)
        XCTAssertTrue(controller.proposal?.canApply == true)
        XCTAssertEqual(controller.candidateBandCount, 1)

        try controller.approveAndApply(
            userInitiated: true,
            approvedAt: Date(timeIntervalSince1970: 1_703_900_100),
            appliedAt: Date(timeIntervalSince1970: 1_703_900_200)
        )
        XCTAssertEqual(
            controller.state,
            .appliedPendingVerification
        )
        let receipt = try XCTUnwrap(controller.applyReceipt)
        XCTAssertTrue(receipt.requiresMeasuredVerification)
        XCTAssertNotNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerPEQ
        )

        let report = SpeakerOptimizerPostApplyVerificationReport(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID:
                receipt.baselineMeasurementSetID,
            verificationMeasurementSetID: UUID(),
            playbackSystemID: receipt.playbackSystemID,
            routingSignature: receipt.routingSignature,
            evidenceConfidence: 0.9,
            sources: [
                SpeakerOptimizerPostApplySourceVerification(
                    source: .speaker(.frontLeft),
                    persistentPointCount: 8,
                    protectedPointCount: 8,
                    filterTrackingRMSDB: 0.2,
                    persistentRMSEBeforeDB: 2,
                    persistentRMSEAfterDB: 1,
                    persistentImprovementDB: 1,
                    worstPersistentSeatRegressionDB: 0,
                    protectedRegressionDB: 0,
                    accepted: true,
                    blockingReasons: []
                )
            ],
            blockingReasons: [],
            warnings: []
        )
        try controller.recordVerification(report)
        XCTAssertEqual(controller.state, .measuredAccepted)
        XCTAssertNotNil(controller.verificationFinalizationReceipt)
        XCTAssertEqual(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerPEQ?.verification?
                .verificationMeasurementSetID,
            report.verificationMeasurementSetID
        )

        try controller.rollback(
            rolledBackAt: Date(timeIntervalSince1970: 1_703_900_300)
        )
        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerPEQ
        )
    }

    func testMeasuredRejectionAutomaticallyRollsBackProvisionalPEQ() throws {
        let fixture = try makeGuidedFixture()
        let store = GuidedFakeProfileStore(profile: fixture.profile)
        let controller = SpeakerOptimizerGuidedPEQController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )
        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization
        )
        try controller.approveAndApply(
            userInitiated: true,
            approvedAt: Date(timeIntervalSince1970: 1_703_905_100),
            appliedAt: Date(timeIntervalSince1970: 1_703_905_200)
        )
        let receipt = try XCTUnwrap(controller.applyReceipt)
        let rejected = SpeakerOptimizerPostApplyVerificationReport(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID:
                receipt.baselineMeasurementSetID,
            verificationMeasurementSetID: UUID(),
            playbackSystemID: receipt.playbackSystemID,
            routingSignature: receipt.routingSignature,
            evidenceConfidence: 0.9,
            sources: [
                SpeakerOptimizerPostApplySourceVerification(
                    source: .speaker(.frontLeft),
                    persistentPointCount: 8,
                    protectedPointCount: 8,
                    filterTrackingRMSDB: 2,
                    persistentRMSEBeforeDB: 2,
                    persistentRMSEAfterDB: 2.2,
                    persistentImprovementDB: -0.2,
                    worstPersistentSeatRegressionDB: 0.2,
                    protectedRegressionDB: 0,
                    accepted: false,
                    blockingReasons: ["Measured improvement failed."]
                )
            ],
            blockingReasons: ["Front Left: Measured improvement failed."],
            warnings: []
        )
        try controller.recordVerification(rejected)

        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertNotNil(controller.rollbackReceipt)
        XCTAssertNil(controller.verificationFinalizationReceipt)
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerPEQ
        )
    }

    func testGuidedControllerCannotMintNonUserApproval() throws {
        let fixture = try makeGuidedFixture()
        let store = GuidedFakeProfileStore(profile: fixture.profile)
        let controller = SpeakerOptimizerGuidedPEQController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )
        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization
        )

        XCTAssertThrowsError(
            try controller.approveAndApply(userInitiated: false)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCommissioningError,
                .invalidApproval
            )
        }
        XCTAssertNil(controller.applyReceipt)
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerPEQ
        )
    }

    func testVerificationFactoryCreatesFreshReceiptBoundCampaign() throws {
        let fixture = try makeGuidedFixture()
        let planner = SpeakerOptimizerCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: fixture.profile,
            plan: fixture.plan
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            userInitiated: true
        )
        let deployment = try planner.makePEQDeploymentConfiguration(
            profile: fixture.profile,
            plan: fixture.plan,
            proposal: proposal,
            approval: approval
        )
        var expected = fixture.profile.state
        var output = try XCTUnwrap(expected.outputDeviceProfile)
        output.speakerOptimizerPEQ = deployment
        expected.outputDeviceProfile = output
        let receipt = SpeakerOptimizerPEQApplyReceipt(
            appliedAt: Date(timeIntervalSince1970: 1_703_910_000),
            proposalID: proposal.id,
            playbackSystemID: fixture.profile.id,
            baselineMeasurementSetID: fixture.baseline.id,
            characterizationMeasurementSetID:
                fixture.plan.classification
                    .characterizationMeasurementSetID,
            routingSignature:
                fixture.baseline.routingSignature,
            aggregateCandidateFingerprint:
                approval.aggregateCandidateFingerprint,
            deployment: deployment,
            rollbackSnapshot: proposal.rollbackSnapshot,
            expectedAppliedState: expected
        )

        let factory = SpeakerOptimizerVerificationSessionFactory()
        let archive = try factory.fresh(
            baseline: fixture.baseline,
            receipt: receipt,
            createdAt: Date(timeIntervalSince1970: 1_703_910_010)
        )
        XCTAssertEqual(archive.applyReceiptID, receipt.id)
        XCTAssertEqual(
            archive.baselineMeasurementSetID,
            fixture.baseline.id
        )
        XCTAssertEqual(archive.measurementSet.role, .verification)
        XCTAssertEqual(
            archive.measurementSet.positions,
            fixture.baseline.positions
        )
        XCTAssertTrue(archive.measurementSet.captures.isEmpty)
        XCTAssertNoThrow(
            try factory.validate(
                archive,
                baseline: fixture.baseline,
                receipt: receipt
            )
        )
    }

    func testVerificationFactoryRejectsPreApplyCaptureReuse() throws {
        let fixture = try makeGuidedFixture()
        let planner = SpeakerOptimizerCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: fixture.profile,
            plan: fixture.plan
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            userInitiated: true
        )
        let deployment = try planner.makePEQDeploymentConfiguration(
            profile: fixture.profile,
            plan: fixture.plan,
            proposal: proposal,
            approval: approval
        )
        var expected = fixture.profile.state
        var output = try XCTUnwrap(expected.outputDeviceProfile)
        output.speakerOptimizerPEQ = deployment
        expected.outputDeviceProfile = output
        let receipt = SpeakerOptimizerPEQApplyReceipt(
            appliedAt: Date(timeIntervalSince1970: 1_703_920_000),
            proposalID: proposal.id,
            playbackSystemID: fixture.profile.id,
            baselineMeasurementSetID: fixture.baseline.id,
            characterizationMeasurementSetID:
                fixture.plan.classification
                    .characterizationMeasurementSetID,
            routingSignature: fixture.baseline.routingSignature,
            aggregateCandidateFingerprint:
                approval.aggregateCandidateFingerprint,
            deployment: deployment,
            rollbackSnapshot: proposal.rollbackSnapshot,
            expectedAppliedState: expected
        )
        let factory = SpeakerOptimizerVerificationSessionFactory()
        var archive = try factory.fresh(
            baseline: fixture.baseline,
            receipt: receipt
        )
        var reused = fixture.baseline.captures[0]
        reused.positionID = archive.measurementSet.positions[0].id
        archive.measurementSet.captures = [reused]

        XCTAssertThrowsError(
            try factory.validate(
                archive,
                baseline: fixture.baseline,
                receipt: receipt
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerVerificationSessionError,
                .invalidArchive
            )
        }
    }

    private func makeGuidedFixture() throws -> (
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        baseline: SpeakerOptimizerMeasurementSet,
        characterization:
            SpeakerOptimizerCharacterizationMeasurementSet
    ) {
        let playbackID = UUID(
            uuidString: "C8000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let baselineID = UUID(
            uuidString: "C8100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let characterizationID = UUID(
            uuidString: "C8200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let position = SpeakerOptimizerMeasurementPosition(
            id: UUID(
                uuidString: "C8300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            name: "Main"
        )
        let source: MultichannelCalibrationSource =
            .speaker(.frontLeft)
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "guided-workflow-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: nil
        )
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "guided-workflow-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "guided-workflow-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let profile = PlaybackSystemProfile(
            id: playbackID,
            name: "Guided Workflow",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(enabled: false),
                outputDeviceProfile: output
            )
        )
        let route = output.multichannelCalibrationRoutingSignature
        let frequencies = (0..<32).map { index in
            500 * pow(
                8_000.0 / 500.0,
                Double(index) / 31.0
            )
        }
        let band = try XCTUnwrap(
            SpeakerOptimizerPEQBand.peak(
                centerHz: 2_000,
                q: 1.2,
                gainDB: -3,
                sampleRate: 48_000
            )
        )
        let candidate = SpeakerOptimizerPEQCandidatePlan(
            baselineMeasurementSetID: baselineID,
            playbackSystemID: playbackID,
            routingSignature: route,
            sampleRate: 48_000,
            evidenceConfidence: 0.9,
            sources: [
                SpeakerOptimizerPEQSourceCandidate(
                    source: source,
                    bands: [band],
                    frequenciesHz: frequencies,
                    modeledFilterMagnitudeDB: frequencies.map {
                        band.magnitudeDB(
                            at: $0,
                            sampleRate: 48_000
                        )
                    },
                    weightedRMSEBeforeDB: 2,
                    predictedWeightedRMSEAfterDB: 1,
                    worstSeatRegressionDB: 0,
                    maximumPositiveGainDB: 0,
                    recommendedHeadroomDB: 0,
                    warnings: []
                )
            ]
        )
        let classification = SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID: characterizationID,
            listeningMeasurementSetID: baselineID,
            playbackSystemID: playbackID,
            routingSignature: route,
            sources: [
                SpeakerOptimizerCrossDomainSourceReport(
                    source: source,
                    frequenciesHz: frequencies,
                    points: frequencies.map {
                        SpeakerOptimizerCrossDomainPoint(
                            frequencyHz: $0,
                            characterizationResidualDB: 2,
                            listeningMeanResidualDB: 2,
                            listeningSeatSpreadDB: 0.1,
                            classification: .speakerPersistent
                        )
                    },
                    characterizationCaptureCount: 3,
                    listeningSeatCount: 1
                )
            ],
            warnings: []
        )
        let plan = SpeakerOptimizerClassificationAwarePEQPlan(
            classification: classification,
            candidate: candidate
        )

        let captures = (0..<3).map { repeatIndex in
            SpeakerOptimizerMeasurementCapture(
                capturedAt: Date(
                    timeIntervalSince1970:
                        1_703_800_000 + Double(repeatIndex)
                ),
                playbackSystemID: playbackID,
                routingSignature: route,
                microphone: mic,
                positionID: position.id,
                source: source,
                sampleRate: 48_000,
                response: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: frequencies.map { frequency in
                        4 * exp(
                            -0.5 * pow(
                                log2(frequency / 2_000) / 0.3,
                                2
                            )
                        )
                    },
                    phaseRadians: frequencies.map { _ in 0 }
                ),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -20,
                    capturePeakDBFS: -12,
                    estimatedNoiseFloorDBFS: -72,
                    estimatedSNRDB: 58,
                    sweepComplete: true,
                    directArrivalSeconds:
                        0.010 + Double(repeatIndex) * 0.00002,
                    usableLowHz: 500,
                    usableHighHz: 8_000,
                    warnings: []
                )
            )
        }
        let baseline = SpeakerOptimizerMeasurementSet(
            id: baselineID,
            role: .baseline,
            playbackSystemID: playbackID,
            routingSignature: route,
            microphone: mic,
            sampleRate: 48_000,
            positions: [position],
            plannedSources: [source],
            captures: captures
        )
        let target = SpeakerOptimizerCharacterizationTarget(
            id: UUID(
                uuidString: "C8400000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            source: source,
            geometry: .init()
        )
        let characterization =
            SpeakerOptimizerCharacterizationMeasurementSet(
                id: characterizationID,
                role: .baseline,
                playbackSystemID: playbackID,
                routingSignature: route,
                microphone: mic,
                sampleRate: 48_000,
                linkedListeningMeasurementSetID: baselineID,
                targets: [target],
                captures: []
            )
        return (profile, plan, baseline, characterization)
    }
}

@MainActor
private final class GuidedFakeProfileStore:
    SpeakerOptimizerPEQProfileMutating {
    var profile: PlaybackSystemProfile?
    var lifecycleState: AudioLifecycleState = .idle

    init(profile: PlaybackSystemProfile?) {
        self.profile = profile
    }

    var speakerOptimizerSelectedSystemProfile:
        PlaybackSystemProfile? {
        profile
    }

    var speakerOptimizerLifecycleState: AudioLifecycleState {
        lifecycleState
    }

    func speakerOptimizerReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        profile?.state.outputDeviceProfile = configuration
    }
}
