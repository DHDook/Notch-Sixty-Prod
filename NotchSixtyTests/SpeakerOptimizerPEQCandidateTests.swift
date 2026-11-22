import XCTest
@testable import NotchSixty

final class SpeakerOptimizerPEQCandidateTests: XCTestCase {
    private let playbackID = UUID(uuidString: "E1111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let seatID = UUID(uuidString: "E2222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr104-peq-test-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr104-peq-calibration"
    )

    func testDigitalPeakingBiquadHasBoundedCorrectCenterGain() throws {
        let band = try XCTUnwrap(SpeakerOptimizerPEQBand.peak(
            centerHz: 200, q: 1.4, gainDB: -4, sampleRate: 48_000
        ))
        XCTAssertEqual(band.magnitudeDB(at: 200, sampleRate: 48_000), -4, accuracy: 0.001)
        XCTAssertEqual(band.magnitudeDB(at: 15_000, sampleRate: 48_000), 0, accuracy: 0.03)
        XCTAssertNil(SpeakerOptimizerPEQBand.peak(
            centerHz: 25_000, q: 1, gainDB: -4, sampleRate: 48_000
        ))
    }

    func testQualifiedMeasurementProducesConstrainedCutOnlyPEQ() throws {
        let set = baseline()
        XCTAssertTrue(try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(set).optimizerReady)
        let candidate = try SpeakerOptimizerPEQCandidateDesigner().design(baseline: set)
        XCTAssertTrue(candidate.previewOnly)
        XCTAssertFalse(candidate.isMeasuredVerification)
        XCTAssertEqual(candidate.baselineMeasurementSetID, set.id)
        let source = try XCTUnwrap(candidate.sources.first)
        XCTAssertFalse(source.bands.isEmpty, source.warnings.joined(separator: "; "))
        XCTAssertLessThanOrEqual(source.bands.count, 6)
        XCTAssertTrue(source.bands.allSatisfy {
            $0.gainDB <= 0 && $0.gainDB >= -6
                && $0.q >= 0.55 && $0.q <= 4
        })
        XCTAssertLessThanOrEqual(source.maximumPositiveGainDB, 0.01)
        XCTAssertEqual(source.recommendedHeadroomDB, 0)
        XCTAssertLessThan(source.predictedWeightedRMSEAfterDB, source.weightedRMSEBeforeDB)
    }

    func testNoRealApplyOrDSPMutationAndIdentityMaintained() throws {
        let set = baseline()
        let unchanged = set
        let result = try SpeakerOptimizerPEQCandidateDesigner().design(baseline: set)
        XCTAssertEqual(unchanged, set)
        XCTAssertEqual(result.playbackSystemID, set.playbackSystemID)
        XCTAssertEqual(result.routingSignature, set.routingSignature)
        XCTAssertEqual(result.sampleRate, set.sampleRate)
    }

    func testUnqualifiedDataAndRoleFailClosed() throws {
        var set = baseline()
        set.role = .verification
        XCTAssertThrowsError(try SpeakerOptimizerPEQCandidateDesigner().design(baseline: set))
        set = baseline()
        set.captures[0].routingSignature = "unexpected"
        XCTAssertThrowsError(try SpeakerOptimizerPEQCandidateDesigner().design(baseline: set))
    }

    func testInvalidFilterConstraintsFailClosed() throws {
        var config = SpeakerOptimizerPEQConstraints()
        config.maximumBands = 32
        XCTAssertThrowsError(try SpeakerOptimizerPEQCandidateDesigner().design(
            baseline: baseline(), constraints: config
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerPEQError, .invalidConstraints)
        }
        config = SpeakerOptimizerPEQConstraints()
        config.maximumHeadroomDB = -.infinity
        XCTAssertThrowsError(try SpeakerOptimizerPEQCandidateDesigner().design(
            baseline: baseline(), constraints: config
        ))
    }

    func testExplicitSeatWeightValidationAndBandLimit() throws {
        var c = SpeakerOptimizerPEQConstraints()
        c.maximumBands = 1
        let result = try SpeakerOptimizerPEQCandidateDesigner().design(
            baseline: baseline(), seatWeights: [seatID: 1], constraints: c
        )
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.sources.first).bands.count, 1)
        XCTAssertThrowsError(try SpeakerOptimizerPEQCandidateDesigner().design(
            baseline: baseline(), seatWeights: [UUID(): 1]
        ))
    }

    private func baseline(sampleRate: Double = 48_000) -> SpeakerOptimizerMeasurementSet {
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let frequencies = (0..<64).map { i in
            20 * pow(1_000.0, Double(i) / 63)
        }
        let captures: [SpeakerOptimizerMeasurementCapture] = (0..<3).map { repeatIndex in
            let mags = frequencies.map { f in
                let octaves = log2(f / 250)
                return 6 * exp(-0.5 * pow(octaves / 0.65, 2))
                    + 0.08 * Double(repeatIndex - 1)
            }
            return SpeakerOptimizerMeasurementCapture(
                capturedAt: Date(timeIntervalSince1970: 1_700_500_000 + Double(repeatIndex)),
                playbackSystemID: playbackID,
                routingSignature: "peq-stable-routing",
                microphone: microphone,
                positionID: seatID,
                source: source,
                sampleRate: sampleRate,
                response: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: mags,
                    phaseRadians: Array(repeating: 0, count: frequencies.count)
                ),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -20,
                    capturePeakDBFS: -12,
                    estimatedNoiseFloorDBFS: -70,
                    estimatedSNRDB: 55,
                    sweepComplete: true,
                    directArrivalSeconds: 0.01 + Double(repeatIndex) * 0.00002,
                    usableLowHz: 20,
                    usableHighHz: 20_000,
                    warnings: []
                )
            )
        }
        return SpeakerOptimizerMeasurementSet(
            role: .baseline, playbackSystemID: playbackID,
            routingSignature: "peq-stable-routing",
            microphone: microphone, sampleRate: sampleRate,
            positions: [SpeakerOptimizerMeasurementPosition(id: seatID, name: "Center")],
            plannedSources: [source], captures: captures
        )
    }

    /// E21 S9a parity (design note 9): the core candidate search matches the Swift reference at every standard rate.
    func testCoreMathsMatchesSwiftReferenceAtStandardRates() throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let set = baseline(sampleRate: rate)
            var reference = SpeakerOptimizerPEQCandidateDesigner()
            reference.useCoreMaths = false
            var core = SpeakerOptimizerPEQCandidateDesigner()
            core.useCoreMaths = true
            let a = try XCTUnwrap(reference.design(baseline: set).sources.first, "\(rate)")
            let b = try XCTUnwrap(core.design(baseline: set).sources.first, "\(rate)")
            XCTAssertEqual(a.bands.count, b.bands.count, "\(rate)")
            for (x, y) in zip(a.bands, b.bands) {
                XCTAssertEqual(x.centerHz, y.centerHz, accuracy: x.centerHz * 1e-9, "\(rate)")
                XCTAssertEqual(x.q, y.q, "\(rate)")
                XCTAssertEqual(x.gainDB, y.gainDB, accuracy: 1e-9, "\(rate)")
                XCTAssertEqual(x.b0, y.b0, accuracy: 1e-12, "\(rate)")
                XCTAssertEqual(x.a2, y.a2, accuracy: 1e-12, "\(rate)")
            }
            XCTAssertEqual(a.weightedRMSEBeforeDB, b.weightedRMSEBeforeDB, accuracy: 0.05, "\(rate)")
            XCTAssertEqual(a.predictedWeightedRMSEAfterDB, b.predictedWeightedRMSEAfterDB, accuracy: 0.05, "\(rate)")
            XCTAssertEqual(a.maximumPositiveGainDB, b.maximumPositiveGainDB, accuracy: 0.05, "\(rate)")
            XCTAssertEqual(a.recommendedHeadroomDB, b.recommendedHeadroomDB, accuracy: 0.5, "\(rate)")
            XCTAssertEqual(a.warnings, b.warnings, "\(rate)")
            for (x, y) in zip(a.modeledFilterMagnitudeDB, b.modeledFilterMagnitudeDB) {
                XCTAssertEqual(x, y, accuracy: 1e-6, "\(rate)")
            }
        }
    }
}
