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

    private func baseline() -> SpeakerOptimizerMeasurementSet {
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
                sampleRate: 48_000,
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
            microphone: microphone, sampleRate: 48_000,
            positions: [SpeakerOptimizerMeasurementPosition(id: seatID, name: "Center")],
            plannedSources: [source], captures: captures
        )
    }
}
