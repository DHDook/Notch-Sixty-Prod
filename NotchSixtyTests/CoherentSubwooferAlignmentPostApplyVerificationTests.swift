import XCTest
@testable import NotchSixty

@MainActor
final class CoherentSubwooferAlignmentPostApplyVerificationTests:
    XCTestCase {
    private let playbackID = UUID(
        uuidString: "E4000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let pairID = UUID(
        uuidString: "E4100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr108-verify-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr108-verify-cal"
    )

    func testFreshSessionAcceptsMeasuredAppliedTimingShift()
        throws {
        let fixture = try makeAppliedFixture()
        let verification = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            acousticMainArrival: 0.013,
            acousticSubArrival: 0.013,
            capturedAtBase: 1_704_900_100
        )

        let report =
            try CoherentSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineReports: fixture.baselineReports,
                    verificationSession: verification,
                    verificationPairIDs: [pairID],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )

        XCTAssertTrue(report.accepted)
        XCTAssertFalse(report.shouldRollback)
        XCTAssertTrue(report.isMeasuredVerification)
        XCTAssertGreaterThan(report.measuredImprovementDB, 1)
        XCTAssertEqual(
            report.coherenceAfterDB,
            0,
            accuracy: 0.1
        )
        let source = try XCTUnwrap(report.sources.first)
        XCTAssertLessThan(
            source.phaseTrackingRMSRadians,
            0.05
        )
        XCTAssertLessThan(
            source.magnitudeTrackingRMSDB,
            0.05
        )
    }

    func testFreshSessionThatDoesNotTrackAppliedDelayIsRejected()
        throws {
        let fixture = try makeAppliedFixture()
        let verification = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            acousticMainArrival: 0.010,
            acousticSubArrival: 0.013,
            capturedAtBase: 1_704_900_100
        )

        let report =
            try CoherentSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineReports: fixture.baselineReports,
                    verificationSession: verification,
                    verificationPairIDs: [pairID],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )

        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.shouldRollback)
        XCTAssertTrue(report.blockingReasons.contains {
            $0.contains("relative-phase change")
                || $0.contains("improved by only")
        })
    }

    func testVerificationCapturesMustAllBeAfterApply() throws {
        let fixture = try makeAppliedFixture()
        let stale = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            acousticMainArrival: 0.013,
            acousticSubArrival: 0.013,
            capturedAtBase: 1_704_899_900
        )

        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineReports: fixture.baselineReports,
                    verificationSession: stale,
                    verificationPairIDs: [pairID],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentVerificationError,
                .verificationNotPostApply
            )
        }
    }

    func testVerificationRejectsCurrentStateAndBaselineDrift()
        throws {
        let fixture = try makeAppliedFixture()
        let verification = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            acousticMainArrival: 0.013,
            acousticSubArrival: 0.013,
            capturedAtBase: 1_704_900_100
        )

        var drifted = try XCTUnwrap(fixture.store.profile)
        drifted.state.outputGainDB = -1
        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineReports: fixture.baselineReports,
                    verificationSession: verification,
                    verificationPairIDs: [pairID],
                    currentProfile: drifted,
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentVerificationError,
                .currentStateDrift
            )
        }

        var changedBaseline = fixture.baselineReports
        changedBaseline[0].wrappedRelativePhaseRadians[5]
            += 0.01
        XCTAssertThrowsError(
            try CoherentSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineReports: changedBaseline,
                    verificationSession: verification,
                    verificationPairIDs: [pairID],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentSubwooferAlignmentVerificationError,
                .baselineEvidenceMismatch
            )
        }
    }

    private func makeAppliedFixture() throws -> (
        baselineReports:
            [SpeakerMeasurementLabCoherentTimingReport],
        store: PR108VerificationFakeStore,
        receipt: CoherentSubwooferAlignmentApplyReceipt
    ) {
        let profile = makeProfile()
        let baseline = makeBaselineReport(
            routingSignature:
                profile.state.outputDeviceProfile!
                    .multichannelCalibrationRoutingSignature
        )
        let output = try XCTUnwrap(
            profile.state.outputDeviceProfile
        )
        let candidate = try CoherentSubwooferAlignmentPlanner()
            .propose(
                reports: [baseline],
                profile: output,
                bassManagementEnabled: true,
                crossoverFrequencyHz: 80
            )
        XCTAssertEqual(
            candidate.signedRelativeDelayAdjustmentMilliseconds,
            -3,
            accuracy: 0.04
        )

        let commissioning =
            CoherentSubwooferAlignmentCommissioningPlanner()
        let proposal = try commissioning.proposal(
            profile: profile,
            reports: [baseline],
            candidate: candidate
        )
        let approval = try commissioning.makeExplicitApproval(
            proposal: proposal,
            userInitiated: true
        )

        let store = PR108VerificationFakeStore(profile: profile)
        let receipt =
            try CoherentSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: proposal,
                    approval: approval,
                    appliedAt: Date(
                        timeIntervalSince1970: 1_704_900_000
                    )
                )
        return ([baseline], store, receipt)
    }

    private func makeProfile() -> PlaybackSystemProfile {
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-verify-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-verify-output",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-verify-output",
                        channelIndex: 2
                    )
                )
            ]
        )
        return PlaybackSystemProfile(
            id: playbackID,
            name: "PR108 Verification",
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

    private func makeBaselineReport(
        routingSignature: String
    ) -> SpeakerMeasurementLabCoherentTimingReport {
        let frequencies = self.frequencies
        let seconds = 0.003
        return SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(
                uuidString:
                    "E4200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            coherentPairID: UUID(
                uuidString:
                    "E4300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            playbackSystemID: playbackID,
            routingSignature: routingSignature,
            microphone: mic,
            main: .speaker(.frontLeft),
            subwoofer: .subwoofer(0),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians:
                frequencies.map {
                    wrapped(
                        -2 * Double.pi * $0 * seconds
                    )
                },
            relativeArrivalMilliseconds: 3,
            referenceArrivalSpreadMilliseconds: 0.02,
            referenceMagnitudeRepeatabilityRMSDB: 0.02,
            referencePhaseConsistency: 0.999,
            evidenceConfidence: 0.95,
            warnings: []
        )
    }

    private func makeVerificationSession(
        routingSignature: String,
        acousticMainArrival: Double,
        acousticSubArrival: Double,
        capturedAtBase: TimeInterval
    ) throws -> SpeakerMeasurementLabSession {
        let request = SpeakerMeasurementLabRequest(
            mode: .coherentMainsSubTiming,
            target: .sourcePair(
                main: .speaker(.frontLeft),
                subwoofer: .subwoofer(0)
            ),
            geometry: SpeakerMeasurementLabGeometry(
                distanceMeters: 2
            ),
            repeatCount: 3
        )
        let protocols = [
            SpeakerMeasurementLabProtocol(
                name: "Fresh Main",
                request: request,
                excitationLevelDBFS: -24,
                coherentPairID: pairID,
                coherentLeg: .main
            ),
            SpeakerMeasurementLabProtocol(
                name: "Fresh Sub",
                request: request,
                excitationLevelDBFS: -24,
                coherentPairID: pairID,
                coherentLeg: .subwoofer
            ),
        ]

        var session = SpeakerMeasurementLabSession(
            id: UUID(
                uuidString:
                    "E4400000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            playbackSystemID: playbackID,
            routingSignature: routingSignature,
            microphone: mic,
            sharedClockReferenceConfiguration:
                SpeakerMeasurementLabSharedClockReferenceConfiguration(
                    inputDeviceUID: mic.deviceUID,
                    inputChannelIndex: 1,
                    outputReferenceDeviceUID:
                        "pr108-verify-output",
                    minimumSNRDB: 35
                ),
            sampleRate: 48_000,
            protocols: protocols,
            captures: []
        )

        for labProtocol in protocols {
            let acousticArrival =
                labProtocol.coherentLeg == .main
                    ? acousticMainArrival
                    : acousticSubArrival
            for repeat in 0..<3 {
                let referenceArrival =
                    0.002 + Double(repeat) * 0.00001
                session.captures.append(
                    SpeakerMeasurementLabCapture(
                        protocolID: labProtocol.id,
                        repeatIndex: repeat,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                capturedAtBase
                                + Double(
                                    (labProtocol.coherentLeg
                                        == .main ? 0 : 10)
                                    + repeat
                                )
                        ),
                        playbackSystemID: playbackID,
                        routingSignature: routingSignature,
                        microphone: mic,
                        excitationLevelDBFS: -24,
                        sampleRate: 48_000,
                        source: labProtocol.captureSource!,
                        sharedClockReference:
                            referenceEvidence(
                                arrival: referenceArrival,
                                repeat: repeat
                            ),
                        impulseResponse: [0, 0.1, 1, 0.2, 0],
                        transferFunction:
                            RoomCorrectionFrequencyResponse(
                                frequenciesHz: frequencies,
                                magnitudeDB:
                                    Array(
                                        repeating: 0,
                                        count: frequencies.count
                                    ),
                                phaseRadians:
                                    Array(
                                        repeating: 0,
                                        count: frequencies.count
                                    )
                            ),
                        quality:
                            RoomCorrectionMeasurementQuality(
                                clipped: false,
                                playbackPeakDBFS: -24,
                                capturePeakDBFS: -12,
                                estimatedNoiseFloorDBFS: -75,
                                estimatedSNRDB: 60,
                                sweepComplete: true,
                                directArrivalSeconds:
                                    acousticArrival
                                    + Double(repeat) * 0.00001,
                                usableLowHz: 40,
                                usableHighHz: 140,
                                warnings: []
                            )
                    )
                )
            }
        }
        try session.validateStructure()
        return session
    }

    private func referenceEvidence(
        arrival: Double,
        repeat: Int
    ) -> SpeakerMeasurementLabSharedClockReferenceEvidence {
        SpeakerMeasurementLabSharedClockReferenceEvidence(
            inputDeviceUID: mic.deviceUID,
            inputChannelIndex: 1,
            outputReferenceDeviceUID: "pr108-verify-output",
            sampleRate: 48_000,
            directArrivalSeconds: arrival,
            transferFunction:
                RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: Array(
                        repeating: Double(repeat - 1) * 0.005,
                        count: frequencies.count
                    ),
                    phaseRadians: Array(
                        repeating: Double(repeat - 1) * 0.002,
                        count: frequencies.count
                    )
                ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -24,
                capturePeakDBFS: -8,
                estimatedNoiseFloorDBFS: -75,
                estimatedSNRDB: 65,
                sweepComplete: true,
                directArrivalSeconds: arrival,
                usableLowHz: 40,
                usableHighHz: 140,
                warnings: []
            )
        )
    }

    private var frequencies: [Double] {
        stride(from: 40.0, through: 140.0, by: 5.0)
            .map { $0 }
    }

    private func wrapped(_ value: Double) -> Double {
        atan2(sin(value), cos(value))
    }
}

@MainActor
private final class PR108VerificationFakeStore:
    CoherentSubwooferAlignmentProfileMutating {
    var profile: PlaybackSystemProfile?
    var coherentAlignmentLifecycleState:
        AudioLifecycleState = .idle

    init(profile: PlaybackSystemProfile?) {
        self.profile = profile
    }

    var coherentAlignmentSelectedSystemProfile:
        PlaybackSystemProfile? {
        profile
    }

    func coherentAlignmentReplaceOutputDeviceProfile(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        profile?.state.outputDeviceProfile = configuration
    }
}
