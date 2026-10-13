import Foundation
import XCTest
@testable import NotchSixty

final class HardwareAcceptanceEvidenceAdapterTests: XCTestCase {
    private let systemID = UUID(uuidString:
        "112A1000-0000-0000-0000-000000000001")!
    private let positionID = UUID(uuidString:
        "112A1000-0000-0000-0000-000000000002")!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr112a-adapter-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr112a-cal"
    )

    func testQualifiedH03BaselineLinksIdsButStaysRemoteAuthority()
        throws {
        let set = baselineSet()
        let linked = try HardwareAcceptanceEvidenceAdapter()
            .h03Baseline(set)

        XCTAssertEqual(linked.gateID, .h03MeasurementBaselines)
        XCTAssertEqual(linked.recommendedOutcome, .passed)
        XCTAssertEqual(linked.automaticAuthority, .remoteSoftware)
        XCTAssertFalse(linked.canEstablishPhysicalAuthority)
        XCTAssertFalse(linked.canAuthorizeLiveFeedForwardANC)
        XCTAssertTrue(linked.artifacts.contains {
            $0.identifier == set.id.uuidString
        })
        XCTAssertEqual(
            linked.artifacts.count,
            1 + set.captures.count
        )
    }

    func testUnqualifiedH03BaselineRecommendsFailureNotPhysicalPass()
        throws {
        var set = baselineSet()
        set.captures[0].quality.clipped = true
        let linked = try HardwareAcceptanceEvidenceAdapter()
            .h03Baseline(set)

        XCTAssertEqual(linked.recommendedOutcome, .failed)
        XCTAssertEqual(linked.automaticAuthority, .remoteSoftware)
        XCTAssertFalse(linked.canEstablishPhysicalAuthority)
    }

    func testH05RequiresWholeSpeakerAndCompleteRepeatedSession()
        throws {
        let complete = wholeSpeakerLabSession()
        let linked = try HardwareAcceptanceEvidenceAdapter()
            .h05MeasurementLab(complete)
        XCTAssertEqual(linked.gateID, .h05AdvancedMeasurementLab)
        XCTAssertEqual(linked.playbackSystemID, systemID)
        XCTAssertEqual(linked.automaticAuthority, .remoteSoftware)
        XCTAssertFalse(linked.canEstablishPhysicalAuthority)
        XCTAssertTrue(linked.coveredCapabilities.isEmpty)

        var incomplete = complete
        incomplete.captures.removeLast()
        XCTAssertThrowsError(
            try HardwareAcceptanceEvidenceAdapter()
                .h05MeasurementLab(incomplete)
        ) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceEvidenceAdapterError,
                .incompleteLabSession
            )
        }

        var noWholeSpeaker = complete
        noWholeSpeaker.protocols[0].request.mode =
            .subwooferNearField
        noWholeSpeaker.protocols[0].request.target =
            .acousticSource(.subwoofer(0))
        noWholeSpeaker.protocols[0].request.geometry =
            SpeakerMeasurementLabGeometry(
                distanceMeters: 0.1
            )
        for index in noWholeSpeaker.captures.indices {
            noWholeSpeaker.captures[index].source =
                .subwoofer(0)
        }
        XCTAssertThrowsError(
            try HardwareAcceptanceEvidenceAdapter()
                .h05MeasurementLab(noWholeSpeaker)
        ) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceEvidenceAdapterError,
                .wholeSpeakerLabRequired
            )
        }
    }

    func testFinalizedH04PEQVerificationLinksExactReceiptIdentity()
        throws {
        let applyID = UUID()
        let baselineID = UUID()
        let verificationID = UUID()
        let report = acceptedSpeakerOptimizerReport(
            applyID: applyID,
            baselineID: baselineID,
            verificationID: verificationID
        )
        let record = SpeakerOptimizerPEQVerificationRecord(
            applyReceiptID: applyID,
            verificationMeasurementSetID: verificationID,
            verifiedAt: Date(timeIntervalSince1970: 1_800_100_100),
            evidenceConfidence: 0.95,
            sourceCount: 1,
            worstFilterTrackingRMSDB: 0.2,
            minimumPersistentImprovementDB: 0.4,
            worstPersistentSeatRegressionDB: 0.1,
            maximumProtectedRegressionDB: 0.1
        )
        let finalization =
            SpeakerOptimizerPEQVerificationFinalizationReceipt(
                applyReceiptID: applyID,
                verificationMeasurementSetID: verificationID,
                playbackSystemID: systemID,
                verifiedAt:
                    Date(timeIntervalSince1970: 1_800_100_100),
                verification: record,
                expectedVerifiedState: PlaybackSystemState()
            )

        let linked = try HardwareAcceptanceEvidenceAdapter()
            .h04PEQVerification(
                report,
                finalization: finalization
            )
        XCTAssertEqual(
            linked.gateID,
            .h04SpeakerOptimizerVerification
        )
        XCTAssertEqual(linked.recommendedOutcome, .passed)
        XCTAssertEqual(linked.automaticAuthority, .remoteSoftware)
        XCTAssertFalse(linked.canEstablishPhysicalAuthority)

        var wrong = finalization
        wrong.verificationMeasurementSetID = UUID()
        XCTAssertThrowsError(
            try HardwareAcceptanceEvidenceAdapter()
                .h04PEQVerification(
                    report,
                    finalization: wrong
                )
        ) {
            XCTAssertEqual(
                $0 as? HardwareAcceptanceEvidenceAdapterError,
                .verificationReceiptMismatch
            )
        }
    }

    func testFinalizedH07CoherentVerificationStillNeedsPhysicalAuthority()
        throws {
        let applyID = UUID()
        let verificationSessionID = UUID()
        let source = CoherentSubwooferAlignmentSourceVerification(
            mainRole: .frontLeft,
            analyzedFrequencyCount: 20,
            phaseTrackingRMSRadians: 0.1,
            magnitudeTrackingRMSDB: 0.2,
            coherenceBeforeDB: -3,
            coherenceAfterDB: -1,
            measuredImprovementDB: 2,
            accepted: true,
            blockingReasons: []
        )
        let report = CoherentSubwooferAlignmentVerificationReport(
            applyReceiptID: applyID,
            verificationSessionID: verificationSessionID,
            playbackSystemID: systemID,
            routingSignature: "pr112a-route",
            microphone: microphone,
            sampleRate: 48_000,
            subwooferIndex: 0,
            crossoverFrequencyHz: 80,
            evidenceConfidence: 0.95,
            sources: [source],
            coherenceBeforeDB: -3,
            coherenceAfterDB: -1,
            measuredImprovementDB: 2,
            blockingReasons: [],
            warnings: []
        )
        let record = CoherentSubwooferAlignmentVerificationRecord(
            applyReceiptID: applyID,
            verificationSessionID: verificationSessionID,
            verifiedAt: Date(timeIntervalSince1970: 1_800_200_100),
            evidenceConfidence: 0.95,
            sourceCount: 1,
            worstPhaseTrackingRMSRadians: 0.1,
            worstMagnitudeTrackingRMSDB: 0.2,
            coherenceBeforeDB: -3,
            coherenceAfterDB: -1,
            measuredImprovementDB: 2
        )
        let finalization =
            CoherentSubwooferAlignmentVerificationFinalizationReceipt(
                applyReceiptID: applyID,
                verificationSessionID: verificationSessionID,
                playbackSystemID: systemID,
                verifiedAt:
                    Date(timeIntervalSince1970: 1_800_200_100),
                verification: record,
                expectedVerifiedState: PlaybackSystemState()
            )

        let linked = try HardwareAcceptanceEvidenceAdapter()
            .h07SingleSubVerification(
                report,
                finalization: finalization
            )
        XCTAssertEqual(
            linked.gateID,
            .h07CoherentMainSubAlignment
        )
        XCTAssertEqual(
            linked.coveredCapabilities,
            [.coherentIndependentSubAlignment]
        )
        XCTAssertEqual(linked.recommendedOutcome, .passed)
        XCTAssertEqual(linked.automaticAuthority, .remoteSoftware)
        XCTAssertFalse(linked.canEstablishPhysicalAuthority)
        XCTAssertFalse(linked.canAuthorizeLiveFeedForwardANC)
    }

    private func baselineSet() -> SpeakerOptimizerMeasurementSet {
        let source: MultichannelCalibrationSource =
            .speaker(.frontLeft)
        let captures = [
            baselineCapture(
                source: source,
                offsetDB: 0,
                arrival: 0.01000
            ),
            baselineCapture(
                source: source,
                offsetDB: 0.1,
                arrival: 0.01005
            ),
            baselineCapture(
                source: source,
                offsetDB: -0.1,
                arrival: 0.01010
            ),
        ]
        return SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: systemID,
            routingSignature: "pr112a-route",
            microphone: microphone,
            sampleRate: 48_000,
            positions: [
                .init(id: positionID, name: "Main Seat")
            ],
            plannedSources: [source],
            captures: captures,
            createdAt:
                Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt:
                Date(timeIntervalSince1970: 1_800_000_100)
        )
    }

    private func baselineCapture(
        source: MultichannelCalibrationSource,
        offsetDB: Double,
        arrival: Double
    ) -> SpeakerOptimizerMeasurementCapture {
        SpeakerOptimizerMeasurementCapture(
            capturedAt:
                Date(timeIntervalSince1970:
                    1_800_000_000 + arrival + offsetDB),
            playbackSystemID: systemID,
            routingSignature: "pr112a-route",
            microphone: microphone,
            positionID: positionID,
            source: source,
            sampleRate: 48_000,
            response: response(offsetDB: offsetDB),
            quality: quality(arrival: arrival)
        )
    }

    private func wholeSpeakerLabSession()
        -> SpeakerMeasurementLabSession {
        let labProtocol = SpeakerMeasurementLabProtocol(
            name: "Front Left installed on-axis",
            request: SpeakerMeasurementLabRequest(
                mode: .wholeSpeakerOnAxis,
                target:
                    .acousticSource(.speaker(.frontLeft)),
                geometry:
                    SpeakerMeasurementLabGeometry(
                        distanceMeters: 1.0
                    ),
                repeatCount: 3
            )
        )
        let captures = (0..<3).map { repeatIndex in
            SpeakerMeasurementLabCapture(
                protocolID: labProtocol.id,
                repeatIndex: repeatIndex,
                capturedAt:
                    Date(timeIntervalSince1970:
                        1_800_050_000
                        + Double(repeatIndex)),
                playbackSystemID: systemID,
                routingSignature: "pr112a-route",
                microphone: microphone,
                excitationLevelDBFS: -24,
                sampleRate: 48_000,
                source: .speaker(.frontLeft),
                impulseResponse: [0, 1, 0.1],
                transferFunction:
                    response(
                        offsetDB:
                            Double(repeatIndex - 1) * 0.05
                    ),
                quality:
                    quality(
                        arrival:
                            0.010
                            + Double(repeatIndex) * 0.00002
                    )
            )
        }
        return SpeakerMeasurementLabSession(
            playbackSystemID: systemID,
            routingSignature: "pr112a-route",
            microphone: microphone,
            sampleRate: 48_000,
            protocols: [labProtocol],
            captures: captures,
            createdAt:
                Date(timeIntervalSince1970: 1_800_049_900),
            modifiedAt:
                Date(timeIntervalSince1970: 1_800_050_100)
        )
    }

    private func acceptedSpeakerOptimizerReport(
        applyID: UUID,
        baselineID: UUID,
        verificationID: UUID
    ) -> SpeakerOptimizerPostApplyVerificationReport {
        SpeakerOptimizerPostApplyVerificationReport(
            applyReceiptID: applyID,
            baselineMeasurementSetID: baselineID,
            verificationMeasurementSetID: verificationID,
            playbackSystemID: systemID,
            routingSignature: "pr112a-route",
            evidenceConfidence: 0.95,
            sources: [
                SpeakerOptimizerPostApplySourceVerification(
                    source: .speaker(.frontLeft),
                    persistentPointCount: 20,
                    protectedPointCount: 10,
                    filterTrackingRMSDB: 0.2,
                    persistentRMSEBeforeDB: 2,
                    persistentRMSEAfterDB: 1,
                    persistentImprovementDB: 1,
                    worstPersistentSeatRegressionDB: 0.1,
                    protectedRegressionDB: 0.1,
                    accepted: true,
                    blockingReasons: []
                )
            ],
            blockingReasons: [],
            warnings: []
        )
    }

    private func response(
        offsetDB: Double
    ) -> RoomCorrectionFrequencyResponse {
        let frequencies = (0..<64).map { index in
            20.0 * pow(
                1_000,
                Double(index) / 63.0
            )
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: frequencies.map {
                offsetDB + 0.2 * sin(log($0 / 100))
            },
            phaseRadians: frequencies.map {
                -0.05 * log($0 / 20)
            }
        )
    }

    private func quality(
        arrival: Double
    ) -> RoomCorrectionMeasurementQuality {
        RoomCorrectionMeasurementQuality(
            clipped: false,
            playbackPeakDBFS: -24,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -70,
            estimatedSNRDB: 55,
            sweepComplete: true,
            directArrivalSeconds: arrival,
            usableLowHz: 20,
            usableHighHz: 20_000,
            warnings: []
        )
    }
}
