import XCTest
@testable import NotchSixty

final class SpeakerOptimizerCandidateComparisonTests: XCTestCase {
    private let system = UUID(uuidString: "B1111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let seat = UUID(uuidString: "B2222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr104-alternatives-test-mic", inputChannelIndex: 0,
        calibrationFingerprint: "pr104-rank-cal"
    )
    private let speaker: MultichannelCalibrationSource = .speaker(.frontLeft)

    func testComparesBypassPEQAndFIRWithSameEvidenceAndNoLiveSwitch() throws {
        let baseline = makeBaseline()
        XCTAssertTrue(try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(baseline).optimizerReady)
        let designer = SpeakerOptimizerCandidateComparisonDesigner()
        let result = try designer.compare(baseline: baseline)
        XCTAssertEqual(result.baselineMeasurementSetID, baseline.id)
        XCTAssertEqual(result.routingSignature, baseline.routingSignature)
        XCTAssertEqual(result.microphone, baseline.microphone)
        XCTAssertTrue(result.previewOnly)
        XCTAssertFalse(result.canDeploy)
        XCTAssertFalse(result.canSwitchLiveAudio)
        XCTAssertFalse(result.isMeasuredVerification)
        let row = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(Set(row.alternatives.map(\.kind)), Set(SpeakerOptimizerAlternativeKind.allCases))
        XCTAssertTrue(row.alternatives.contains { $0.kind == .bypass && $0.eligibleForVisualPreview })
        XCTAssertTrue(row.alternatives.contains { $0.kind == .peq && $0.eligibleForVisualPreview })
        XCTAssertEqual(row.alternatives.first?.kind, row.topVisualPreviewKind)
        XCTAssertTrue(row.alternatives.filter(\.eligibleForVisualPreview).allSatisfy {
            $0.rankingScore?.isFinite == true
        })
        XCTAssertTrue(row.alternatives.filter { !$0.eligibleForVisualPreview }.allSatisfy {
            !$0.blockingReasons.isEmpty && $0.rankingScore == nil
        })
    }

    func testVisualABIsMagnitudeOnlyAndRejectsIneligibleCandidate() throws {
        let designer = SpeakerOptimizerCandidateComparisonDesigner()
        let result = try designer.compare(baseline: makeBaseline())
        let ab = try designer.visualAB(in: result, source: speaker, a: .bypass, b: .peq)
        XCTAssertTrue(ab.visualOnly)
        XCTAssertFalse(ab.canSwitchLiveAudio)
        XCTAssertEqual(ab.differenceBMinusADB.count, ab.frequenciesHz.count)
        XCTAssertTrue(ab.aCorrectionDB.allSatisfy { $0 == 0 })
        XCTAssertEqual(ab.differenceBMinusADB, ab.bCorrectionDB)
        XCTAssertThrowsError(try designer.visualAB(
            in: result, source: .subwoofer(2), a: .bypass, b: .peq
        ))
        var guarded = result
        let row = try XCTUnwrap(guarded.sources.firstIndex(where: { $0.source == speaker }))
        let peq = try XCTUnwrap(guarded.sources[row].alternatives.firstIndex(where: { $0.kind == .peq }))
        guarded.sources[row].alternatives[peq].eligibleForVisualPreview = false
        XCTAssertThrowsError(try designer.visualAB(
            in: guarded, source: speaker, a: .bypass, b: .peq
        ))
    }

    func testStrictLatencyHeadroomAndBenefitCanRejectAlternatives() throws {
        var choices = SpeakerOptimizerComparisonOptions()
        choices.maximumFIRDelayMilliseconds = 2.0
        choices.minimumModeledImprovementDB = 0.45
        let result = try SpeakerOptimizerCandidateComparisonDesigner().compare(
            baseline: makeBaseline(), comparisonOptions: choices
        )
        let row = try XCTUnwrap(result.sources.first)
        let fir = try XCTUnwrap(row.alternatives.first(where: { $0.kind == .fir }))
        XCTAssertFalse(fir.eligibleForVisualPreview)
        XCTAssertTrue(fir.blockingReasons.count > 0)
        XCTAssertEqual(fir.filterCount, 0)
        XCTAssertTrue(fir.correctionDB.allSatisfy { $0 == 0 })
    }

    func testRejectsIncompleteBaselineAndInvalidTradeoffConstraints() throws {
        var invalid = makeBaseline()
        invalid.role = .candidate
        XCTAssertThrowsError(try SpeakerOptimizerCandidateComparisonDesigner().compare(baseline: invalid))
        invalid = makeBaseline()
        invalid.captures.removeLast()
        XCTAssertThrowsError(try SpeakerOptimizerCandidateComparisonDesigner().compare(baseline: invalid))
        var options = SpeakerOptimizerComparisonOptions()
        options.maximumRequiredHeadroomDB = -.infinity
        XCTAssertThrowsError(try SpeakerOptimizerCandidateComparisonDesigner().compare(
            baseline: makeBaseline(), comparisonOptions: options
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerComparisonError, .invalidOptions)
        }
    }

    func testComparisonLeavesInputUnchangedAndValidatesExplicitWeights() throws {
        let baseline = makeBaseline()
        let unchanged = baseline
        let result = try SpeakerOptimizerCandidateComparisonDesigner().compare(
            baseline: baseline, seatWeights: [seat: 1]
        )
        XCTAssertEqual(baseline, unchanged)
        XCTAssertEqual(result.playbackSystemID, baseline.playbackSystemID)
        XCTAssertThrowsError(try SpeakerOptimizerCandidateComparisonDesigner().compare(
            baseline: baseline, seatWeights: [UUID(): 1]
        ))
    }

    private func makeBaseline() -> SpeakerOptimizerMeasurementSet {
        let freqs = (0..<64).map { index in
            20 * pow(1_000.0, Double(index) / 63)
        }
        let captures = (0..<3).map { repeatIndex in
            SpeakerOptimizerMeasurementCapture(
                capturedAt: Date(timeIntervalSince1970: 1_702_000_000 + Double(repeatIndex)),
                playbackSystemID: system, routingSignature: "comparison-stable-route",
                microphone: mic, positionID: seat, source: speaker, sampleRate: 48_000,
                response: RoomCorrectionFrequencyResponse(
                    frequenciesHz: freqs,
                    magnitudeDB: freqs.map { f in
                        6 * exp(-0.5 * pow(log2(f / 250) / 0.65, 2))
                            + Double(repeatIndex - 1) * 0.08
                    },
                    phaseRadians: Array(repeating: 0, count: freqs.count)
                ),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false, playbackPeakDBFS: -20,
                    capturePeakDBFS: -12, estimatedNoiseFloorDBFS: -70,
                    estimatedSNRDB: 55, sweepComplete: true,
                    directArrivalSeconds: 0.010 + Double(repeatIndex) * 0.00002,
                    usableLowHz: 20, usableHighHz: 20_000, warnings: []
                )
            )
        }
        return SpeakerOptimizerMeasurementSet(
            role: .baseline, playbackSystemID: system,
            routingSignature: "comparison-stable-route",
            microphone: mic, sampleRate: 48_000,
            positions: [SpeakerOptimizerMeasurementPosition(id: seat, name: "Main")],
            plannedSources: [speaker], captures: captures
        )
    }
}
