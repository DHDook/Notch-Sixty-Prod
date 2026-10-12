import XCTest
@testable import NotchSixty

@MainActor
final class CoherentMultiSubwooferAlignmentPostApplyVerificationTests:
    XCTestCase {
    private let playbackID = UUID(
        uuidString: "E8000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let pair0 = UUID(
        uuidString: "E8100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let pair1 = UUID(
        uuidString: "E8200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
    )!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr108-multi-verify-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr108-multi-verify-cal"
    )

    func testFreshCoordinatedSessionAcceptsEveryAppliedSubSignature()
        throws {
        let fixture = try makeAppliedFixture()
        let session = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            subArrivals: [0: 0.013, 1: 0.013],
            capturedAtBase: 1_705_100_100
        )

        let report =
            try CoherentMultiSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineEvidenceGroups:
                        fixture.baselineGroups,
                    verificationSession: session,
                    verificationPairIDsBySubwoofer: [
                        0: [pair0],
                        1: [pair1],
                    ],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )

        XCTAssertTrue(report.accepted)
        XCTAssertFalse(report.shouldRollback)
        XCTAssertTrue(report.isMeasuredVerification)
        XCTAssertEqual(report.sources.count, 2)
        XCTAssertEqual(report.subwooferIndices, [0, 1])
        XCTAssertGreaterThan(report.measuredImprovementDB, 1)
        XCTAssertEqual(report.coherenceAfterDB, 0, accuracy: 0.1)
        XCTAssertTrue(report.sources.allSatisfy {
            $0.phaseTrackingRMSRadians < 0.05
                && $0.magnitudeTrackingRMSDB < 0.05
        })
    }

    func testOneUncorrectedSubRejectsWholeCoordinatedVerification()
        throws {
        let fixture = try makeAppliedFixture()
        let session = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            subArrivals: [
                0: 0.013,
                1: 0.011, // preserves the pre-Apply -2 ms Sub 2 arrival
            ],
            capturedAtBase: 1_705_100_100
        )

        let report =
            try CoherentMultiSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineEvidenceGroups:
                        fixture.baselineGroups,
                    verificationSession: session,
                    verificationPairIDsBySubwoofer: [
                        0: [pair0],
                        1: [pair1],
                    ],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )

        XCTAssertFalse(report.accepted)
        XCTAssertTrue(report.shouldRollback)
        let sub1 = try XCTUnwrap(
            report.sources.first { $0.subwooferIndex == 1 }
        )
        XCTAssertFalse(sub1.accepted)
        XCTAssertTrue(sub1.blockingReasons.contains {
            $0.contains("relative-phase change")
        })
    }

    func testPairSetAndFreshnessMustCoverEverySub() throws {
        let fixture = try makeAppliedFixture()
        let fresh = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            subArrivals: [0: 0.013, 1: 0.013],
            capturedAtBase: 1_705_100_100
        )

        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineEvidenceGroups:
                        fixture.baselineGroups,
                    verificationSession: fresh,
                    verificationPairIDsBySubwoofer: [
                        0: [pair0]
                    ],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentVerificationError,
                .pairSetMismatch
            )
        }

        let stale = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            subArrivals: [0: 0.013, 1: 0.013],
            capturedAtBase: 1_705_099_900
        )
        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineEvidenceGroups:
                        fixture.baselineGroups,
                    verificationSession: stale,
                    verificationPairIDsBySubwoofer: [
                        0: [pair0],
                        1: [pair1],
                    ],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentVerificationError,
                .verificationNotPostApply
            )
        }
    }

    func testBaselineAndCurrentStateDriftFailClosed() throws {
        let fixture = try makeAppliedFixture()
        let session = try makeVerificationSession(
            routingSignature:
                fixture.receipt.candidate.routingSignature,
            subArrivals: [0: 0.013, 1: 0.013],
            capturedAtBase: 1_705_100_100
        )

        var drifted = try XCTUnwrap(fixture.store.profile)
        drifted.state.outputGainDB = -1
        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineEvidenceGroups:
                        fixture.baselineGroups,
                    verificationSession: session,
                    verificationPairIDsBySubwoofer: [
                        0: [pair0],
                        1: [pair1],
                    ],
                    currentProfile: drifted,
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentVerificationError,
                .currentStateDrift
            )
        }

        var changed = fixture.baselineGroups
        changed[1].reports[0]
            .wrappedRelativePhaseRadians[5] += 0.01
        XCTAssertThrowsError(
            try CoherentMultiSubwooferAlignmentPostApplyVerifier()
                .verify(
                    baselineEvidenceGroups: changed,
                    verificationSession: session,
                    verificationPairIDsBySubwoofer: [
                        0: [pair0],
                        1: [pair1],
                    ],
                    currentProfile:
                        try XCTUnwrap(fixture.store.profile),
                    receipt: fixture.receipt
                )
        ) {
            XCTAssertEqual(
                $0 as?
                    CoherentMultiSubwooferAlignmentVerificationError,
                .baselineEvidenceMismatch
            )
        }
    }

    private func makeAppliedFixture() throws -> (
        baselineGroups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup],
        store: PR108MultiVerificationFakeStore,
        receipt: CoherentMultiSubwooferAlignmentApplyReceipt
    ) {
        let profile = makeProfile()
        let groups = [
            baselineGroup(
                profile: profile,
                subwooferIndex: 0,
                arrivalMilliseconds: 3
            ),
            baselineGroup(
                profile: profile,
                subwooferIndex: 1,
                arrivalMilliseconds: -2
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
        let commissioning =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()
        let proposal = try commissioning.proposal(
            profile: profile,
            evidenceGroups: groups,
            candidate: candidate
        )
        let approval = try commissioning.makeExplicitApproval(
            proposal: proposal,
            userInitiated: true
        )
        let store =
            PR108MultiVerificationFakeStore(profile: profile)
        let receipt =
            try CoherentMultiSubwooferAlignmentApplyTransaction()
                .apply(
                    profileStore: store,
                    proposal: proposal,
                    approval: approval,
                    appliedAt: Date(
                        timeIntervalSince1970: 1_705_100_000
                    )
                )
        return (groups, store, receipt)
    }

    private func makeProfile() -> PlaybackSystemProfile {
        let output = OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-verify-output",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-verify-output",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-verify-output",
                        channelIndex: 2
                    )
                ),
                PhysicalSubwooferOutputAssignment(
                    index: 1,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "pr108-multi-verify-output",
                        channelIndex: 3
                    )
                ),
            ]
        )
        return PlaybackSystemProfile(
            id: playbackID,
            name: "PR108 Multi Verification",
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

    private func baselineGroup(
        profile: PlaybackSystemProfile,
        subwooferIndex: UInt32,
        arrivalMilliseconds: Double
    ) -> CoherentMultiSubwooferAlignmentEvidenceGroup {
        let seconds = arrivalMilliseconds / 1_000
        let report = SpeakerMeasurementLabCoherentTimingReport(
            sessionID: UUID(),
            coherentPairID: UUID(),
            playbackSystemID: profile.id,
            routingSignature:
                profile.state.outputDeviceProfile!
                    .multichannelCalibrationRoutingSignature,
            microphone: mic,
            main: .speaker(.frontLeft),
            subwoofer: .subwoofer(subwooferIndex),
            sampleRate: 48_000,
            frequenciesHz: frequencies,
            relativeMagnitudeDB:
                Array(repeating: 0, count: frequencies.count),
            wrappedRelativePhaseRadians:
                frequencies.map { frequency in
                    wrapped(
                        -2 * Double.pi
                        * frequency * seconds
                    )
                },
            relativeArrivalMilliseconds:
                arrivalMilliseconds,
            referenceArrivalSpreadMilliseconds: 0.02,
            referenceMagnitudeRepeatabilityRMSDB: 0.02,
            referencePhaseConsistency: 0.999,
            evidenceConfidence: 0.95,
            warnings: []
        )
        return CoherentMultiSubwooferAlignmentEvidenceGroup(
            subwooferIndex: subwooferIndex,
            reports: [report]
        )
    }

    private func makeVerificationSession(
        routingSignature: String,
        subArrivals: [UInt32: Double],
        capturedAtBase: TimeInterval
    ) throws -> SpeakerMeasurementLabSession {
        let pairMap: [(UInt32, UUID)] = [
            (0, pair0),
            (1, pair1),
        ]
        var protocols: [SpeakerMeasurementLabProtocol] = []
        for (subIndex, pairID) in pairMap {
            let request = SpeakerMeasurementLabRequest(
                mode: .coherentMainsSubTiming,
                target: .sourcePair(
                    main: .speaker(.frontLeft),
                    subwoofer: .subwoofer(subIndex)
                ),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 2
                ),
                repeatCount: 3
            )
            protocols.append(
                SpeakerMeasurementLabProtocol(
                    name: "Main vs Sub \(subIndex + 1)",
                    request: request,
                    excitationLevelDBFS: -24,
                    coherentPairID: pairID,
                    coherentLeg: .main
                )
            )
            protocols.append(
                SpeakerMeasurementLabProtocol(
                    name: "Sub \(subIndex + 1)",
                    request: request,
                    excitationLevelDBFS: -24,
                    coherentPairID: pairID,
                    coherentLeg: .subwoofer
                )
            )
        }

        var session = SpeakerMeasurementLabSession(
            id: UUID(
                uuidString:
                    "E8300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD"
            )!,
            playbackSystemID: playbackID,
            routingSignature: routingSignature,
            microphone: mic,
            sharedClockReferenceConfiguration:
                SpeakerMeasurementLabSharedClockReferenceConfiguration(
                    inputDeviceUID: mic.deviceUID,
                    inputChannelIndex: 1,
                    outputReferenceDeviceUID:
                        "pr108-multi-verify-output",
                    minimumSNRDB: 35
                ),
            sampleRate: 48_000,
            protocols: protocols,
            captures: []
        )

        for (protocolOffset, labProtocol)
            in protocols.enumerated() {
            let subIndex: UInt32
            guard case .sourcePair(_, .subwoofer(let index))
                    = labProtocol.request.target else {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .verificationSessionInvalid
            }
            subIndex = index
            let acousticArrival =
                labProtocol.coherentLeg == .main
                    ? 0.013
                    : try XCTUnwrap(subArrivals[subIndex])
            for repeatIndex in 0..<3 {
                let referenceArrival =
                    0.002 + Double(repeatIndex) * 0.00001
                session.captures.append(
                    SpeakerMeasurementLabCapture(
                        protocolID: labProtocol.id,
                        repeatIndex: repeatIndex,
                        capturedAt: Date(
                            timeIntervalSince1970:
                                capturedAtBase
                                + Double(
                                    protocolOffset * 10
                                        + repeatIndex
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
                                repeatIndex: repeatIndex
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
                                    + Double(repeatIndex)
                                        * 0.00001,
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
        repeatIndex: Int
    ) -> SpeakerMeasurementLabSharedClockReferenceEvidence {
        SpeakerMeasurementLabSharedClockReferenceEvidence(
            inputDeviceUID: mic.deviceUID,
            inputChannelIndex: 1,
            outputReferenceDeviceUID:
                "pr108-multi-verify-output",
            sampleRate: 48_000,
            directArrivalSeconds: arrival,
            transferFunction:
                RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: Array(
                        repeating:
                            Double(repeatIndex - 1) * 0.005,
                        count: frequencies.count
                    ),
                    phaseRadians: Array(
                        repeating:
                            Double(repeatIndex - 1) * 0.002,
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
private final class PR108MultiVerificationFakeStore:
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
