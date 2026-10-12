import XCTest
@testable import NotchSixty

@MainActor
final class SpeakerOptimizerPEQApplyTransactionTests: XCTestCase {
    func testApplyInstallsOnlyDedicatedOptimizerPEQAndRollbackRestoresExactSnapshot() throws {
        let fixture = try makeFixture()
        let store = FakeProfileStore(profile: fixture.profile)
        let transaction = SpeakerOptimizerPEQApplyTransaction()
        let ordinaryBefore = fixture.profile.state.outputDeviceProfile?
            .speakerAssignments.first(where: { $0.role == .frontLeft })?
            .calibration

        let receipt = try transaction.apply(
            profileStore: store,
            plan: fixture.plan,
            proposal: fixture.proposal,
            approval: fixture.approval,
            appliedAt: Date(timeIntervalSince1970: 1_703_700_000)
        )

        let applied = try XCTUnwrap(store.profile)
        XCTAssertEqual(
            applied.state.outputDeviceProfile?
                .speakerAssignments.first(where: { $0.role == .frontLeft })?
                .calibration,
            ordinaryBefore,
            "Ordinary Speaker Calibration ownership must remain untouched."
        )
        XCTAssertEqual(
            applied.state.outputDeviceProfile?
                .speakerOptimizerPEQ?.proposalID,
            fixture.proposal.id
        )
        XCTAssertEqual(applied.state, receipt.expectedAppliedState)
        XCTAssertTrue(receipt.requiresMeasuredVerification)
        XCTAssertFalse(receipt.isMeasuredVerification)

        let rolledBack = try transaction.rollback(
            receipt,
            profileStore: store,
            rolledBackAt: Date(timeIntervalSince1970: 1_703_700_100)
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
            store.profile?.state.outputDeviceProfile?.speakerOptimizerPEQ
        )
    }

    func testApplyRequiresIdleEngineAndExactCommissioningSnapshot() throws {
        let fixture = try makeFixture()
        let store = FakeProfileStore(profile: fixture.profile)
        store.lifecycleState = .running

        XCTAssertThrowsError(
            try SpeakerOptimizerPEQApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: fixture.approval
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPEQApplyTransactionError,
                .lifecycleMustBeIdle(.running)
            )
        }
        XCTAssertEqual(store.replaceCount, 0)

        store.lifecycleState = .idle
        store.profile?.state.outputGainDB = -1
        XCTAssertThrowsError(
            try SpeakerOptimizerPEQApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: fixture.approval
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPEQApplyTransactionError,
                .currentStateDrift
            )
        }
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testApplyRejectsStaleApprovalBeforeMutation() throws {
        let fixture = try makeFixture()
        let store = FakeProfileStore(profile: fixture.profile)
        var stale = fixture.approval
        stale.aggregateCandidateFingerprint = "stale"

        XCTAssertThrowsError(
            try SpeakerOptimizerPEQApplyTransaction().apply(
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
            store.profile?.state.outputDeviceProfile?.speakerOptimizerPEQ
        )
    }

    func testMutationFailureLeavesOriginalSnapshotAndReturnsNoReceipt() throws {
        let fixture = try makeFixture()
        let store = FakeProfileStore(profile: fixture.profile)
        store.failNextReplace = true

        XCTAssertThrowsError(
            try SpeakerOptimizerPEQApplyTransaction().apply(
                profileStore: store,
                plan: fixture.plan,
                proposal: fixture.proposal,
                approval: fixture.approval
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPEQApplyTransactionError,
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
        let store = FakeProfileStore(profile: fixture.profile)
        let transaction = SpeakerOptimizerPEQApplyTransaction()
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
                $0 as? SpeakerOptimizerPEQApplyTransactionError,
                .rollbackStateDrift
            )
        }
        XCTAssertNotNil(
            store.profile?.state.outputDeviceProfile?.speakerOptimizerPEQ
        )
    }

    func testRollbackAlsoRequiresIdleEngine() throws {
        let fixture = try makeFixture()
        let store = FakeProfileStore(profile: fixture.profile)
        let transaction = SpeakerOptimizerPEQApplyTransaction()
        let receipt = try transaction.apply(
            profileStore: store,
            plan: fixture.plan,
            proposal: fixture.proposal,
            approval: fixture.approval
        )
        store.lifecycleState = .running

        XCTAssertThrowsError(
            try transaction.rollback(
                receipt,
                profileStore: store
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPEQApplyTransactionError,
                .lifecycleMustBeIdle(.running)
            )
        }
    }

    private func makeFixture() throws -> (
        profile: PlaybackSystemProfile,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        proposal: SpeakerOptimizerCommissioningProposal,
        approval: SpeakerOptimizerApplyApproval
    ) {
        let playbackID = UUID(
            uuidString: "C6000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let baselineID = UUID(
            uuidString: "C6100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let characterizationID = UUID(
            uuidString: "C6200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
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
                        deviceUID: "pr105-apply-output",
                        channelIndex: 0
                    ),
                    calibration: ordinary
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr105-apply-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let profile = PlaybackSystemProfile(
            id: playbackID,
            name: "PR105 Apply",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(enabled: false),
                outputDeviceProfile: output
            )
        )
        let route = output.multichannelCalibrationRoutingSignature
        let band = try XCTUnwrap(
            SpeakerOptimizerPEQBand.peak(
                centerHz: 2_000,
                q: 1.2,
                gainDB: -3,
                sampleRate: 48_000
            )
        )
        let frequencies = [500.0, 1_000, 2_000, 4_000, 8_000]
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
                        band.magnitudeDB(at: $0, sampleRate: 48_000)
                    },
                    weightedRMSEBeforeDB: 3,
                    predictedWeightedRMSEAfterDB: 1.5,
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
                    listeningSeatCount: 3
                )
            ],
            warnings: []
        )
        let plan = SpeakerOptimizerClassificationAwarePEQPlan(
            classification: classification,
            candidate: candidate
        )
        let planner = SpeakerOptimizerCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            plan: plan,
            createdAt: Date(timeIntervalSince1970: 1_703_690_000)
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            approvedAt: Date(timeIntervalSince1970: 1_703_690_100),
            userInitiated: true
        )
        return (profile, plan, proposal, approval)
    }
}

@MainActor
private final class FakeProfileStore:
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
