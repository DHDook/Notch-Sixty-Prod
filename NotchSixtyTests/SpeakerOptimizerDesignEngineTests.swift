import XCTest
@testable import NotchSixty

final class SpeakerOptimizerDesignEngineTests: XCTestCase {
    private let systemID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-AAAAAAAAAAAA")!
    private let seatA = UUID(uuidString: "BBBBBBBB-1111-2222-3333-BBBBBBBBBBBB")!
    private let seatB = UUID(uuidString: "CCCCCCCC-1111-2222-3333-CCCCCCCCCCCC")!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr104-measurement-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr104-fixture-cal"
    )
    private let left: MultichannelCalibrationSource = .speaker(.frontLeft)

    func testQualifiedBaselineProducesBoundedCutOnlyPreview() throws {
        let result = try SpeakerOptimizerDesignEngine().design(baseline: makeBaseline())
        XCTAssertTrue(result.previewOnly)
        XCTAssertFalse(result.isMeasuredVerification)
        XCTAssertEqual(result.sources.count, 1)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.frequenciesHz.count, source.correctionDB.count)
        XCTAssertTrue(source.correctionDB.allSatisfy { (-6.00001...0.00001).contains($0) })
        XCTAssertTrue(source.correctionDB.contains { $0 < -0.5 })
        XCTAssertLessThan(source.predictedWeightedRMSEAfterDB, source.weightedRMSEBeforeDB)
    }

    func testCandidateOrVerificationCannotBecomeBaseline() throws {
        var baseline = makeBaseline()
        baseline.role = .candidate
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(baseline: baseline)) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .baselineRequired)
        }
        baseline.role = .verification
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(baseline: baseline)) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .baselineRequired)
        }
    }

    func testInsufficientRepeatsFailsClosed() throws {
        var baseline = makeBaseline()
        baseline.captures.removeLast()
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(baseline: baseline)) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .unqualifiedMeasurements)
        }
    }

    func testChangedMicrophoneOrRoutingFailsClosed() throws {
        var baseline = makeBaseline()
        baseline.captures[0].routingSignature = "other-route"
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(baseline: baseline)) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .unqualifiedMeasurements)
        }
    }

    func testMissingOrInvalidSeatWeightsFailClosed() throws {
        let baseline = makeBaseline()
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(
            baseline: baseline, seatWeights: [seatA: 1]
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .invalidSeatWeights)
        }
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(
            baseline: baseline, seatWeights: [seatA: 1, seatB: -.infinity]
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .invalidSeatWeights)
        }
    }

    func testSafetyOptionsBoundBoostAndCut() throws {
        var options = SpeakerOptimizerDesignOptions()
        options.maximumBoostDB = 4
        XCTAssertThrowsError(try SpeakerOptimizerDesignEngine().design(
            baseline: makeBaseline(), options: options
        )) {
            XCTAssertEqual($0 as? SpeakerOptimizerDesignError, .invalidOptions)
        }
        options.maximumBoostDB = 3
        options.maximumCutDB = 2
        let result = try SpeakerOptimizerDesignEngine().design(baseline: makeBaseline(), options: options)
        let values = try XCTUnwrap(result.sources.first).correctionDB
        XCTAssertTrue(values.allSatisfy { (-2.00001...3.00001).contains($0) })
    }

    func testNoOutputOrDriverRoutingIsMutatedByDesign() throws {
        let baseline = makeBaseline()
        let frozen = baseline
        let result = try SpeakerOptimizerDesignEngine().design(baseline: baseline)
        XCTAssertEqual(baseline, frozen)
        XCTAssertEqual(result.playbackSystemID, baseline.playbackSystemID)
        XCTAssertEqual(result.routingSignature, baseline.routingSignature)
        XCTAssertEqual(result.baselineMeasurementSetID, baseline.id)
    }

    private func makeBaseline() -> SpeakerOptimizerMeasurementSet {
        var captures: [SpeakerOptimizerMeasurementCapture] = []
        for (position, seatBias) in [(seatA, 0.0), (seatB, 0.5)] {
            for repeatIndex in 0..<3 {
                let frequencies = (0..<64).map {
                    20.0 * pow(1_000, Double($0) / 63)
                }
                let magnitudes = frequencies.map { f in
                    let octaves = log2(f / 250)
                    return seatBias + 5 * exp(-0.5 * pow(octaves / 0.7, 2))
                        + Double(repeatIndex - 1) * 0.10
                }
                let response = RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies,
                    magnitudeDB: magnitudes,
                    phaseRadians: Array(repeating: 0, count: 64)
                )
                let quality = RoomCorrectionMeasurementQuality(
                    clipped: false,
                    playbackPeakDBFS: -20,
                    capturePeakDBFS: -15,
                    estimatedNoiseFloorDBFS: -70,
                    estimatedSNRDB: 55,
                    sweepComplete: true,
                    directArrivalSeconds: 0.010 + Double(repeatIndex) * 0.00002,
                    usableLowHz: 20,
                    usableHighHz: 20_000,
                    warnings: []
                )
                captures.append(SpeakerOptimizerMeasurementCapture(
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000
                        + (position == seatA ? 0 : 100)
                        + Double(repeatIndex)),
                    playbackSystemID: systemID,
                    routingSignature: "pr104-stable-route",
                    microphone: mic,
                    positionID: position,
                    source: left,
                    sampleRate: 48_000,
                    response: response,
                    quality: quality
                ))
            }
        }
        return SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: systemID,
            routingSignature: "pr104-stable-route",
            microphone: mic,
            sampleRate: 48_000,
            positions: [
                SpeakerOptimizerMeasurementPosition(id: seatA, name: "Main seat"),
                SpeakerOptimizerMeasurementPosition(id: seatB, name: "Second seat")
            ],
            plannedSources: [left],
            captures: captures
        )
    }
}
