import XCTest
@testable import NotchSixty

@MainActor
final class SpeakerOptimizerFIRPostApplyVerificationTests:
    XCTestCase {
    func testFreshQualifiedVerificationAcceptsTrackedBeneficialFIR() throws {
        let fixture = try makeFixture()
        let report = try SpeakerOptimizerFIRPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )

        XCTAssertTrue(report.isMeasuredVerification)
        XCTAssertTrue(
            report.accepted,
            report.blockingReasons.joined(separator: "; ")
        )
        XCTAssertFalse(report.shouldRollback)
        XCTAssertTrue(report.canFinalizeDeployment)
        let source = try XCTUnwrap(report.sources.first)
        XCTAssertLessThan(source.filterTrackingRMSDB, 0.15)
        XCTAssertGreaterThan(
            source.persistentImprovementDB,
            0.10
        )
    }

    func testNoAcousticFIRChangeRecommendsRollback() throws {
        let fixture = try makeFixture(
            applyFilterToVerification: false
        )
        let report = try SpeakerOptimizerFIRPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )

        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.shouldRollback)
        XCTAssertFalse(report.canFinalizeDeployment)
    }

    func testGlobalMeasurementOffsetDoesNotCreateFalseFIRFailure() throws {
        let fixture = try makeFixture(
            verificationGlobalOffsetDB: 2.0
        )
        let report = try SpeakerOptimizerFIRPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )
        XCTAssertTrue(
            report.accepted,
            report.blockingReasons.joined(separator: "; ")
        )
        XCTAssertLessThan(
            try XCTUnwrap(report.sources.first)
                .filterTrackingRMSDB,
            0.15
        )
    }

    func testVerificationMustBeFreshPostApplyEvidence() throws {
        var fixture = try makeFixture()
        for index in fixture.verification.captures.indices {
            fixture.verification.captures[index].capturedAt =
                fixture.receipt.appliedAt
        }

        XCTAssertThrowsError(
            try SpeakerOptimizerFIRPostApplyVerifier().verify(
                baseline: fixture.baseline,
                verification: fixture.verification,
                plan: fixture.plan,
                receipt: fixture.receipt
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerPostApplyVerificationError,
                .verificationNotPostApply
            )
        }
    }

    func testAcceptedFIRVerificationPersistsAndRollbackStillRestoresSnapshot() throws {
        let fixture = try makeFixture()
        let report = try SpeakerOptimizerFIRPostApplyVerifier().verify(
            baseline: fixture.baseline,
            verification: fixture.verification,
            plan: fixture.plan,
            receipt: fixture.receipt
        )
        XCTAssertTrue(report.accepted)

        let store = FIRVerificationFakeProfileStore(
            profile: PlaybackSystemProfile(
                id: fixture.receipt.playbackSystemID,
                name: "Verified FIR",
                state: fixture.receipt.expectedAppliedState
            )
        )
        let transaction = SpeakerOptimizerFIRApplyTransaction()
        let finalized = try transaction.finalizeVerified(
            report,
            receipt: fixture.receipt,
            profileStore: store,
            verifiedAt: Date(
                timeIntervalSince1970: 1_704_110_000
            )
        )
        XCTAssertEqual(
            finalized.verification
                .verificationMeasurementSetID,
            fixture.verification.id
        )
        XCTAssertEqual(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerFIR?.verification?
                .applyReceiptID,
            fixture.receipt.id
        )

        let rollback = try transaction.rollback(
            fixture.receipt,
            profileStore: store,
            rolledBackAt: Date(
                timeIntervalSince1970: 1_704_110_100
            )
        )
        XCTAssertEqual(
            rollback.restoredState,
            fixture.receipt.rollbackSnapshot.playbackSystemState
        )
        XCTAssertNil(
            store.profile?.state.outputDeviceProfile?
                .speakerOptimizerFIR
        )
    }

    private func makeFixture(
        applyFilterToVerification: Bool = true,
        verificationGlobalOffsetDB: Double = 0
    ) throws -> (
        baseline: SpeakerOptimizerMeasurementSet,
        verification: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        receipt: SpeakerOptimizerFIRApplyReceipt
    ) {
        let playbackID = UUID(
            uuidString:
                "D7000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let baselineID = UUID(
            uuidString:
                "D7100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let characterizationID = UUID(
            uuidString:
                "D7200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let verificationID = UUID(
            uuidString:
                "D7300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
        )!
        let source: MultichannelCalibrationSource =
            .speaker(.frontLeft)
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr107-fir-verification-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: nil
        )
        let seats = [
            SpeakerOptimizerMeasurementPosition(
                id: UUID(
                    uuidString:
                        "D7400000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
                )!,
                name: "Main"
            ),
            SpeakerOptimizerMeasurementPosition(
                id: UUID(
                    uuidString:
                        "D7500000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
                )!,
                name: "Second"
            ),
        ]
        let frequencies = (0..<96).map { index in
            350 * pow(
                12_000.0 / 350.0,
                Double(index) / 95.0
            )
        }

        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID:
                            "pr107-fir-verification-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID:
                            "pr107-fir-verification-output",
                        channelIndex: 1
                    )
                ),
            ]
        )
        let route =
            output.multichannelCalibrationRoutingSignature
        let profile = PlaybackSystemProfile(
            id: playbackID,
            name: "FIR Verification System",
            state: PlaybackSystemState(
                bassManagement:
                    BassManagementConfiguration(enabled: false),
                outputDeviceProfile: output
            )
        )

        var taps = [Float](repeating: 0, count: 257)
        taps[128] = 0.8
        taps[121] = 0.1
        taps[135] = 0.1
        let expected = firMagnitude(
            taps: taps,
            frequencies: frequencies,
            sampleRate: 48_000
        )

        let candidate = SpeakerOptimizerFIRCandidatePlan(
            baselineMeasurementSetID: baselineID,
            playbackSystemID: playbackID,
            routingSignature: route,
            sampleRate: 48_000,
            evidenceConfidence: 0.95,
            requestedTapCount: taps.count,
            declaredGroupDelayFrames: 128,
            declaredGroupDelayMilliseconds:
                128.0 / 48_000 * 1_000,
            sources: [
                SpeakerOptimizerFIRSourceCandidate(
                    source: source,
                    taps: taps,
                    frequenciesHz: frequencies,
                    modeledFilterMagnitudeDB: expected,
                    weightedRMSEBeforeDB: 3,
                    predictedWeightedRMSEAfterDB: 1,
                    worstSeatRegressionDB: 0,
                    maximumPositiveGainDB: 0,
                    recommendedHeadroomDB: 0,
                    acceptedForPreview: true,
                    blockingReasons: []
                )
            ]
        )
        let classification = SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID:
                characterizationID,
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
                    listeningSeatCount: seats.count
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
            createdAt: Date(
                timeIntervalSince1970: 1_704_100_000
            )
        )
        let approval = try planner.makeExplicitApproval(
            proposal: proposal,
            approvedAt: Date(
                timeIntervalSince1970: 1_704_100_100
            ),
            userInitiated: true
        )
        let deployment =
            try planner.makeFIRDeploymentConfiguration(
                profile: profile,
                plan: plan,
                proposal: proposal,
                approval: approval
            )
        var expectedState = profile.state
        var expectedOutput = try XCTUnwrap(
            expectedState.outputDeviceProfile
        )
        expectedOutput.speakerOptimizerFIR = deployment
        expectedState.outputDeviceProfile = expectedOutput
        let appliedAt = Date(
            timeIntervalSince1970: 1_704_100_200
        )
        let receipt = SpeakerOptimizerFIRApplyReceipt(
            appliedAt: appliedAt,
            proposalID: proposal.id,
            playbackSystemID: playbackID,
            baselineMeasurementSetID: baselineID,
            characterizationMeasurementSetID:
                characterizationID,
            routingSignature: route,
            aggregateCandidateFingerprint:
                approval.aggregateCandidateFingerprint,
            deployment: deployment,
            rollbackSnapshot: proposal.rollbackSnapshot,
            expectedAppliedState: expectedState
        )

        var baselineCaptures:
            [SpeakerOptimizerMeasurementCapture] = []
        var verificationCaptures:
            [SpeakerOptimizerMeasurementCapture] = []

        for (seatIndex, seat) in seats.enumerated() {
            for repeatIndex in 0..<3 {
                let repeatOffset =
                    Double(repeatIndex - 1) * 0.01
                let seatOffset =
                    Double(seatIndex) * 0.03
                let baselineMagnitude =
                    frequencies.indices.map { index in
                        -expected[index]
                            + repeatOffset
                            + seatOffset
                    }
                let verificationMagnitude =
                    frequencies.indices.map { index in
                        baselineMagnitude[index]
                            + (applyFilterToVerification
                                ? expected[index] : 0)
                            + verificationGlobalOffsetDB
                    }

                baselineCaptures.append(
                    capture(
                        playbackID: playbackID,
                        route: route,
                        microphone: mic,
                        positionID: seat.id,
                        source: source,
                        frequencies: frequencies,
                        magnitudeDB: baselineMagnitude,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_704_099_000
                                + Double(
                                    seatIndex * 10
                                    + repeatIndex
                                )
                        ),
                        repeatIndex: repeatIndex
                    )
                )
                verificationCaptures.append(
                    capture(
                        playbackID: playbackID,
                        route: route,
                        microphone: mic,
                        positionID: seat.id,
                        source: source,
                        frequencies: frequencies,
                        magnitudeDB:
                            verificationMagnitude,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                1_704_101_000
                                + Double(
                                    seatIndex * 10
                                    + repeatIndex
                                )
                        ),
                        repeatIndex: repeatIndex
                    )
                )
            }
        }

        return (
            SpeakerOptimizerMeasurementSet(
                id: baselineID,
                role: .baseline,
                playbackSystemID: playbackID,
                routingSignature: route,
                microphone: mic,
                sampleRate: 48_000,
                positions: seats,
                plannedSources: [source],
                captures: baselineCaptures
            ),
            SpeakerOptimizerMeasurementSet(
                id: verificationID,
                role: .verification,
                playbackSystemID: playbackID,
                routingSignature: route,
                microphone: mic,
                sampleRate: 48_000,
                positions: seats,
                plannedSources: [source],
                captures: verificationCaptures
            ),
            plan,
            receipt
        )
    }

    private func firMagnitude(
        taps: [Float],
        frequencies: [Double],
        sampleRate: Double
    ) -> [Double] {
        frequencies.map { frequency in
            let omega =
                2 * Double.pi * frequency / sampleRate
            var real = 0.0
            var imaginary = 0.0
            for (index, tap) in taps.enumerated() {
                let phase = omega * Double(index)
                real += Double(tap) * cos(phase)
                imaginary -=
                    Double(tap) * sin(phase)
            }
            return 20 * log10(
                max(hypot(real, imaginary), 1.0e-12)
            )
        }
    }

    private func capture(
        playbackID: UUID,
        route: String,
        microphone: SpeakerOptimizerMicrophoneIdentity,
        positionID: UUID,
        source: MultichannelCalibrationSource,
        frequencies: [Double],
        magnitudeDB: [Double],
        capturedAt: Date,
        repeatIndex: Int
    ) -> SpeakerOptimizerMeasurementCapture {
        SpeakerOptimizerMeasurementCapture(
            capturedAt: capturedAt,
            playbackSystemID: playbackID,
            routingSignature: route,
            microphone: microphone,
            positionID: positionID,
            source: source,
            sampleRate: 48_000,
            response: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: magnitudeDB,
                phaseRadians: frequencies.map {
                    0.03 * log2($0 / 1_000)
                        + Double(repeatIndex - 1)
                            * 0.002
                }
            ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -20,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -72,
                estimatedSNRDB: 58,
                sweepComplete: true,
                directArrivalSeconds:
                    0.010
                    + Double(repeatIndex) * 0.00002,
                usableLowHz: 350,
                usableHighHz: 12_000,
                warnings: []
            )
        )
    }
}

@MainActor
private final class FIRVerificationFakeProfileStore:
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
        guard profile != nil else {
            throw SpeakerOptimizerFIRApplyTransactionError
                .selectedProfileRequired
        }
        profile?.state.outputDeviceProfile =
            configuration
    }
}
