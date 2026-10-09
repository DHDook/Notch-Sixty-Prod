import CoreAudio
import XCTest
@testable import NotchSixty

final class QuietZoneInstrumentedProbeCaptureTests: XCTestCase {
    private let sampleRate = 48_000.0
    private func probe() -> [Float] {
        var x: UInt32 = 0x1234BEEF
        return (0..<128).map { _ in
            x = x &* 1_664_525 &+ 1_013_904_223
            return x & 0x80000000 == 0 ? 0.4 : -0.4
        }
    }

    private func fixture(
        position: QuietZoneFeedForwardPosition = .listenerFirst
    ) throws -> QuietZoneInstrumentedProbeCollector {
        try .init(
            position: position, microphoneID: "mic",
            microphoneChannel: 0, sourceFixtureID: "external-fixture",
            synchronizedClockID: "hardware-clock",
            physicalSourceID: "hallway-loudspeaker",
            routeLeaseID: "selected-DAC-session",
            sampleRate: sampleRate
        )
    }

    private func launch(_ offsetFrames: Int = 480) -> QuietZoneInstrumentedSourceLaunch {
        .init(
            launchID: "independent-shot-1",
            sourceFixtureID: "external-fixture",
            synchronizedClockID: "hardware-clock",
            physicalSourceID: "hallway-loudspeaker",
            routeLeaseID: "selected-DAC-session",
            sampleRate: sampleRate,
            emissionHostSeconds: 100 + Double(offsetFrames) / sampleRate,
            oneSigmaTimingUncertaintySeconds: 0.00005,
            physicalClockCalibrationVerified: true,
            emittedProbe: probe()
        )
    }

    private func captureFrames(
        onset: Int = 1_200, count: Int = 2_048,
        skippedFrame: Int? = nil, clipped: Bool = false
    ) -> [N60FeedForwardReferenceFrame] {
        let sequence = probe()
        var data = [Float](repeating: 0.0001, count: count)
        for i in sequence.indices { data[onset + i] += sequence[i] * 0.5 }
        if clipped { data[onset] = 1 }
        let host = AudioConvertNanosToHostTime(100_000_000_000)
        return data.indices.map { index in
            var result = N60FeedForwardReferenceFrame()
            result.sample = data[index]
            result.firstFrameHostTime = host
            result.firstFrameSampleTime = 10_000
            result.frameOffset = UInt32(index)
            if let skippedFrame, index >= skippedFrame {
                result.frameOffset += 1
            }
            return result
        }
    }

    func testMeasuredSourceCaptureBuildsRealProbePayload() throws {
        var collector = try fixture()
        let frames = captureFrames()
        try collector.append(Array(frames[0..<800]))
        try collector.append(Array(frames[800..<frames.count]))
        let record = try collector.finish(launch: launch())
        XCTAssertEqual(record.position, .listenerFirst)
        XCTAssertEqual(record.microphoneDeviceID, "mic")
        XCTAssertEqual(record.recordedSamples.count, 2_048)
        XCTAssertEqual(
            record.firstInputFrameAfterTriggerSeconds,
            -480 / sampleRate, accuracy: 1.0 / sampleRate
        )
        let result = try QuietZoneFeedForwardProbeDetector().detect(record)
        XCTAssertEqual(
            result.arrivalAfterTriggerSeconds,
            (1_200 - 480) / sampleRate, accuracy: 1 / sampleRate
        )
    }

    func testRejectsMissingOrUncalibratedSourceWitness() throws {
        var collector = try fixture()
        try collector.append(captureFrames())
        var bad = launch()
        bad.physicalClockCalibrationVerified = false
        XCTAssertThrowsError(try collector.finish(launch: bad)) {
            XCTAssertEqual(
                $0 as? QuietZoneInstrumentedProbeError, .uncalibratedTrigger
            )
        }
        bad = launch()
        bad.synchronizedClockID = "unsynced-phone"
        XCTAssertThrowsError(try collector.finish(launch: bad))
        bad = launch()
        bad.routeLeaseID = "different-session"
        XCTAssertThrowsError(try collector.finish(launch: bad))
        bad = launch()
        bad.oneSigmaTimingUncertaintySeconds = 0.005
        XCTAssertThrowsError(try collector.finish(launch: bad))
    }

    func testNoPreRollOrLateTriggerFailsClosed() throws {
        var collector = try fixture()
        try collector.append(captureFrames())
        XCTAssertThrowsError(try collector.finish(launch: launch(16)))
        XCTAssertThrowsError(try collector.finish(launch: launch(2_040)))
    }

    func testDroppedSampleAndClippingAreRejected() throws {
        var collector = try fixture()
        XCTAssertThrowsError(try collector.append(
            captureFrames(skippedFrame: 1_024)
        )) {
            XCTAssertEqual(
                $0 as? QuietZoneInstrumentedProbeError, .discontinuousInput
            )
        }
        collector = try fixture()
        XCTAssertThrowsError(try collector.append(captureFrames(clipped: true))) {
            XCTAssertEqual(
                $0 as? QuietZoneInstrumentedProbeError, .unusableAudio
            )
        }
    }

    func testStableSourceRepetitionsRequireIndependentLaunchIDs() throws {
        let id = UUID(), begin = Date()
        var session = try QuietZoneFeedForwardSurveySession(
            projectID: id, microphoneStableID: "mic", microphoneChannel: 0,
            routeFingerprint: "selected-DAC-session",
            clockID: "hardware-clock", stimulusID: "external-fixture",
            now: begin
        )
        let positions: [(QuietZoneFeedForwardPosition, Int)] = [
            (.listenerFirst, 1200), (.upstream, 700), (.listenerReturn, 1200)
        ]
        for (index, entry) in positions.enumerated() {
            var collector = try fixture(position: entry.0)
            try collector.append(captureFrames(onset: entry.1))
            var shot = launch()
            shot.launchID = "shot-\(index)"
            let record = try collector.finish(launch: shot)
            _ = try session.add(
                record, projectID: id,
                capturedAt: begin.addingTimeInterval(Double(index + 1))
            )
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.arrivals.count, 3)
    }
}
