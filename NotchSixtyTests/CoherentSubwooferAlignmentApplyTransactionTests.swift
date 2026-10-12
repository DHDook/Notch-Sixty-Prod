import XCTest
@testable import NotchSixty

@MainActor
final class CoherentSubwooferAlignmentApplyTransactionTests:
    XCTestCase {
    func testLateSubApplyAddsCommonSpeakerDelayAndRollbackRestoresSnapshot()
        throws {
        let fixture = try makeFixture(arrivalMilliseconds: 3.0)
        let store = PR108FakeProfileStore(profile: fixture.profile)
        let transaction =
            CoherentSubwooferAlignmentApplyTransaction()

        let receipt = try transaction.apply(
            profileStore: store,
            proposal: fixture.proposal,
            approval: fixture.approval,
            appliedAt: Date(timeIntervalSince1970: 30)
        )

        let output = try XCTUnwrap(
            store.profile?.state.outputDeviceProfile
        )
        let leftCalibration = try XCTUnwrap(
            output.speakerAssignments[0].calibration
        )
        let rightCalibration = try XCTUnwrap(
            output.speakerAssignments[1].calibration
        )
        let subCalibration = try XCTUnwrap(
            output.subwooferAssignments[0].calibration
        )
        XCTAssertEqual(
            leftCalibration.delayMilliseconds,
            3.5,
            accuracy: 0.05
        )
        XCTAssertEqual(
            rightCalibration.delayMilliseconds,
            4.0,
            accuracy: 0.05
        )
        XCTAssertEqual(
            subCalibration.delayMilliseconds,
            0.75,
            accuracy: 0.001
        )
        XCTAssertFalse(subCalibration.polarityInverted)
        XCTAssertEqual(
            store.profile?.state,
            receipt.expectedAppliedState
        )
        let deployment = try XCTUnwrap(
            output.coherentSubwooferAlignment
        )
        XCTAssertEqual(deployment.applyReceiptID, receipt.id)
        XCTAssertTrue(deployment.provisional)
        XCTAssertFalse(deployment.verified)
        XCTAssertTrue(deployment.validate(profile: output))
        XCTAssertTrue(receipt.requiresMeasuredVerification)
        XCTAssertFalse(receipt.isMeasuredVerification)

        let rollback = try transaction.rollback(
            receipt,
            profileStore: store,
            rolledBackAt: Date(timeIntervalSince1970: 40)
        )
        XCTAssertEqual(
            rollback.restoredState,
            fixture.profile.state
        )
        XCTAssertEqual(store.profile?.state, fixture.profile.state)
    }

    func testEarlySubApplyAddsOnlyPhysicalSubDelay() throws {
        let fixture = try makeFixture(arrivalMilliseconds: -2.0)
        let store = PR108FakeProfileStore(profile: fixture.profile)

        _ = try CoherentSubwooferAlignmentApplyTransaction()
            .apply(
                profileStore: store,
                proposal: fixture.proposal,
                approval: fixture.approval
            )

        let output = try XCTUnwrap(
            store.profile?.state.outputDeviceProfile
        )
        let leftCalibration = try XCTUnwrap(
            output.speakerAssignments[0].calibration
        )
        let rightCalibration = try XCTUnwrap(
            output.speakerAssignments[1].calibration
        )
        let subCalibration = try XCTUnwrap(
            output.subwooferAssignments[0].calibration
        )
        XCTAssertEqual(
            leftCalibration.delayMilliseconds,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            rightCalibration.delayMilliseconds,
            1.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            subCalibration.delayMilliseconds,
            2.75,
            accuracy: 0.05
        )
    }

    func testPolarityCandidateMutatesOnlyPhysicalSubPolarity()
        throws {
        let fixture = try makeFixture(
            arrivalMilliseconds: 0,
            additionalPhaseRadians: Double.pi
        )
        let store = PR108FakeProfileStore(profile: fixture.profile)

        _ = try CoherentSubwooferAlignmentApplyTransaction()
            .apply(
                profileStore: store,
                proposal: fixture.proposal,
                approval: fixture.approval
            )

        let output = try XCTUnwrap(
            store.profile?.state.outputDeviceProfile
        )
        XCTAssertTrue(
            try XCTUnwrap(
                output.subwooferAssignments[0]
                    .calibration?.polarityInverted
            )
        )
        XCTAssertEqual(
            output.subwooferAssignments[0]
                .calibration?.gainDB,
            -1
        )
        XCTAssertEqual(
            output.subwooferAssignments[0]
                .calibration?.eqBands,
            fixture.profile.state.outputDeviceProfile?
                .subwooferAssignments[0]
                .calibration?.eqBands
        )
    }

    func testApplyRequiresIdleAndExactCommissioningSnapshot()
        throws {
        let fixture = try makeFixture(arrivalMilliseconds: 3)
        let store = PR108FakeProfileStore(profile: fixture.profile)
        store.lifecycleState = .running

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: fixture.approval
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentSubwooferAlignmentApplyError,
                .lifecycleMustBeIdle(.running)
            )
        }
        XCTAssertEqual(store.replaceCount, 0)

        store.lifecycleState = .idle
        store.profile?.state.outputGainDB = -1
        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: fixture.approval
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentSubwooferAlignmentApplyError,
                .currentStateDrift
            )
        }
        XCTAssertEqual(store.replaceCount, 0)
    }

    func testProvenanceInvalidatesIfLiveCalibrationDrifts()
        throws {
        let fixture = try makeFixture(arrivalMilliseconds: 3)
        let store = PR108FakeProfileStore(profile: fixture.profile)
        let receipt =
            try CoherentSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: fixture.approval
                )

        var output = try XCTUnwrap(
            receipt.expectedAppliedState.outputDeviceProfile
        )
        var sub = try XCTUnwrap(
            output.subwooferAssignments[0].calibration
        )
        sub.delayMilliseconds += 1
        output.subwooferAssignments[0].calibration = sub

        XCTAssertThrowsError(
            try output.validateStructure(
                bassManagementEnabled: true
            )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentDeploymentError,
                .invalidRecord
            )
        }
    }

    func testLegacyOutputProfileWithoutPR108ProvenanceDecodes()
        throws {
        let output = try XCTUnwrap(
            makeProfile().state.outputDeviceProfile
        )
        let encoded = try JSONEncoder().encode(output)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(
            forKey: "coherentSubwooferAlignment"
        )
        let legacy = try JSONSerialization.data(
            withJSONObject: object
        )
        let decoded = try JSONDecoder().decode(
            OutputDeviceProfileConfiguration.self,
            from: legacy
        )
        XCTAssertNil(decoded.coherentSubwooferAlignment)
        XCTAssertEqual(
            decoded.multichannelCalibrationRoutingSignature,
            output.multichannelCalibrationRoutingSignature
        )
    }

    func testStaleApprovalAndPostApplyStateDriftFailClosed()
        throws {
        let fixture = try makeFixture(arrivalMilliseconds: 3)
        let store = PR108FakeProfileStore(profile: fixture.profile)
        var stale = fixture.approval
        stale.candidateFingerprint = "stale"

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: stale
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentCommissioningError,
                .invalidApproval
            )
        }
        XCTAssertEqual(store.replaceCount, 0)

        let receipt =
            try CoherentSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: fixture.proposal,
                    approval: fixture.approval
                )
        store.profile?.state.outputGainDB = -2

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentApplyTransaction()
                .rollback(
                    receipt,
                    profileStore: store
                )
        ) {
            XCTAssertEqual(
                $0 as? CoherentSubwooferAlignmentApplyError,
                .rollbackStateDrift
            )
        }
    }

    private func makeFixture(
        arrivalMilliseconds: Double,
        additionalPhaseRadians: Double = 0
    ) throws -> (
        profile: PlaybackSystemProfile,
        proposal: CoherentSubwooferAlignmentCommissioningProposal,
        approval: CoherentSubwooferAlignmentApproval
    ) {
        let profile = makeProfile()
        let report = makeReport(
            profile: profile,
            arrivalMilliseconds: arrivalMilliseconds,
            additionalPhaseRadians: additionalPhaseRadians
        )
        let output = try XCTUnwrap(
            profile.state.outputDeviceProfile
        )
        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [report],
                profile: output,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )
        let planner =
            CoherentSubwooferAlignmentCommissioningPlanner()
        let proposal = try planner.proposal(
            profile: profile,
            reports: [report],
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
                        deviceUID: "pr108-apply-output",
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
                        deviceUID: "pr108-apply-output",
                        channelIndex: 1
                    ),
                    calibration: SemanticSpeakerCalibration(
                        trimDB: -0.25,
                        delayMilliseconds: 1.0,
                        polarityInverted: false,
                        eqBands: speakerEQ
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-apply-output",
                        channelIndex: 2
                    ),
                    calibration: PhysicalSubwooferCalibration(
                        gainDB: -1,
                        delayMilliseconds: 0.75,
                        polarityInverted: false,
                        eqBands: subEQ
                    )
                )
            ]
        )
        return PlaybackSystemProfile(
            id: UUID(
                uuidString:
                    "E3000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            name: "PR108 Apply",
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
        arrivalMilliseconds: Double,
        additionalPhaseRadians: Double
    ) -> SpeakerMeasurementLabCoherentTimingReport {
        let frequencies = stride(
            from: 40.0,
            through: 140.0,
            by: 5.0
        ).map { $0 }
        let seconds = arrivalMilliseconds / 1_000
        let phases = frequencies.map { frequency in
            let raw =
                -2 * Double.pi * frequency * seconds
                + additionalPhaseRadians
            return atan2(sin(raw), cos(raw))
        }
        return SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(),
            coherentPairID: UUID(),
            playbackSystemID: profile.id,
            routingSignature:
                profile.state.outputDeviceProfile!
                    .multichannelCalibrationRoutingSignature,
            microphone: SpeakerOptimizerMicrophoneIdentity(
                deviceUID: "pr108-apply-mic",
                inputChannelIndex: 0,
                calibrationFingerprint: "pr108-apply-cal"
            ),
            main: .speaker(.frontLeft),
            subwoofer: .subwoofer(0),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians: phases,
            relativeArrivalMilliseconds: arrivalMilliseconds,
            referenceArrivalSpreadMilliseconds: 0.02,
            referenceMagnitudeRepeatabilityRMSDB: 0.05,
            referencePhaseConsistency: 0.999,
            evidenceConfidence: 0.95,
            warnings: []
        )
    }
}

@MainActor
private final class PR108FakeProfileStore:
    CoherentSubwooferAlignmentProfileMutating {
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
