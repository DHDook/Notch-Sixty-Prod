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

    /// E8 S8b: the core linear-phase synthesiser at every standard rate. The taps are symmetric (exact linear phase), the
    /// candidate passes the unchanged audit and acceptance thresholds, and the modelled response reproduces the
    /// correction inside the measured band while the band edge taper leaves 0 dB outside it.
    func testCoreSynthesisMeetsAuditAtStandardRates() throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let baseline = stableBaseline(sampleRate: rate)
            // The same ~21 ms span at every rate: a fixed 2049 taps cannot resolve the 20 Hz edge once the
            // Blackman main lobe (6 fs / N) exceeds a few hundred Hz, so the tap count scales with the rate.
            var constraints = SpeakerOptimizerFIRConstraints()
            constraints.tapCount = 2 * Int((1024 * rate / 48_000).rounded()) + 1
            let half = (constraints.tapCount - 1) / 2
            let result = try SpeakerOptimizerFIRCandidateDesigner().design(
                baseline: baseline, constraints: constraints
            )
            XCTAssertEqual(result.declaredGroupDelayFrames, half)
            let candidate = try XCTUnwrap(result.sources.first)
            XCTAssertTrue(candidate.acceptedForPreview,
                          "\(rate): " + candidate.blockingReasons.joined(separator: "; "))
            guard candidate.taps.count == constraints.tapCount else {
                XCTFail("\(rate): taps \(candidate.taps.count)")
                continue
            }
            for i in 0..<half {
                XCTAssertEqual(candidate.taps[i], candidate.taps[2 * half - i], accuracy: 1e-6, "\(rate) tap \(i)")
            }
            XCTAssertLessThan(candidate.predictedWeightedRMSEAfterDB, candidate.weightedRMSEBeforeDB, "\(rate)")
            XCTAssertLessThan(candidate.worstSeatRegressionDB, 0.25, "\(rate)")
            XCTAssertLessThanOrEqual(candidate.recommendedHeadroomDB, 3.5, "\(rate)")
        }
    }

    /// E9 S4: with the long scheme the core designs a 65,535-tap single-band candidate (the delay limit lets it run at
    /// the two highest rates); with the uniform scheme the request is refused with a named reason.
    func testLongSchemeDesignsA65535TapCandidateAndTheUniformSchemeNamesTheRefusal() throws {
        for rate in [352_800.0, 384_000] {
            var constraints = SpeakerOptimizerFIRConstraints()
            constraints.tapCount = 65_535
            constraints.maximumGroupDelayMilliseconds = 100
            let baseline = stableBaseline(sampleRate: rate)
            let result = try SpeakerOptimizerFIRCandidateDesigner().design(
                baseline: baseline, constraints: constraints, firScheme: UnifiedGraphFIRScheme.nonUniform)
            XCTAssertEqual(result.declaredGroupDelayFrames, 32_767, "\(rate)")
            let candidate = try XCTUnwrap(result.sources.first)
            XCTAssertEqual(candidate.taps.count, 65_535, "\(rate): " + candidate.blockingReasons.joined(separator: "; "))
            XCTAssertTrue(candidate.taps.allSatisfy(\.isFinite))
            for i in 0..<32_767 where i % 997 == 0 {
                XCTAssertEqual(candidate.taps[i], candidate.taps[65_534 - i], accuracy: 1e-6, "\(rate) tap \(i)")
            }
            XCTAssertThrowsError(try SpeakerOptimizerFIRCandidateDesigner().design(
                baseline: baseline, constraints: constraints, firScheme: UnifiedGraphFIRScheme.uniform)) { error in
                XCTAssertEqual(error as? SpeakerOptimizerFIRCandidateError,
                               .filterTooLong(requested: 65_535, maximum: 32_768), "\(rate)")
                XCTAssertTrue(error.localizedDescription.contains("longest supported (32768 taps)"))
            }
        }
    }

    /// E9 S4: the long scheme leaves designs inside 32,768 taps as they were, at every standard rate.
    func testLongSchemeKeepsShortDesignsSingleBandAtStandardRates() throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            var constraints = SpeakerOptimizerFIRConstraints()
            constraints.tapCount = 2 * Int((1024 * rate / 48_000).rounded()) + 1
            let baseline = stableBaseline(sampleRate: rate)
            let uniform = try SpeakerOptimizerFIRCandidateDesigner().design(
                baseline: baseline, constraints: constraints, firScheme: UnifiedGraphFIRScheme.uniform)
            let long = try SpeakerOptimizerFIRCandidateDesigner().design(
                baseline: baseline, constraints: constraints, firScheme: UnifiedGraphFIRScheme.nonUniform)
            XCTAssertEqual(try XCTUnwrap(long.sources.first).taps, try XCTUnwrap(uniform.sources.first).taps, "\(rate)")
        }
    }

    private func stableBaseline(sampleRate: Double = 48_000) -> SpeakerOptimizerMeasurementSet {
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
                    sampleRate: sampleRate,
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
            microphone: microphone, sampleRate: sampleRate,
            positions: [
                SpeakerOptimizerMeasurementPosition(id: seatA, name: "Main"),
                SpeakerOptimizerMeasurementPosition(id: seatB, name: "Second")
            ],
            plannedSources: [source], captures: captures
        )
    }
}
