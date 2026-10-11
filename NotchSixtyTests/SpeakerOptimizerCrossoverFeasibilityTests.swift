import XCTest
@testable import NotchSixty

final class SpeakerOptimizerCrossoverFeasibilityTests: XCTestCase {
    private let main: MultichannelCalibrationSource = .speaker(.frontLeft)
    private let sub: MultichannelCalibrationSource = .subwoofer(0)
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr104-crossover-synthetic-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr104-crossover-test-cal"
    )

    func testQualifiedMainsSubOffersPreviewOnlyPhaseAndTimingHypothesis() throws {
        let baseline = makeBaseline()
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline)
        XCTAssertTrue(report.optimizerReady, report.blockingReasons.joined(separator: "; "))
        let result = try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub
        )
        XCTAssertTrue(result.previewOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.isMeasuredVerification)
        XCTAssertTrue(result.requiresIndependentHeadroomAndLimiterAudit)
        XCTAssertEqual(result.measurementSetID, baseline.id)
        XCTAssertEqual(result.microphone, microphone)
        XCTAssertTrue(result.acceptedForPreview, result.blockingReasons.joined(separator: "; "))
        XCTAssertGreaterThan(result.aggregatePredictedImprovementDB, 0.25)
        XCTAssertEqual(result.seatPredictions.count, 2)
        XCTAssertTrue(result.seatPredictions.allSatisfy { $0.predictedImprovementDB >= -1 })
        XCTAssertLessThanOrEqual(abs(result.previewRelativeDelayMs), 8)
        XCTAssertTrue(result.warnings.contains { $0.contains("common sweep-clock") })
    }

    func testRoleRouteAndSourceMustBeQualifiedAndSeparate() throws {
        var baseline = makeBaseline()
        baseline.role = .verification
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub
        ))
        baseline = makeBaseline()
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: main
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerCrossoverError, .invalidSourcePair)
        }
        baseline.captures[0].routingSignature = "other"
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub
        ))
    }

    func testMissingPhaseOrExcessiveArrivalGapBlocksModel() throws {
        var baseline = makeBaseline()
        baseline.captures[0].response.phaseRadians = nil
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub
        ))
        baseline = makeBaseline()
        for i in baseline.captures.indices where baseline.captures[i].source == sub {
            baseline.captures[i].quality.directArrivalSeconds = 0.1
        }
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerCrossoverError,
                           .unreliablePhaseOrArrival)
        }
    }

    func testWeightsAndUnsupportedCrossoverBandFailClosed() throws {
        let baseline = makeBaseline()
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub,
            seatWeights: [baseline.positions[0].id: 1]
        ))
        var options = SpeakerOptimizerCrossoverOptions()
        options.centerHz = 250
        var limited = baseline
        for index in limited.captures.indices where limited.captures[index].source == sub {
            limited.captures[index].quality.usableHighHz = 100
        }
        XCTAssertThrowsError(try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: limited, speaker: main, subwoofer: sub,
            options: options
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerCrossoverError,
                           .insufficientCommonBandwidth)
        }
    }

    func testNoBenefitEmitsNoActionableOffset() throws {
        let baseline = makeBaseline(subArrival: 0.010)
        let result = try SpeakerOptimizerCrossoverFeasibilityDesigner().analyze(
            baseline: baseline, speaker: main, subwoofer: sub
        )
        if !result.acceptedForPreview {
            XCTAssertEqual(result.previewRelativeDelayMs, 0)
            XCTAssertFalse(result.previewInvertSubPolarity)
            XCTAssertEqual(result.aggregatePredictedImprovementDB, 0)
        }
        XCTAssertFalse(result.canDeploy)
    }


    func testClockOffsetUncertaintySensitivityIsPreviewOnlyAndUnauthenticated() throws {
        let baseline = makeBaseline()
        var sensitivity = SpeakerOptimizerPhaseReferenceSensitivityOptions()
        sensitivity.maximumUnknownClockOffsetMs = 0.25
        let report = try SpeakerOptimizerCrossoverFeasibilityDesigner()
            .auditUnknownClockOffsetSensitivity(
                baseline: baseline, speaker: main, subwoofer: sub,
                sensitivity: sensitivity
            )
        XCTAssertEqual(report.measurementSetID, baseline.id)
        XCTAssertEqual(report.routingSignature, baseline.routingSignature)
        XCTAssertEqual(report.microphone, baseline.microphone)
        XCTAssertEqual(report.testedOffsets.count, sensitivity.sampleCount)
        XCTAssertEqual(report.testedOffsets.first?.assumedSubClockOffsetMs, -0.25)
        XCTAssertEqual(report.testedOffsets.last?.assumedSubClockOffsetMs, 0.25)
        XCTAssertTrue(report.previewOnly)
        XCTAssertFalse(report.canDeploy)
        XCTAssertFalse(report.crossSourceClockProvenanceAuthenticated)
        XCTAssertTrue(report.requiresSynchronizedReferenceCapture)
        XCTAssertFalse(report.isMeasuredVerification)
        XCTAssertTrue(report.warnings.contains { $0.contains("NOT a measured bound") })
    }

    func testWideClockUncertaintyCanRejectOtherwiseAttractiveCrossoverHypothesis() throws {
        let baseline = makeBaseline()
        var sensitivity = SpeakerOptimizerPhaseReferenceSensitivityOptions()
        sensitivity.maximumUnknownClockOffsetMs = 8.0
        let report = try SpeakerOptimizerCrossoverFeasibilityDesigner()
            .auditUnknownClockOffsetSensitivity(
                baseline: baseline, speaker: main, subwoofer: sub,
                sensitivity: sensitivity
            )
        XCTAssertFalse(report.survivesAssumedTimingUncertaintyForVisualPreview)
        XCTAssertFalse(report.blockingReasons.isEmpty)
        XCTAssertEqual(report.testedOffsets.count, 9)
        XCTAssertFalse(report.canDeploy)
    }

    func testClockAuditRejectsUnqualifiedDataOrInvalidUncertainty() throws {
        var baseline = makeBaseline()
        baseline.role = .verification
        XCTAssertThrowsError(
            try SpeakerOptimizerCrossoverFeasibilityDesigner()
                .auditUnknownClockOffsetSensitivity(
                    baseline: baseline, speaker: main, subwoofer: sub
                )
        )
        var limits = SpeakerOptimizerPhaseReferenceSensitivityOptions()
        limits.maximumUnknownClockOffsetMs = 0
        XCTAssertThrowsError(
            try SpeakerOptimizerCrossoverFeasibilityDesigner()
                .auditUnknownClockOffsetSensitivity(
                    baseline: makeBaseline(), speaker: main, subwoofer: sub,
                    sensitivity: limits
                )
        ) {
            XCTAssertEqual($0 as? SpeakerOptimizerCrossoverError, .invalidOptions)
        }
        limits.maximumUnknownClockOffsetMs = 2
        limits.sampleCount = 8
        XCTAssertThrowsError(
            try SpeakerOptimizerCrossoverFeasibilityDesigner()
                .auditUnknownClockOffsetSensitivity(
                    baseline: makeBaseline(), speaker: main, subwoofer: sub,
                    sensitivity: limits
                )
        )
    }

    func testClockAuditNeverMutatesBaselineOrAllowsApply() throws {
        let baseline = makeBaseline()
        let original = baseline
        let report = try SpeakerOptimizerCrossoverFeasibilityDesigner()
            .auditUnknownClockOffsetSensitivity(
                baseline: baseline, speaker: main, subwoofer: sub
            )
        XCTAssertEqual(baseline, original)
        XCTAssertEqual(report.playbackSystemID, baseline.playbackSystemID)
        XCTAssertFalse(report.canDeploy)
    }

    private func makeBaseline(subArrival: Double = 0.013) -> SpeakerOptimizerMeasurementSet {
        let system = UUID(uuidString: "E6666666-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
        let seats = [
            SpeakerOptimizerMeasurementPosition(
                id: UUID(uuidString: "E7777777-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!, name: "Main seat"),
            SpeakerOptimizerMeasurementPosition(
                id: UUID(uuidString: "E8888888-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!, name: "Second seat")
        ]
        let freqs = (0..<512).map { i in
            20 * pow(1_000.0, Double(i) / 511)
        }
        var captures: [SpeakerOptimizerMeasurementCapture] = []
        for (seatIndex, seat) in seats.enumerated() {
            for source in [main, sub] {
                for repeatIndex in 0..<3 {
                    let arrival = (source == main ? 0.010 : subArrival)
                        + Double(repeatIndex) * 0.00001
                    let phase = freqs.map { f in
                        // Analyzer-style bulk-delay-removed phase.
                        0.05 * log2(f / 80)
                    }
                    captures.append(SpeakerOptimizerMeasurementCapture(
                        capturedAt: Date(timeIntervalSince1970:
                            1_701_000_000 + Double(seatIndex * 20 + repeatIndex)),
                        playbackSystemID: system,
                        routingSignature: "pr104-synthetic-full-range-speaker-sub",
                        microphone: microphone,
                        positionID: seat.id, source: source,
                        sampleRate: 48_000,
                        response: RoomCorrectionFrequencyResponse(
                            frequenciesHz: freqs,
                            magnitudeDB: freqs.map { f in
                                -0.5 * pow(log2(f / 80), 2)
                                    + Double(seatIndex) * 0.1
                                    + Double(repeatIndex - 1) * 0.02
                            },
                            phaseRadians: phase
                        ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false, playbackPeakDBFS: -24,
                            capturePeakDBFS: -15, estimatedNoiseFloorDBFS: -75,
                            estimatedSNRDB: 60, sweepComplete: true,
                            directArrivalSeconds: arrival,
                            usableLowHz: 20, usableHighHz: 20_000,
                            warnings: []
                        )
                    ))
                }
            }
        }
        return SpeakerOptimizerMeasurementSet(
            role: .baseline, playbackSystemID: system,
            routingSignature: "pr104-synthetic-full-range-speaker-sub",
            microphone: microphone, sampleRate: 48_000,
            positions: seats, plannedSources: [main, sub], captures: captures
        )
    }
}
