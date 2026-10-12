import XCTest
@testable import NotchSixty

final class SpeakerOptimizerClassificationAwareCandidateTests: XCTestCase {
    private let systemID = UUID(uuidString: "C5000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let targetID = UUID(uuidString: "C5100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let source: MultichannelCalibrationSource = .speaker(.frontLeft)
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr105-aware-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: nil
    )

    func testMaskAuthorizesOnlySpeakerPersistentPointsAndProtectsUnknownBand() throws {
        let baseline = makePair().listening
        let frequencies = makeFrequencies().filter { $0 >= 350 }
        let report = SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID: UUID(),
            listeningMeasurementSetID: baseline.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            sources: [
                SpeakerOptimizerCrossDomainSourceReport(
                    source: source,
                    frequenciesHz: frequencies,
                    points: frequencies.map { frequency in
                        SpeakerOptimizerCrossDomainPoint(
                            frequencyHz: frequency,
                            characterizationResidualDB: 0,
                            listeningMeanResidualDB: 0,
                            listeningSeatSpreadDB: 0,
                            classification:
                                abs(log2(frequency / 2_000)) < 0.30
                                ? .speakerPersistent : .roomSeatDependent
                        )
                    },
                    characterizationCaptureCount: 3,
                    listeningSeatCount: 2
                )
            ],
            warnings: []
        )
        let mask = try SpeakerOptimizerClassificationAwareCandidateDesigner()
            .makeMask(report: report, baseline: baseline)
        let vector = try mask.authorizationVector(
            source: source,
            frequenciesHz: [200, 2_000, 6_000]
        )
        XCTAssertEqual(vector, [false, false, false],
                       "Only exact qualified classification-grid points may authorize correction.")
        let exact = try XCTUnwrap(frequencies.min {
            abs($0 - 2_000) < abs($1 - 2_000)
        })
        let exactVector = try mask.authorizationVector(
            source: source,
            frequenciesHz: [exact]
        )
        XCTAssertEqual(exactVector, [true])
    }

    func testGuidedPEQCorrectsPersistentFeatureButProtectsRoomFeature() throws {
        let pair = makePair()
        let result = try SpeakerOptimizerClassificationAwareCandidateDesigner()
            .designPEQ(
                characterization: pair.characterization,
                listeningBaseline: pair.listening
            )
        XCTAssertTrue(result.previewOnly)
        XCTAssertFalse(result.canDeploy)
        let classification = try XCTUnwrap(result.classification.sources.first)
        XCTAssertEqual(
            try pointNearest(2_000, classification).classification,
            .speakerPersistent
        )
        XCTAssertEqual(
            try pointNearest(6_000, classification).classification,
            .roomSeatDependent
        )
        let candidate = try XCTUnwrap(result.candidate.sources.first)
        let protectedIndex = try XCTUnwrap(candidate.frequenciesHz.indices.min {
            abs(candidate.frequenciesHz[$0] - 6_000)
                < abs(candidate.frequenciesHz[$1] - 6_000)
        })
        XCTAssertLessThanOrEqual(
            abs(candidate.modeledFilterMagnitudeDB[protectedIndex]),
            0.5001
        )
        XCTAssertTrue(candidate.warnings.contains {
            $0.localizedCaseInsensitiveContains("classification")
        })
    }

    func testGuidedFIRNeverLeaksMaterialCorrectionIntoRoomDependentFeature() throws {
        let pair = makePair()
        let result = try SpeakerOptimizerClassificationAwareCandidateDesigner()
            .designFIR(
                characterization: pair.characterization,
                listeningBaseline: pair.listening
            )
        XCTAssertFalse(result.canDeploy)
        let candidate = try XCTUnwrap(result.candidate.sources.first)
        if candidate.acceptedForPreview {
            let protectedIndex = try XCTUnwrap(candidate.frequenciesHz.indices.min {
                abs(candidate.frequenciesHz[$0] - 6_000)
                    < abs(candidate.frequenciesHz[$1] - 6_000)
            })
            XCTAssertLessThanOrEqual(
                abs(candidate.modeledFilterMagnitudeDB[protectedIndex]),
                0.5001
            )
        } else {
            XCTAssertTrue(candidate.taps.isEmpty)
            XCTAssertFalse(candidate.blockingReasons.isEmpty)
        }
    }

    func testGuidedPathRecomputesClassificationAndFailsOnDomainIdentityDrift() throws {
        var pair = makePair()
        pair.characterization.routingSignature = "stale-route"
        XCTAssertThrowsError(
            try SpeakerOptimizerClassificationAwareCandidateDesigner()
                .designPEQ(
                    characterization: pair.characterization,
                    listeningBaseline: pair.listening
                )
        )
    }

    private func pointNearest(
        _ frequency: Double,
        _ report: SpeakerOptimizerCrossDomainSourceReport
    ) throws -> SpeakerOptimizerCrossDomainPoint {
        try XCTUnwrap(report.points.min {
            abs($0.frequencyHz - frequency) < abs($1.frequencyHz - frequency)
        })
    }

    private func makePair() -> (
        characterization: SpeakerOptimizerCharacterizationMeasurementSet,
        listening: SpeakerOptimizerMeasurementSet
    ) {
        let frequencies = makeFrequencies()
        let target = SpeakerOptimizerCharacterizationTarget(
            id: targetID,
            source: source,
            geometry: .init()
        )
        let seatIDs = [
            UUID(uuidString: "C5200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            UUID(uuidString: "C5300000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
        ]
        let seats = seatIDs.enumerated().map {
            SpeakerOptimizerMeasurementPosition(
                id: $0.element,
                name: "Seat \($0.offset + 1)"
            )
        }

        var characterizationCaptures: [SpeakerOptimizerMeasurementCapture] = []
        var early: [SpeakerOptimizerEarlyWindowEvidence] = []
        for repeatIndex in 0..<3 {
            let id = UUID()
            let near = response(
                frequencies: frequencies,
                persistentDB: 6,
                roomDB: 0,
                repeatIndex: repeatIndex
            )
            characterizationCaptures.append(capture(
                id: id,
                positionID: targetID,
                response: near,
                repeatIndex: repeatIndex
            ))
            let valid = frequencies.indices.filter { frequencies[$0] >= 350 }
            early.append(SpeakerOptimizerEarlyWindowEvidence(
                captureID: id,
                targetID: targetID,
                source: source,
                sampleRate: 48_000,
                response: RoomCorrectionFrequencyResponse(
                    frequenciesHz: valid.map { frequencies[$0] },
                    magnitudeDB: valid.map { near.magnitudeDB[$0] },
                    phaseRadians: nil
                ),
                directArrivalSeconds: 0.003,
                retainedPreArrivalMilliseconds: 0.75,
                retainedPostArrivalMilliseconds: 6,
                fadeOutMilliseconds: 1.5,
                minimumReliableFrequencyHz: frequencies[valid.first!],
                maximumReliableFrequencyHz: frequencies[valid.last!],
                microphoneCalibrationFingerprint: nil,
                microphoneCalibrationApplied: false,
                warnings: []
            ))
        }

        var listeningCaptures: [SpeakerOptimizerMeasurementCapture] = []
        for seat in seats {
            for repeatIndex in 0..<3 {
                listeningCaptures.append(capture(
                    positionID: seat.id,
                    response: response(
                        frequencies: frequencies,
                        persistentDB: 6,
                        roomDB: 5,
                        repeatIndex: repeatIndex
                    ),
                    repeatIndex: repeatIndex
                ))
            }
        }
        let listening = SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: systemID,
            routingSignature: "pr105-aware-route",
            microphone: mic,
            sampleRate: 48_000,
            positions: seats,
            plannedSources: [source],
            captures: listeningCaptures
        )
        let characterization = SpeakerOptimizerCharacterizationMeasurementSet(
            playbackSystemID: systemID,
            routingSignature: "pr105-aware-route",
            microphone: mic,
            sampleRate: 48_000,
            linkedListeningMeasurementSetID: listening.id,
            targets: [target],
            captures: characterizationCaptures,
            earlyWindowEvidence: early
        )
        return (characterization, listening)
    }

    private func makeFrequencies() -> [Double] {
        (0..<128).map { index in
            80 * pow(18_000.0 / 80.0, Double(index) / 127.0)
        }
    }

    private func response(
        frequencies: [Double],
        persistentDB: Double,
        roomDB: Double,
        repeatIndex: Int
    ) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: frequencies.map { frequency in
                gaussian(frequency, center: 2_000, gain: persistentDB, width: 0.18)
                    + gaussian(frequency, center: 6_000, gain: roomDB, width: 0.18)
                    + Double(repeatIndex - 1) * 0.03
            },
            phaseRadians: frequencies.map { 0.02 * log2($0 / 1_000) }
        )
    }

    private func gaussian(
        _ frequency: Double,
        center: Double,
        gain: Double,
        width: Double
    ) -> Double {
        gain * exp(-0.5 * pow(log2(frequency / center) / width, 2))
    }

    private func capture(
        id: UUID = UUID(),
        positionID: UUID,
        response: RoomCorrectionFrequencyResponse,
        repeatIndex: Int
    ) -> SpeakerOptimizerMeasurementCapture {
        SpeakerOptimizerMeasurementCapture(
            id: id,
            capturedAt: Date(timeIntervalSince1970:
                1_703_300_000 + Double(repeatIndex)),
            playbackSystemID: systemID,
            routingSignature: "pr105-aware-route",
            microphone: mic,
            positionID: positionID,
            source: source,
            sampleRate: 48_000,
            response: response,
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -20,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -72,
                estimatedSNRDB: 58,
                sweepComplete: true,
                directArrivalSeconds: 0.003
                    + Double(repeatIndex) * 0.00002,
                usableLowHz: 80,
                usableHighHz: 18_000,
                warnings: []
            )
        )
    }
}
