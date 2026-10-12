import XCTest
@testable import NotchSixty

@MainActor
final class CoherentMultiSubwooferAlignmentApplyTransactionTests:
    XCTestCase {
    func testApplyMaterializesSharedDelayOnceAndEverySubAtomically()
        throws {
        let fixture = try makeFixture()
        let store = PR108MultiApplyFakeStore(
            profile: fixture.profile
        )
        let transaction =
            CoherentMultiSubwooferAlignmentApplyTransaction()

        let receipt = try transaction.apply(
            profileStore: store,
            proposal: fixture.proposal,
            approval: fixture.approval,
            appliedAt: Date(timeIntervalSince1970: 300)
        )

        let output = try XCTUnwrap(
            store.profile?.state.outputDeviceProfile
        )
        let left = try XCTUnwrap(
            output.speakerAssignments.first {
                $0.role == .frontLeft
            }?.calibration
        )
        let right = try XCTUnwrap(
            output.speakerAssignments.first {
                $0.role == .frontRight
            }?.calibration
        )
        let sub0 = try XCTUnwrap(
            output.subwooferAssignments.first {
                $0.index == 0
            }?.calibration
        )
        let sub1 = try XCTUnwrap(
            output.subwooferAssignments.first {
                $0.index == 1
            }?.calibration
        )

        XCTAssertEqual(left.delayMilliseconds, 3.5, accuracy: 0.05)
        XCTAssertEqual(right.delayMilliseconds, 4.0, accuracy: 0.05)
        XCTAssertEqual(sub0.delayMilliseconds, 0.75, accuracy: 0.05)
        XCTAssertEqual(sub1.delayMilliseconds, 6.25, accuracy: 0.05)

        // Existing non-timing calibration is preserved.
        XCTAssertEqual(left.trimDB, -0.5)
        XCTAssertEqual(sub0.gainDB, -1)
        XCTAssertEqual(sub1.gainDB, -2)
        XCTAssertEqual(sub0.eqBands.count, 1)
        XCTAssertEqual(sub1.eqBands.count, 1)

        let deployment = try XCTUnwrap(
            output.coherentMultiSubwooferAlignment
        )
        XCTAssertNil(output.coherentSubwooferAlignment)
        XCTAssertTrue(deployment.provisional)
        XCTAssertEqual(deployment.applyReceiptID, receipt.id)
        XCTAssertEqual(deployment.subwoofers.count, 2)
        XCTAssertEqual(
            deployment.speakerCommonDelayAdjustmentMilliseconds,
            3,
            accuracy: 0.05
        )
        XCTAssertEqual(store.profile?.state, receipt.expectedAppliedState)
        XCTAssertTrue(receipt.requiresMeasuredVerification)
        XCTAssertFalse(receipt.isMeasuredVerification)

        let rollback = try transaction.rollback(
            receipt,
            profileStore: store,
            rolledBackAt: Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(
            rollback.restoredState,
            fixture.profile.state
        )
        XCTAssertEqual(store.profile?.state, fixture.profile.state)
    }

    func testApplyCarriesIndependentSubPolarity() throws {
        let fixture = try makeFixture(
            sub0ArrivalMilliseconds: 0,
            sub0AdditionalPhaseRadians: Double.pi,
            sub1ArrivalMilliseconds: 2
        )
        let store = PR108MultiApplyFakeStore(
            profile: fixture.profile
        )

        _ = try CoherentMultiSubwooferAlignmentApplyTransaction()
            .apply(
                profileStore: store,
                proposal: fixture.proposal,
                approval: fixture.approval
            )

        let output = try XCTUnwrap(
            store.profile?.state.outputDeviceProfile
        )
        let sub0 = try XCTUnwrap(
            output.subwooferAssignments.first {
                $0.index == 0
            }?.calibration
        )
        let sub1 = try XCTUnwrap(
            output.subwooferAssignments.first {
                $0.index == 1
            }?.calibration
        )
        XCTAssertTrue(sub0.polarityInverted)
        XCTAssertFalse(sub1.polarityInverted)
    }

    func testApplyRequiresIdleExactSnapshotAndFreshApproval()
        throws {
        let fixture = try makeFixture()
        let store = PR108MultiApplyFakeStore(
            profile: fixture.profile
        )
        store.lifecycleState = .running

        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: fixture.approval
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentMultiSubwooferAlignmentApplyError,
                .lifecycleMustBeIdle(.running)
            )
        }
        XCTAssertEqual(store.replaceCount, 0)

        store.lifecycleState = .idle
        store.profile?.state.outputGainDB = -1
        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: fixture.approval
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentMultiSubwooferAlignmentApplyError,
                .currentStateDrift
            )
        }
        XCTAssertEqual(store.replaceCount, 0)

        store.profile = fixture.profile
        var stale = fixture.approval
        stale.candidateFingerprint = "stale"
        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: stale
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentCommissioningError,
                .invalidApproval
            )
        }
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testRollbackRefusesUnrelatedPostApplyEdit() throws {
        let fixture = try makeFixture()
        let store = PR108MultiApplyFakeStore(
            profile: fixture.profile
        )
        let transaction =
            CoherentMultiSubwooferAlignmentApplyTransaction()
        let receipt = try transaction.apply(
            profileStore: store,
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
                $0 as? CoherentMultiSubwooferAlignmentApplyError,
                .rollbackStateDrift
            )
        }
    }

    private func makeFixture(
        sub0ArrivalMilliseconds: Double = 3,
        sub0AdditionalPhaseRadians: Double = 0,
        sub1ArrivalMilliseconds: Double = -2
    ) throws -> (
        profile: PlaybackSystemProfile,
        proposal:
            CoherentMultiSubwooferAlignmentCommissioningProposal,
        approval: CoherentMultiSubwooferAlignmentApproval
    ) {
        let profile = makeProfile()
        let groups = [
            evidenceGroup(
                profile: profile,
                subwooferIndex: 0,
                arrivalMilliseconds:
                    sub0ArrivalMilliseconds,
                additionalPhaseRadians:
                    sub0AdditionalPhaseRadians
            ),
            evidenceGroup(
                profile: profile,
                subwooferIndex: 1,
                arrivalMilliseconds:
                    sub1ArrivalMilliseconds
            ),
        ]
        let output = try XCTUnwrap(
            profile.state.outputDeviceProfile
        )
        let candidate =
            try CoherentMultiSubwooferAlignmentPlanner()
                .propose(
                    evidenceGroups: groups,
                    profile: output,
                    bassManagementEnabled: true,
                    crossoverFrequencyHz: 80
                )
        let planner =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            evidenceGroups: groups,
            candidate: candidate
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            userInitiated: true
        )
        return (profile, proposal, approval)
    }

    private func makeProfile() -> PlaybackSystemProfile {
        let speakerEQ = [
            OutputCalibrationEQBand(
                frequencyHz: 500,
                gainDB: -1,
                q: 1
            )
        ]
        let subEQ = [
            OutputCalibrationEQBand(
                frequencyHz: 45,
                gainDB: -2,
                q: 1.1
            )
        ]
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-apply-output",
                        channelIndex: 0
                    ),
                    calibration: SemanticSpeakerCalibration(
                        trimDB: -0.5,
                        delayMilliseconds: 0.5,
                        polarityInverted: false,
                        eqBands: speakerEQ
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-apply-output",
                        channelIndex: 1
                    ),
                    calibration: SemanticSpeakerCalibration(
                        trimDB: -0.25,
                        delayMilliseconds: 1,
                        polarityInverted: false,
                        eqBands: speakerEQ
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-apply-output",
                        channelIndex: 2
                    ),
                    calibration: PhysicalSubwooferCalibration(
                        gainDB: -1,
                        delayMilliseconds: 0.75,
                        polarityInverted: false,
                        eqBands: subEQ
                    )
                ),
                PhysicalSubwooferOutputAssignment(
                    index: 1,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-apply-output",
                        channelIndex: 3
                    ),
                    calibration: PhysicalSubwooferCalibration(
                        gainDB: -2,
                        delayMilliseconds: 1.25,
                        polarityInverted: false,
                        eqBands: subEQ
                    )
                ),
            ]
        )
        return PlaybackSystemProfile(
            id: UUID(
                uuidString:
                    "E7000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            name: "PR108 Multi Apply",
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

    private func evidenceGroup(
        profile: PlaybackSystemProfile,
        subwooferIndex: UInt32,
        arrivalMilliseconds: Double,
        additionalPhaseRadians: Double = 0
    ) -> CoherentMultiSubwooferAlignmentEvidenceGroup {
        let frequencies = stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
        let seconds = arrivalMilliseconds / 1_000
        let report = SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(),
            coherentPairID: UUID(),
            playbackSystemID: profile.id,
            routingSignature:
                profile.state.outputDeviceProfile!
                    .multichannelCalibrationRoutingSignature,
            microphone: SpeakerOptimizerMicrophoneIdentity(
                deviceUID: "pr108-multi-apply-mic",
                inputChannelIndex: 0,
                calibrationFingerprint: "pr108-multi-apply-cal"
            ),
            main: .speaker(.frontLeft),
            subwoofer: .subwoofer(subwooferIndex),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians:
                frequencies.map { frequency in
                    let raw =
                        -2 * Double.pi * frequency * seconds
                        + additionalPhaseRadians
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
        return CoherentMultiSubwooferAlignmentEvidenceGroup(
            subwooferIndex: subwooferIndex,
            reports: [report]
        )
    }
}

@MainActor
private final class PR108MultiApplyFakeStore:
    CoherentSubwooferAlignmentProfileMutating {
    enum FakeError: Error {
        case replaceFailed
    }

    var profile: PlaybackSystemProfile?
    var lifecycleState: AudioLifecycleState = .idle
    var replaceCount = 0

    init(profile: PlaybackSystemProfile?) {
        self.profile = profile
    }

    var coherentAlignmentSelectedSystemProfile:
        PlaybackSystemProfile? {
        profile
    }

    var coherentAlignmentLifecycleState:
        AudioLifecycleState {
        lifecycleState
    }

    func coherentAlignmentReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        replaceCount += 1
        guard profile != nil else {
            throw FakeError.replaceFailed
        }
        profile?.state.outputDeviceProfile = configuration
    }
}
