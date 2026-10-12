import XCTest
@testable import NotchSixty

final class SpeakerOptimizerCrossDomainClassifierTests: XCTestCase {
    private let systemID = UUID(uuidString: "C4000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let targetID = UUID(uuidString: "C4100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let source: MultichannelCalibrationSource = .speaker(.frontLeft)
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr105-classifier-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: nil
    )

    func testMatchingSpeakerAndSeatFeatureClassifiesSpeakerPersistent() throws {
        let pair = makePair(
            characterizationFeatureDB: 5,
            seatFeaturesDB: [5, 4.8, 5.2]
        )
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: pair.characterization,
            listeningBaseline: pair.listening
        )
        let point = try pointNearest(2_000, in: report)
        XCTAssertEqual(point.classification, .speakerPersistent)
        XCTAssertTrue(point.supportsSpeakerCorrection)
        XCTAssertGreaterThan(abs(point.characterizationResidualDB), 1.5)
    }

    func testSeatSpecificNullWithFlatCharacterizationClassifiesRoomDependent() throws {
        let pair = makePair(
            characterizationFeatureDB: 0,
            seatFeaturesDB: [-7, 0, 5]
        )
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: pair.characterization,
            listeningBaseline: pair.listening
        )
        let point = try pointNearest(2_000, in: report)
        XCTAssertEqual(point.classification, .roomSeatDependent)
        XCTAssertFalse(point.supportsSpeakerCorrection)
        XCTAssertGreaterThan(point.listeningSeatSpreadDB, 1.5)
    }

    func testDomainDisagreementRemainsAmbiguous() throws {
        let pair = makePair(
            characterizationFeatureDB: 5,
            seatFeaturesDB: [-5, -5, -5]
        )
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: pair.characterization,
            listeningBaseline: pair.listening
        )
        XCTAssertEqual(
            try pointNearest(2_000, in: report).classification,
            .ambiguous
        )
    }

    func testFlatDomainsDoNotManufactureSpeakerDefect() throws {
        let pair = makePair(
            characterizationFeatureDB: 0,
            seatFeaturesDB: [0, 0, 0]
        )
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: pair.characterization,
            listeningBaseline: pair.listening
        )
        XCTAssertEqual(
            try pointNearest(2_000, in: report).classification,
            .noMaterialDeviation
        )
        XCTAssertTrue(report.previewOnly)
        XCTAssertFalse(report.canDeploy)
        XCTAssertFalse(report.isMeasuredVerification)
    }

    func testClassifierUsesOnlyEarlyWindowReliableBand() throws {
        let pair = makePair(
            characterizationFeatureDB: 5,
            seatFeaturesDB: [5, 5, 5]
        )
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: pair.characterization,
            listeningBaseline: pair.listening
        )
        let sourceReport = try XCTUnwrap(report.sources.first)
        XCTAssertGreaterThanOrEqual(sourceReport.frequenciesHz.first ?? 0, 350)
        XCTAssertFalse(sourceReport.frequenciesHz.contains { $0 < 300 })
    }

    func testAbsoluteMeasurementLevelDifferenceDoesNotDriveClassification() throws {
        let pair = makePair(
            characterizationFeatureDB: 0,
            seatFeaturesDB: [0, 0, 0],
            characterizationOffsetDB: 18,
            listeningOffsetDB: -9
        )
        let report = try SpeakerOptimizerCrossDomainClassifier().classify(
            characterization: pair.characterization,
            listeningBaseline: pair.listening
        )
        XCTAssertEqual(
            try pointNearest(2_000, in: report).classification,
            .noMaterialDeviation
        )
    }

    func testIdentityMismatchFailsBeforeCrossDomainComparison() throws {
        var pair = makePair(
            characterizationFeatureDB: 4,
            seatFeaturesDB: [4, 4, 4]
        )
        pair.listening.routingSignature = "other-route"
        XCTAssertThrowsError(
            try SpeakerOptimizerCrossDomainClassifier().classify(
                characterization: pair.characterization,
                listeningBaseline: pair.listening
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCrossDomainError,
                .incompatibleMeasurementDomains
            )
        }
    }

    func testMissingEarlyWindowRepeatsFailClosed() throws {
        var pair = makePair(
            characterizationFeatureDB: 4,
            seatFeaturesDB: [4, 4, 4]
        )
        pair.characterization.earlyWindowEvidence = Array(
            (pair.characterization.earlyWindowEvidence ?? []).prefix(2)
        )
        XCTAssertThrowsError(
            try SpeakerOptimizerCrossDomainClassifier().classify(
                characterization: pair.characterization,
                listeningBaseline: pair.listening
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCrossDomainError,
                .missingEarlyWindowEvidence(source)
            )
        }
    }

    private func pointNearest(
        _ frequency: Double,
        in report: SpeakerOptimizerCrossDomainReport
    ) throws -> SpeakerOptimizerCrossDomainPoint {
        let sourceReport = try XCTUnwrap(report.sources.first)
        return try XCTUnwrap(sourceReport.points.min {
            abs($0.frequencyHz - frequency) < abs($1.frequencyHz - frequency)
        })
    }

    private func makePair(
        characterizationFeatureDB: Double,
        seatFeaturesDB: [Double],
        characterizationOffsetDB: Double = 0,
        listeningOffsetDB: Double = 0
    ) -> (
        characterization: SpeakerOptimizerCharacterizationMeasurementSet,
        listening: SpeakerOptimizerMeasurementSet
    ) {
        let frequencies = makeFrequencies()
        let target = SpeakerOptimizerCharacterizationTarget(
            id: targetID,
            source: source,
            geometry: .init()
        )

        var characterizationCaptures: [SpeakerOptimizerMeasurementCapture] = []
        var early: [SpeakerOptimizerEarlyWindowEvidence] = []
        for repeatIndex in 0..<3 {
            let id = UUID()
            let response = makeResponse(
                frequencies: frequencies,
                featureDB: characterizationFeatureDB,
                offsetDB: characterizationOffsetDB
                    + Double(repeatIndex - 1) * 0.02
            )
            characterizationCaptures.append(makeCapture(
                id: id,
                positionID: targetID,
                response: response,
                repeatIndex: repeatIndex
            ))
            early.append(SpeakerOptimizerEarlyWindowEvidence(
                captureID: id,
                targetID: targetID,
                source: source,
                sampleRate: 48_000,
                response: RoomCorrectionFrequencyResponse(
                    frequenciesHz: frequencies.filter { $0 >= 350 },
                    magnitudeDB: zip(
                        frequencies,
                        response.magnitudeDB
                    ).filter { $0.0 >= 350 }.map(\.1),
                    phaseRadians: nil
                ),
                directArrivalSeconds: 0.003,
                retainedPreArrivalMilliseconds: 0.75,
                retainedPostArrivalMilliseconds: 6,
                fadeOutMilliseconds: 1.5,
                minimumReliableFrequencyHz: frequencies.first { $0 >= 350 }!,
                maximumReliableFrequencyHz: frequencies.last!,
                microphoneCalibrationFingerprint: nil,
                microphoneCalibrationApplied: false,
                warnings: []
            ))
        }

        let seats = seatFeaturesDB.enumerated().map { index, _ in
            SpeakerOptimizerMeasurementPosition(
                id: UUID(),
                name: "Seat \(index + 1)"
            )
        }
        var listeningCaptures: [SpeakerOptimizerMeasurementCapture] = []
        for (seatIndex, seat) in seats.enumerated() {
            for repeatIndex in 0..<3 {
                let response = makeResponse(
                    frequencies: frequencies,
                    featureDB: seatFeaturesDB[seatIndex],
                    offsetDB: listeningOffsetDB
                        + Double(repeatIndex - 1) * 0.02
                )
                listeningCaptures.append(makeCapture(
                    positionID: seat.id,
                    response: response,
                    repeatIndex: repeatIndex
                ))
            }
        }

        let listening = SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: systemID,
            routingSignature: "pr105-cross-domain-route",
            microphone: mic,
            sampleRate: 48_000,
            positions: seats,
            plannedSources: [source],
            captures: listeningCaptures
        )
        let characterization = SpeakerOptimizerCharacterizationMeasurementSet(
            playbackSystemID: systemID,
            routingSignature: "pr105-cross-domain-route",
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
        (0..<96).map { index in
            80 * pow(18_000.0 / 80.0, Double(index) / 95.0)
        }
    }

    private func makeResponse(
        frequencies: [Double],
        featureDB: Double,
        offsetDB: Double
    ) -> RoomCorrectionFrequencyResponse {
        RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: frequencies.map { frequency in
                let octaveDistance = log2(frequency / 2_000)
                let feature = featureDB
                    * exp(-0.5 * pow(octaveDistance / 0.11, 2))
                return offsetDB + feature
            },
            phaseRadians: frequencies.map { frequency in
                0.03 * log2(frequency / 1_000)
            }
        )
    }

    private func makeCapture(
        id: UUID = UUID(),
        positionID: UUID,
        response: RoomCorrectionFrequencyResponse,
        repeatIndex: Int
    ) -> SpeakerOptimizerMeasurementCapture {
        SpeakerOptimizerMeasurementCapture(
            id: id,
            capturedAt: Date(
                timeIntervalSince1970: 1_703_200_000 + Double(repeatIndex)
            ),
            playbackSystemID: systemID,
            routingSignature: "pr105-cross-domain-route",
            microphone: mic,
            positionID: positionID,
            source: source,
            sampleRate: 48_000,
            response: response,
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -20,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -70,
                estimatedSNRDB: 55,
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
