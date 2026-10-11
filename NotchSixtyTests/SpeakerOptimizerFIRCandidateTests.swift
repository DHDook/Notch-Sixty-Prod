import XCTest
@testable import NotchSixty

final class SpeakerOptimizerFIRCandidateTests: XCTestCase {
    private let systemID = UUID(uuidString: "E3333333-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let seatA = UUID(uuidString: "E4444444-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let seatB = UUID(uuidString: "E5555555-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr104-fir-test-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr104-fir-calibration"
    )

    func testQualifiedEvidenceBuildsLinearPhaseFIRWithDeclaredDelay() throws {
        let baseline = stableBaseline()
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline)
        XCTAssertTrue(report.optimizerReady, report.blockingReasons.joined(separator: "; "))
        let result = try SpeakerOptimizerFIRCandidateDesigner().design(baseline: baseline)
        XCTAssertTrue(result.previewOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.isMeasuredVerification)
        XCTAssertEqual(result.declaredGroupDelayFrames, 1024)
        XCTAssertEqual(result.declaredGroupDelayMilliseconds, 1024 / 48, accuracy: 0.001)
        XCTAssertEqual(result.baselineMeasurementSetID, baseline.id)
        let candidate = try XCTUnwrap(result.sources.first)
        XCTAssertTrue(candidate.acceptedForPreview, candidate.blockingReasons.joined(separator: "; "))
        XCTAssertEqual(candidate.taps.count, 2049)
        XCTAssertEqual(candidate.taps[0], candidate.taps[2048], accuracy: 0.00001)
        XCTAssertEqual(candidate.taps[200], candidate.taps[1848], accuracy: 0.00001)
        XCTAssertLessThan(candidate.predictedWeightedRMSEAfterDB, candidate.weightedRMSEBeforeDB)
        XCTAssertGreaterThanOrEqual(candidate.recommendedHeadroomDB, 0)
    }

    func testMissingEvidenceOrVerificationRoleIsRejected() throws {
        var baseline = stableBaseline()
        baseline.role = .verification
        XCTAssertThrowsError(try SpeakerOptimizerFIRCandidateDesigner().design(baseline: baseline))
        baseline = stableBaseline()
        baseline.captures.removeLast()
        XCTAssertThrowsError(try SpeakerOptimizerFIRCandidateDesigner().design(baseline: baseline))
    }

    func testTapCountAndDelayFailClosed() throws {
        let baseline = stableBaseline()
        var constraints = SpeakerOptimizerFIRConstraints()
        constraints.tapCount = 2048
        XCTAssertThrowsError(try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: baseline, constraints: constraints
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerFIRCandidateError, .invalidConstraints)
        }
        constraints.tapCount = 4097
        XCTAssertThrowsError(try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: baseline, constraints: constraints
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerFIRCandidateError, .invalidConstraints)
        }
    }

    func testStrictResponseGuardNeverExposesUnacceptedTaps() throws {
        let baseline = stableBaseline()
        var constraints = SpeakerOptimizerFIRConstraints()
        constraints.maximumTruncationOvershootDB = 0
        constraints.maximumOutOfBandDeviationDB = 0
        let result = try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: baseline, constraints: constraints
        )
        for source in result.sources where !source.acceptedForPreview {
            XCTAssertTrue(source.taps.isEmpty)
            XCTAssertFalse(source.blockingReasons.isEmpty)
        }
        XCTAssertTrue(result.previewOnly)
    }

    func testOneMicTwoPositionsPreserveEvidenceAndRoutingIdentity() throws {
        let baseline = stableBaseline()
        let unchanged = baseline
        let result = try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: baseline, seatWeights: [seatA: 2, seatB: 1]
        )
        XCTAssertEqual(baseline, unchanged)
        XCTAssertEqual(result.playbackSystemID, baseline.playbackSystemID)
        XCTAssertEqual(result.routingSignature, baseline.routingSignature)
        XCTAssertEqual(result.sampleRate, baseline.sampleRate)
        XCTAssertThrowsError(try SpeakerOptimizerFIRCandidateDesigner().design(
            baseline: baseline, seatWeights: [seatA: 1]
        ))
    }

    private func stableBaseline() -> SpeakerOptimizerMeasurementSet {
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let frequencies = (0..<96).map { index in
            20 * pow(1_000.0, Double(index) / 95)
        }
        var captures: [SpeakerOptimizerMeasurementCapture] = []
        for (seatIndex, seat) in [seatA, seatB].enumerated() {
            for repeatIndex in 0..<3 {
                let values = frequencies.map { f in
                    let octaves = log2(f / 240)
                    return 5.5 * exp(-0.5 * pow(octaves / 0.75, 2))
                        + Double(seatIndex) * 0.25
                        + Double(repeatIndex - 1) * 0.08
                }
                captures.append(SpeakerOptimizerMeasurementCapture(
                    capturedAt: Date(timeIntervalSince1970:
                        1_700_600_000 + Double(seatIndex * 10 + repeatIndex)),
                    playbackSystemID: systemID,
                    routingSignature: "pr104-fir-safe-route",
                    microphone: microphone,
                    positionID: seat,
                    source: source,
                    sampleRate: 48_000,
                    response: RoomCorrectionFrequencyResponse(
                        frequenciesHz: frequencies,
                        magnitudeDB: values,
                        phaseRadians: Array(repeating: 0, count: frequencies.count)
                    ),
                    quality: RoomCorrectionMeasurementQuality(
                        clipped: false, playbackPeakDBFS: -20,
                        capturePeakDBFS: -12, estimatedNoiseFloorDBFS: -70,
                        estimatedSNRDB: 55, sweepComplete: true,
                        directArrivalSeconds: 0.010 + Double(repeatIndex) * 0.00002,
                        usableLowHz: 20, usableHighHz: 20_000, warnings: []
                    )
                ))
            }
        }
        return SpeakerOptimizerMeasurementSet(
            role: .baseline, playbackSystemID: systemID,
            routingSignature: "pr104-fir-safe-route",
            microphone: microphone, sampleRate: 48_000,
            positions: [
                SpeakerOptimizerMeasurementPosition(id: seatA, name: "Main"),
                SpeakerOptimizerMeasurementPosition(id: seatB, name: "Second")
            ],
            plannedSources: [source], captures: captures
        )
    }
}
