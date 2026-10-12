import XCTest
@testable import NotchSixty

@MainActor
final class SpeakerOptimizerGuidedFIRWorkflowTests:
    XCTestCase {
    func testAudioOnlyReviewDisclosesLatencyHeadroomAndCanApply() throws {
        let fixture = makeFixture()
        let store = GuidedFIRFakeProfileStore(
            profile: fixture.profile
        )
        let controller = SpeakerOptimizerGuidedFIRController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )

        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization,
            avSyncContext: .audioOnly
        )

        XCTAssertEqual(controller.state, .reviewReady)
        XCTAssertTrue(controller.proposal?.canApply == true)
        XCTAssertTrue(controller.canApproveAndApply)
        XCTAssertEqual(controller.candidateTapCount, 257)
        XCTAssertEqual(controller.requiredHeadroomDB, 1.0)
        XCTAssertEqual(
            controller.addedFIRLatencyMilliseconds,
            8.0,
            accuracy: 1.0e-9
        )
        XCTAssertEqual(
            controller.avSyncDecision?.status,
            .audioOnlyAllowed
        )

        try controller.approveAndApply(
            userInitiated: true,
            approvedAt: Date(
                timeIntervalSince1970: 1_704_200_100
            ),
            appliedAt: Date(
                timeIntervalSince1970: 1_704_200_200
            )
        )
        XCTAssertEqual(
            controller.state,
            .appliedPendingVerification
        )
        let receipt = try XCTUnwrap(controller.applyReceipt)
        XCTAssertEqual(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerFIR?.requiredHeadroomDB,
            1.0
        )

        let report = acceptedReport(receipt: receipt)
        try controller.recordVerification(report)
        XCTAssertEqual(controller.state, .measuredAccepted)
        XCTAssertEqual(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerFIR?.verification?
                .verificationMeasurementSetID,
            report.verificationMeasurementSetID
        )

        try controller.rollback()
        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerFIR
        )
    }

    func testVideoWithoutCompensationBlocksUntilContextUpdated() throws {
        let fixture = makeFixture()
        let store = GuidedFIRFakeProfileStore(
            profile: fixture.profile
        )
        let controller = SpeakerOptimizerGuidedFIRController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )

        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization,
            avSyncContext: .synchronizedVideo(
                externalVideoDelayCapacityMilliseconds: nil
            )
        )

        XCTAssertFalse(controller.canApproveAndApply)
        XCTAssertEqual(
            controller.avSyncDecision?.status,
            .externalVideoDelayRequired
        )
        XCTAssertThrowsError(
            try controller.approveAndApply(
                userInitiated: true
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerGuidedFIRError,
                .avSyncApprovalRequired
            )
        }

        try controller.updateAVSyncContext(
            .synchronizedVideo(
                externalVideoDelayCapacityMilliseconds: 10
            )
        )
        XCTAssertEqual(
            controller.avSyncDecision?.status,
            .externalVideoDelayAvailable
        )
        XCTAssertTrue(controller.canApproveAndApply)

        try controller.approveAndApply(
            userInitiated: true
        )
        XCTAssertEqual(
            controller.state,
            .appliedPendingVerification
        )
    }

    func testMeasuredRejectionAutomaticallyRollsBackFIR() throws {
        let fixture = makeFixture()
        let store = GuidedFIRFakeProfileStore(
            profile: fixture.profile
        )
        let controller = SpeakerOptimizerGuidedFIRController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )
        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization,
            avSyncContext: .audioOnly
        )
        try controller.approveAndApply(
            userInitiated: true
        )
        let receipt = try XCTUnwrap(controller.applyReceipt)
        let report = rejectedReport(receipt: receipt)

        try controller.recordVerification(report)

        XCTAssertEqual(controller.state, .rolledBack)
        XCTAssertNotNil(controller.rollbackReceipt)
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerFIR
        )
    }

    func testExplicitUserApprovalRemainsMandatoryForFIR() throws {
        let fixture = makeFixture()
        let store = GuidedFIRFakeProfileStore(
            profile: fixture.profile
        )
        let controller = SpeakerOptimizerGuidedFIRController(
            profileStore: store,
            designOperation: { _, _ in fixture.plan }
        )
        try controller.prepareReview(
            baseline: fixture.baseline,
            characterization: fixture.characterization,
            avSyncContext: .audioOnly
        )

        XCTAssertThrowsError(
            try controller.approveAndApply(
                userInitiated: false
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCommissioningError,
                .invalidApproval
            )
        }
        XCTAssertNil(controller.applyReceipt)
    }

    private func acceptedReport(
        receipt: SpeakerOptimizerFIRApplyReceipt
    ) -> SpeakerOptimizerPostApplyVerificationReport {
        SpeakerOptimizerPostApplyVerificationReport(
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
                    persistentPointCount: 16,
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
    }

    private func rejectedReport(
        receipt: SpeakerOptimizerFIRApplyReceipt
    ) -> SpeakerOptimizerPostApplyVerificationReport {
        SpeakerOptimizerPostApplyVerificationReport(
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
                    persistentPointCount: 16,
                    protectedPointCount: 8,
                    filterTrackingRMSDB: 2,
                    persistentRMSEBeforeDB: 2,
                    persistentRMSEAfterDB: 2.2,
                    persistentImprovementDB: -0.2,
                    worstPersistentSeatRegressionDB: 0.2,
                    protectedRegressionDB: 0,
                    accepted: false,
                    blockingReasons: [
                        "Measured FIR improvement failed."
                    ]
                )
            ],
            blockingReasons: [
                "Front Left: Measured FIR improvement failed."
            ],
            warnings: []
        )
    }

    private func makeFixture() -> (
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        baseline: SpeakerOptimizerMeasurementSet,
        characterization:
            SpeakerOptimizerCharacterizationMeasurementSet
    ) {
        let playbackID = UUID(
            uuidString:
                "D8000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let baselineID = UUID(
            uuidString:
                "D8100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let characterizationID = UUID(
            uuidString:
                "D8200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let position = SpeakerOptimizerMeasurementPosition(
            id: UUID(
                uuidString:
                    "D8300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            name: "Main"
        )
        let source: MultichannelCalibrationSource =
            .speaker(.frontLeft)
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "guided-fir-mic",
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
                        deviceUID: "guided-fir-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "guided-fir-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let profile = PlaybackSystemProfile(
            id: playbackID,
            name: "Guided FIR",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(enabled: false),
                outputDeviceProfile: output
            )
        )
        let route =
            output.multichannelCalibrationRoutingSignature
        var taps = [Float](repeating: 0, count: 257)
        taps[128] = 1
        let plan = SpeakerOptimizerClassificationAwareFIRPlan(
            classification: SpeakerOptimizerCrossDomainReport(
                characterizationMeasurementSetID:
                    characterizationID,
                listeningMeasurementSetID: baselineID,
                playbackSystemID: playbackID,
                routingSignature: route,
                sources: [],
                warnings: []
            ),
            candidate: SpeakerOptimizerFIRCandidatePlan(
                baselineMeasurementSetID: baselineID,
                playbackSystemID: playbackID,
                routingSignature: route,
                sampleRate: 48_000,
                evidenceConfidence: 0.9,
                requestedTapCount: 257,
                declaredGroupDelayFrames: 128,
                declaredGroupDelayMilliseconds:
                    128.0 / 48_000 * 1_000,
                sources: [
                    SpeakerOptimizerFIRSourceCandidate(
                        source: source,
                        taps: taps,
                        frequenciesHz: [
                            500, 1_000, 2_000, 4_000, 8_000
                        ],
                        modeledFilterMagnitudeDB: [
                            0, 0, 0, 0, 0
                        ],
                        weightedRMSEBeforeDB: 2,
                        predictedWeightedRMSEAfterDB: 1,
                        worstSeatRegressionDB: 0,
                        maximumPositiveGainDB: 0.5,
                        recommendedHeadroomDB: 1.0,
                        acceptedForPreview: true,
                        blockingReasons: []
                    )
                ]
            )
        )
        let baseline = SpeakerOptimizerMeasurementSet(
            id: baselineID,
            role: .baseline,
            playbackSystemID: playbackID,
            routingSignature: route,
            microphone: mic,
            sampleRate: 48_000,
            positions: [position],
            plannedSources: [source],
            captures: []
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
                targets: [
                    SpeakerOptimizerCharacterizationTarget(
                        source: source,
                        geometry: .init()
                    )
                ],
                captures: []
            )
        return (
            profile,
            plan,
            baseline,
            characterization
        )
    }
}

@MainActor
private final class GuidedFIRFakeProfileStore:
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
