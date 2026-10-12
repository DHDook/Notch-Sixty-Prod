import XCTest
@testable import NotchSixty

final class SpeakerOptimizerEarlyWindowCharacterizationTests: XCTestCase {
    private let systemID = UUID(uuidString: "C3000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let targetID = UUID(uuidString: "C3100000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!

    func testDefaultGateExcludesLateReflectionAndPublishesMagnitudeOnly() throws {
        let target = makeTarget()
        let channel = makeChannel(lateReflectionGain: 0.8)
        let evidence = try SpeakerOptimizerEarlyWindowAnalyzer().derive(
            channel: channel,
            captureID: UUID(),
            target: target,
            sampleRate: 48_000,
            microphone: makeMicrophone(),
            microphoneCalibration: nil
        )

        XCTAssertTrue(evidence.magnitudeOnly)
        XCTAssertFalse(evidence.isAnechoic)
        XCTAssertNil(evidence.response.phaseRadians)
        XCTAssertGreaterThan(evidence.minimumReliableFrequencyHz, 300)
        XCTAssertLessThan(evidence.minimumReliableFrequencyHz, 500)
        XCTAssertEqual(evidence.retainedPostArrivalMilliseconds, 6, accuracy: 0.05)
        for magnitude in evidence.response.magnitudeDB {
            XCTAssertEqual(magnitude, 0, accuracy: 0.08)
        }
    }

    func testEarlyWindowReappliesTrackedMicrophoneCalibration() throws {
        let calibration = RoomCorrectionMicrophoneCalibration(
            sourceName: "Synthetic +3 dB",
            points: [
                .init(frequencyHz: 20, gainDB: 3),
                .init(frequencyHz: 1_000, gainDB: 3),
                .init(frequencyHz: 20_000, gainDB: 3),
            ]
        )
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr105-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: "Synthetic +3 dB"
        )
        let evidence = try SpeakerOptimizerEarlyWindowAnalyzer().derive(
            channel: makeChannel(lateReflectionGain: 0),
            captureID: UUID(),
            target: makeTarget(),
            sampleRate: 48_000,
            microphone: mic,
            microphoneCalibration: calibration
        )

        XCTAssertTrue(evidence.microphoneCalibrationApplied)
        XCTAssertEqual(
            evidence.microphoneCalibrationFingerprint,
            "Synthetic +3 dB"
        )
        for magnitude in evidence.response.magnitudeDB {
            XCTAssertEqual(magnitude, 3, accuracy: 0.08)
        }
    }

    func testCalibrationFingerprintMismatchFailsClosed() throws {
        let calibration = RoomCorrectionMicrophoneCalibration(
            sourceName: "Other calibration",
            points: [
                .init(frequencyHz: 20, gainDB: 0),
                .init(frequencyHz: 20_000, gainDB: 0),
            ]
        )
        let mic = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr105-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: "Expected calibration"
        )
        XCTAssertThrowsError(
            try SpeakerOptimizerEarlyWindowAnalyzer().derive(
                channel: makeChannel(lateReflectionGain: 0),
                captureID: UUID(),
                target: makeTarget(),
                sampleRate: 48_000,
                microphone: mic,
                microphoneCalibration: calibration
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerEarlyWindowError,
                .microphoneCalibrationIdentityMismatch
            )
        }
    }

    func testWindowReliabilityBoundaryMovesUpWhenGateShortens() throws {
        let analyzer = SpeakerOptimizerEarlyWindowAnalyzer()
        let long = try analyzer.derive(
            channel: makeChannel(lateReflectionGain: 0),
            captureID: UUID(),
            target: makeTarget(),
            sampleRate: 48_000,
            microphone: makeMicrophone(),
            microphoneCalibration: nil,
            settings: .init(
                preArrivalMilliseconds: 0.75,
                postArrivalMilliseconds: 8,
                fadeOutMilliseconds: 1.5,
                minimumCyclesForReliableMagnitude: 2
            )
        )
        let short = try analyzer.derive(
            channel: makeChannel(lateReflectionGain: 0),
            captureID: UUID(),
            target: makeTarget(),
            sampleRate: 48_000,
            microphone: makeMicrophone(),
            microphoneCalibration: nil,
            settings: .init(
                preArrivalMilliseconds: 0.75,
                postArrivalMilliseconds: 4,
                fadeOutMilliseconds: 1,
                minimumCyclesForReliableMagnitude: 2
            )
        )
        XCTAssertGreaterThan(
            short.minimumReliableFrequencyHz,
            long.minimumReliableFrequencyHz
        )
    }

    func testBuilderDerivesBeforeCompactionAndEvidencePersistsWithoutImpulse() throws {
        let target = makeTarget()
        let channel = makeChannel(lateReflectionGain: 0.7)
        let measurement = MultichannelCalibrationMeasurement(
            id: UUID(uuidString: "C3200000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            seatID: target.id,
            source: target.source,
            sampleRate: 48_000,
            channel: channel
        )
        let built = try SpeakerOptimizerCharacterizationCaptureBuilder().build(
            measurement: measurement,
            playbackSystemID: systemID,
            routingSignature: "pr105-window-route",
            microphone: makeMicrophone(),
            target: target,
            microphoneCalibration: nil
        )
        XCTAssertEqual(built.capture.id, measurement.id)
        XCTAssertEqual(built.earlyWindow.captureID, measurement.id)
        XCTAssertFalse(built.capture.response.magnitudeDB.isEmpty)

        var set = SpeakerOptimizerCharacterizationMeasurementSet(
            playbackSystemID: systemID,
            routingSignature: "pr105-window-route",
            microphone: makeMicrophone(),
            sampleRate: 48_000,
            linkedListeningMeasurementSetID: nil,
            targets: [target],
            captures: [built.capture],
            earlyWindowEvidence: [built.earlyWindow]
        )
        try set.validateStructure()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR105-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerOptimizerCharacterizationSetStore(rootDirectory: root)
        try store.save(set)
        let data = try Data(contentsOf: store.url(for: set.id))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("minimumReliableFrequencyHz"))
        XCTAssertFalse(json.contains("rawCapture"))
        XCTAssertFalse(json.contains("impulseResponse"))

        set.earlyWindowEvidence?[0].targetID = UUID()
        XCTAssertThrowsError(try set.validateStructure())
    }

    func testInsufficientImpulseAfterArrivalFailsClosed() throws {
        var channel = makeChannel(lateReflectionGain: 0)
        channel.impulseResponse = Array(channel.impulseResponse.prefix(220))
        XCTAssertThrowsError(
            try SpeakerOptimizerEarlyWindowAnalyzer().derive(
                channel: channel,
                captureID: UUID(),
                target: makeTarget(),
                sampleRate: 48_000,
                microphone: makeMicrophone(),
                microphoneCalibration: nil
            )
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerEarlyWindowError,
                .insufficientPostArrivalImpulse
            )
        }
    }

    private func makeTarget() -> SpeakerOptimizerCharacterizationTarget {
        SpeakerOptimizerCharacterizationTarget(
            id: targetID,
            source: .speaker(.frontLeft),
            geometry: .init()
        )
    }

    private func makeMicrophone() -> SpeakerOptimizerMicrophoneIdentity {
        SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr105-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: nil
        )
    }

    private func makeChannel(
        lateReflectionGain: Float
    ) -> RoomCorrectionChannelMeasurement {
        let sampleRate = 48_000.0
        let arrival = 100
        var impulse = [Float](repeating: 0, count: 2_048)
        impulse[arrival] = 1
        let late = arrival + Int((sampleRate * 0.010).rounded())
        if late < impulse.count {
            impulse[late] = lateReflectionGain
        }
        let frequencies = (0..<96).map { index in
            80.0 * pow(
                18_000.0 / 80.0,
                Double(index) / 95.0
            )
        }
        return RoomCorrectionChannelMeasurement(
            capturedAt: Date(timeIntervalSince1970: 1_703_100_000),
            rawCapture: [0.1, 0.2, 0.1],
            impulseResponse: impulse,
            transferFunction: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: frequencies.map { _ in 0 },
                phaseRadians: frequencies.map { _ in 0 }
            ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -18,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -70,
                estimatedSNRDB: 55,
                sweepComplete: true,
                directArrivalSeconds: Double(arrival) / sampleRate,
                usableLowHz: 80,
                usableHighHz: 18_000,
                warnings: []
            )
        )
    }
}
