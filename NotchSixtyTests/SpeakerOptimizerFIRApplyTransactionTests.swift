import XCTest
@testable import NotchSixty

@MainActor
final class SpeakerOptimizerFIRApplyTransactionTests: XCTestCase {
    func testApplyInstallsOnlyDedicatedFIRAndRollbackRestoresExactSnapshot() throws {
        let fixture = try makeFixture()
        let store = FIRFakeProfileStore(profile: fixture.profile)
        let transaction = SpeakerOptimizerFIRApplyTransaction()
        let ordinaryBefore = fixture.profile.state.outputDeviceProfile?
            .speakerAssignments.first(where: { $0.role == .frontLeft })?
            .calibration

        let receipt = try transaction.apply(
            profileStore: store,
            plan: fixture.plan,
            proposal: fixture.proposal,
            approval: fixture.approval,
            appliedAt: Date(timeIntervalSince1970: 1_704_000_000)
        )

        let applied = try XCTUnwrap(store.profile)
        XCTAssertEqual(
            applied.state.outputDeviceProfile?
                .speakerAssignments.first(where: { $0.role == .frontLeft })?
                .calibration,
            ordinaryBefore
        )
        XCTAssertNil(
            applied.state.outputDeviceProfile?.speakerOptimizerPEQ
        )
        XCTAssertEqual(
            applied.state.outputDeviceProfile?
                .speakerOptimizerFIR?.proposalID,
            fixture.proposal.id
        )
        XCTAssertEqual(
            applied.state.outputDeviceProfile?
                .speakerOptimizerFIR?.requiredHeadroomDB,
            1.0
        )
        XCTAssertEqual(applied.state, receipt.expectedAppliedState)
        XCTAssertTrue(receipt.requiresMeasuredVerification)
        XCTAssertFalse(receipt.isMeasuredVerification)

        let rolledBack = try transaction.rollback(
            receipt,
            profileStore: store,
            rolledBackAt: Date(timeIntervalSince1970: 1_704_000_100)
        )
        XCTAssertEqual(
            store.profile?.state,
            fixture.proposal.rollbackSnapshot.playbackSystemState
        )
        XCTAssertEqual(
            rolledBack.restoredState,
            fixture.proposal.rollbackSnapshot.playbackSystemState
        )
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?.speakerOptimizerFIR
        )
    }

    func testApplyRequiresIdleEngineAndExactCommissioningSnapshot() throws {
        let fixture = try makeFixture()
        let store = FIRFakeProfileStore(profile: fixture.profile)
        store.lifecycleState = .running

        XCTAssertThrowsError(
            try SpeakerOptimizerFIRApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: fixture.approval
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRApplyTransactionError,
                .lifecycleMustBeIdle(.running)
            )
        }
        XCTAssertEqual(store.replaceCount, 0)

        store.lifecycleState = .idle
        store.profile?.state.outputGainDB = -1
        XCTAssertThrowsError(
            try SpeakerOptimizerFIRApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: fixture.approval
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRApplyTransactionError,
                .currentStateDrift
            )
        }
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testApplyRejectsStaleApprovalBeforeMutation() throws {
        let fixture = try makeFixture()
        let store = FIRFakeProfileStore(profile: fixture.profile)
        var stale = fixture.approval
        stale.aggregateCandidateFingerprint = "stale"

        XCTAssertThrowsError(
            try SpeakerOptimizerFIRApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: stale
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCommissioningError,
                .invalidApproval
            )
        }
        XCTAssertEqual(store.replaceCount, 0)
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?.speakerOptimizerFIR
        )
    }

    func testMutationFailureLeavesOriginalSnapshotAndReturnsNoReceipt() throws {
        let fixture = try makeFixture()
        let store = FIRFakeProfileStore(profile: fixture.profile)
        store.failNextReplace = true

        XCTAssertThrowsError(
            try SpeakerOptimizerFIRApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: fixture.approval
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRApplyTransactionError,
                .applyMutationFailed
            )
        }
        XCTAssertEqual(
            store.profile?.state,
            fixture.proposal.rollbackSnapshot.playbackSystemState
        )
    }

    func testRollbackRefusesToOverwriteUnrelatedPostApplyEdit() throws {
        let fixture = try makeFixture()
        let store = FIRFakeProfileStore(profile: fixture.profile)
        let transaction = SpeakerOptimizerFIRApplyTransaction()
        let receipt = try transaction.apply(
            profileStore: store,
            plan: fixture.plan,
            proposal: fixture.proposal,
            approval: fixture.approval
        )

        store.profile?.state.outputGainDB = -2
        XCTAssertThrowsError(
            try transaction.rollback(
                receipt,
                profileStore: store
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerFIRApplyTransactionError,
                .rollbackStateDrift
            )
        }
        XCTAssertNotNil(
            store.profile?.state.outputDeviceProfile?.speakerOptimizerFIR
        )
    }

    private func makeFixture() throws -> (
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        proposal: SpeakerOptimizerCommissioningProposal,
        approval: SpeakerOptimizerApplyApproval
    ) {
        let playbackID = UUID(
            uuidString: "D6000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let baselineID = UUID(
            uuidString: "D6100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let characterizationID = UUID(
            uuidString: "D6200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let source: MultichannelCalibrationSource =
            .speaker(.frontLeft)

        let ordinary = SemanticSpeakerCalibration(
            trimDB: -0.5,
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
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr107-fir-apply-output",
                        channelIndex: 0
                    ),
                    calibration: ordinary
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr107-fir-apply-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let profile = PlaybackSystemProfile(
            id: playbackID,
            name: "PR107 FIR Apply",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(enabled: false),
                outputDeviceProfile: output
            )
        )
        let route = output.multichannelCalibrationRoutingSignature
        var taps = [Float](repeating: 0, count: 257)
        taps[128] = 1
        let candidate = SpeakerOptimizerFIRCandidatePlan(
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
                    frequenciesHz: [500, 1_000, 2_000, 4_000, 8_000],
                    modeledFilterMagnitudeDB: [0, 0, 0, 0, 0],
                    weightedRMSEBeforeDB: 3,
                    predictedWeightedRMSEAfterDB: 1.5,
                    worstSeatRegressionDB: 0,
                    maximumPositiveGainDB: 0.5,
                    recommendedHeadroomDB: 1.0,
                    acceptedForPreview: true,
                    blockingReasons: []
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
                    frequenciesHz: [500, 1_000, 2_000, 4_000, 8_000],
                    points: [500, 1_000, 2_000, 4_000, 8_000].map {
                        SpeakerOptimizerCrossDomainPoint(
                            frequencyHz: Double($0),
                            characterizationResidualDB: 2,
                            listeningMeanResidualDB: 2,
                            listeningSeatSpreadDB: 0.1,
                            classification: .speakerPersistent
                        )
                    },
                    characterizationCaptureCount: 3,
                    listeningSeatCount: 3
                )
            ],
            warnings: []
        )
        let plan = SpeakerOptimizerClassificationAwareFIRPlan(
            classification: classification,
            candidate: candidate
        )
        let planner = SpeakerOptimizerCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            plan: plan,
            createdAt: Date(timeIntervalSince1970: 1_703_990_000)
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            approvedAt: Date(timeIntervalSince1970: 1_703_990_100),
            userInitiated: true
        )
        return (profile, plan, proposal, approval)
    }
}

@MainActor
private final class FIRFakeProfileStore:
    SpeakerOptimizerPEQProfileMutating {
    enum FakeError: Error {
        case replaceFailed
    }

    var profile: PlaybackSystemProfile?
    var lifecycleState: AudioLifecycleState = .idle
    var failNextReplace = false
    var replaceCount = 0

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
        replaceCount += 1
        if failNextReplace {
            failNextReplace = false
            throw FakeError.replaceFailed
        }
        guard profile != nil else {
            throw FakeError.replaceFailed
        }
        profile?.state.outputDeviceProfile = configuration
    }
}
