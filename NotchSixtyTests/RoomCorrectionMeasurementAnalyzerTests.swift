import Foundation
import XCTest
@testable import NotchSixty

final class RoomCorrectionMeasurementAnalyzerTests: XCTestCase {
    private func makePlan() throws -> RoomCorrectionMeasurementPlan {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: 8_000,
            startFrequencyHz: 100,
            endFrequencyHz: 3_000,
            durationSeconds: 0.1,
            levelDBFS: -12,
            leadInSeconds: 0.02,
            tailSeconds: 0.08,
            fadeSeconds: 0.005
        )
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        return try RoomCorrectionMeasurementPlan(program: program, settlingSeconds: 0.01)
    }

    private func makeCapture(
        program: RoomCorrectionSweepProgram,
        gain: Float = 1,
        delayFrames: Int = 0,
        noiseAmplitude: Float = 0
    ) -> [Float] {
        var result = [Float](repeating: 0, count: program.captureFrameCount)
        if noiseAmplitude > 0 {
            for index in result.indices {
                result[index] = index.isMultiple(of: 2) ? noiseAmplitude : -noiseAmplitude
            }
        }
        for index in program.sweepSamples.indices {
            let destination = program.leadInFrames + delayFrames + index
            guard destination < result.count else { break }
            result[destination] += gain * program.sweepSamples[index]
        }
        return result
    }

    private func closestMagnitude(
        _ response: RoomCorrectionFrequencyResponse,
        to frequency: Double
    ) -> Double {
        let index = response.frequenciesHz.indices.min { lhs, rhs in
            abs(response.frequenciesHz[lhs] - frequency)
                < abs(response.frequenciesHz[rhs] - frequency)
        }!
        return response.magnitudeDB[index]
    }

    private func closestPhase(
        _ response: RoomCorrectionFrequencyResponse,
        to frequency: Double
    ) -> Double {
        let index = response.frequenciesHz.indices.min { lhs, rhs in
            abs(response.frequenciesHz[lhs] - frequency)
                < abs(response.frequenciesHz[rhs] - frequency)
        }!
        return response.phaseRadians![index]
    }

    func testIdentityESSDeconvolutionProducesZeroDelayFlatTransfer() throws {
        let plan = try makePlan()
        let raw = makeCapture(
            program: plan.program,
            noiseAmplitude: 0.000_01
        )
        let capturedAt = Date(timeIntervalSince1970: 123)
        let result = try RoomCorrectionMeasurementAnalyzer().analyze(
            capture: RoomCorrectionCalibrationCapture(left: raw, right: raw),
            plan: plan,
            capturedAt: capturedAt
        )

        XCTAssertEqual(result.sampleRate, 8_000)
        XCTAssertEqual(result.left.capturedAt, capturedAt)
        XCTAssertEqual(result.left.rawCapture, raw)
        XCTAssertEqual(result.right.rawCapture, raw)
        XCTAssertTrue(result.left.quality.sweepComplete)
        XCTAssertFalse(result.left.quality.clipped)
        XCTAssertEqual(result.left.quality.directArrivalSeconds ?? -1, 0, accuracy: 1.0 / 8_000.0)
        XCTAssertGreaterThan(result.left.impulseResponse.count, 0)

        let response = try XCTUnwrap(result.left.transferFunction)
        XCTAssertEqual(response.frequenciesHz.count, RoomCorrectionMeasurementAnalyzer.responsePointCount)
        XCTAssertEqual(response.magnitudeDB.count, response.frequenciesHz.count)
        XCTAssertEqual(response.phaseRadians?.count, response.frequenciesHz.count)
        XCTAssertEqual(closestMagnitude(response, to: 1_000), 0, accuracy: 0.35)
        XCTAssertEqual(closestMagnitude(response, to: 2_000), 0, accuracy: 0.35)
        XCTAssertEqual(closestPhase(response, to: 1_000), 0, accuracy: 0.12)
        XCTAssertGreaterThan(result.left.quality.estimatedSNRDB ?? 0, 40)
    }

    func testDelayedHalfGainResponseFindsArrivalAndRemovesBulkDelayFromPhase() throws {
        let plan = try makePlan()
        let delayFrames = 40
        let raw = makeCapture(
            program: plan.program,
            gain: 0.5,
            delayFrames: delayFrames,
            noiseAmplitude: 0.000_01
        )
        let result = try RoomCorrectionMeasurementAnalyzer().analyze(
            capture: RoomCorrectionCalibrationCapture(left: raw, right: raw),
            plan: plan
        )
        let response = try XCTUnwrap(result.left.transferFunction)

        XCTAssertEqual(
            result.left.quality.directArrivalSeconds ?? -1,
            Double(delayFrames) / 8_000.0,
            accuracy: 2.0 / 8_000.0
        )
        XCTAssertEqual(closestMagnitude(response, to: 1_000), -6.0206, accuracy: 0.45)
        XCTAssertEqual(closestPhase(response, to: 1_000), 0, accuracy: 0.20)
    }

    func testMicrophoneCalibrationGainIsAppliedToReportedMagnitude() throws {
        let plan = try makePlan()
        let raw = makeCapture(program: plan.program)
        let calibration = RoomCorrectionMicrophoneCalibration(
            sourceName: "Synthetic calibration",
            points: [
                RoomCorrectionCalibrationPoint(frequencyHz: 100, gainDB: 3),
                RoomCorrectionCalibrationPoint(frequencyHz: 1_000, gainDB: 3),
                RoomCorrectionCalibrationPoint(frequencyHz: 3_000, gainDB: 3),
            ]
        )
        let result = try RoomCorrectionMeasurementAnalyzer().analyze(
            capture: RoomCorrectionCalibrationCapture(left: raw, right: raw),
            plan: plan,
            microphoneCalibration: calibration
        )
        let response = try XCTUnwrap(result.left.transferFunction)

        XCTAssertEqual(closestMagnitude(response, to: 1_000), 3, accuracy: 0.35)
        XCTAssertEqual(closestMagnitude(response, to: 2_000), 3, accuracy: 0.35)
    }

    func testCaptureLengthMismatchFailsClosedBeforeTransformWork() throws {
        let plan = try makePlan()
        let complete = makeCapture(program: plan.program)
        let shortLeft = Array(complete.dropLast())

        XCTAssertThrowsError(
            try RoomCorrectionMeasurementAnalyzer().analyze(
                capture: RoomCorrectionCalibrationCapture(left: shortLeft, right: complete),
                plan: plan
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionMeasurementAnalysisError,
                .captureLength(
                    pass: .left,
                    expected: plan.leftPass.captureFrameCount,
                    actual: shortLeft.count
                )
            )
        }
    }

    func testNonFiniteCaptureAndInvalidCalibrationFailClosed() throws {
        let plan = try makePlan()
        var invalidCapture = makeCapture(program: plan.program)
        invalidCapture[plan.program.leadInFrames] = .nan

        XCTAssertThrowsError(
            try RoomCorrectionMeasurementAnalyzer().analyze(
                capture: RoomCorrectionCalibrationCapture(left: invalidCapture, right: invalidCapture),
                plan: plan
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionMeasurementAnalysisError,
                .nonFiniteCapture(pass: .left)
            )
        }

        let validCapture = makeCapture(program: plan.program)
        let invalidCalibration = RoomCorrectionMicrophoneCalibration(
            sourceName: "Invalid",
            points: [RoomCorrectionCalibrationPoint(frequencyHz: 1_000, gainDB: 0)]
        )
        XCTAssertThrowsError(
            try RoomCorrectionMeasurementAnalyzer().analyze(
                capture: RoomCorrectionCalibrationCapture(left: validCapture, right: validCapture),
                plan: plan,
                microphoneCalibration: invalidCalibration
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionMeasurementAnalysisError,
                .invalidMicrophoneCalibration
            )
        }
    }

    func testClippingAndLowSNRQualityWarningsAreDeterministic() throws {
        let plan = try makePlan()
        var raw = makeCapture(
            program: plan.program,
            gain: 0.05,
            noiseAmplitude: 0.02
        )
        raw[plan.program.leadInFrames] = 1.0

        let result = try RoomCorrectionMeasurementAnalyzer().analyze(
            capture: RoomCorrectionCalibrationCapture(left: raw, right: raw),
            plan: plan
        )

        XCTAssertTrue(result.left.quality.clipped)
        XCTAssertTrue(result.left.quality.warnings.contains { $0.contains("full scale") })
        XCTAssertTrue(result.left.quality.warnings.contains { $0.contains("SNR") })
    }

    func testPR43AcousticDiagnosticsDeriveStepDecayAndGroupDelay() throws {
        let sampleRate = 1_000.0
        let impulse: [Float] = [0, 1, 0.5, 0.25, 0, 0]
        let delaySeconds = 0.005
        let frequencies = [100.0, 200.0, 400.0, 800.0]
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: [0, 0, 0, 0],
            phaseRadians: frequencies.map { -2.0 * Double.pi * $0 * delaySeconds }
        )

        let diagnostics = try RoomCorrectionAcousticDiagnosticsAnalyzer().analyze(
            impulseResponse: impulse,
            transferFunction: response,
            sampleRate: sampleRate,
            referenceArrivalSeconds: 0.001
        )

        XCTAssertEqual(diagnostics.impulse.x[1], 0, accuracy: 1.0e-9)
        XCTAssertEqual(diagnostics.impulse.y[1], 1, accuracy: 1.0e-9)
        XCTAssertEqual(diagnostics.step.y.count, impulse.count)
        XCTAssertEqual(diagnostics.energyTimeCurveDB.y.max() ?? -999, 0, accuracy: 1.0e-9)
        XCTAssertEqual(diagnostics.energyDecayDB.y.first ?? -999, 0, accuracy: 1.0e-9)

        for index in diagnostics.energyDecayDB.y.indices.dropFirst() {
            XCTAssertLessThanOrEqual(
                diagnostics.energyDecayDB.y[index],
                diagnostics.energyDecayDB.y[index - 1] + 1.0e-12
            )
        }

        let groupDelay = try XCTUnwrap(diagnostics.groupDelayMilliseconds)
        XCTAssertEqual(groupDelay.x, frequencies)
        for value in groupDelay.y {
            XCTAssertEqual(value, 5.0, accuracy: 1.0e-9)
        }
    }

    func testPR43AcousticDiagnosticsFailClosedOnInvalidInputs() throws {
        let analyzer = RoomCorrectionAcousticDiagnosticsAnalyzer()
        XCTAssertThrowsError(
            try analyzer.analyze(
                impulseResponse: [1],
                transferFunction: nil,
                sampleRate: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionAcousticDiagnosticsError,
                .invalidSampleRate(0)
            )
        }

        let invalidResponse = RoomCorrectionFrequencyResponse(
            frequenciesHz: [100, 100],
            magnitudeDB: [0, 0],
            phaseRadians: [0, 0]
        )
        XCTAssertThrowsError(
            try analyzer.analyze(
                impulseResponse: [1, 0],
                transferFunction: invalidResponse,
                sampleRate: 48_000
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionAcousticDiagnosticsError,
                .invalidTransferFunction
            )
        }
    }


    // MARK: E24 S4 repeats

    private func repeatSettings(rate: Double, repeats: Int, duration: Double = 0.1) -> RoomCorrectionSweepSettings {
        RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 100, endFrequencyHz: min(3_000, rate * 0.4),
            durationSeconds: duration, levelDBFS: -12, leadInSeconds: 0.02, tailSeconds: 0.08,
            fadeSeconds: 0.005, repeatCount: repeats)
    }

    func testRepeatTrainLayoutAtEveryStandardRate() throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let single = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: rate, repeats: 1, duration: 0.05))
            let train = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: rate, repeats: 3, duration: 0.05))
            let sweep = single.sweepSamples.count
            let period = sweep + single.tailFrames
            XCTAssertEqual(train.repeatPeriodFrames, period, "\(rate)")
            XCTAssertEqual(train.sweepSamples.count, 2 * period + sweep, "\(rate)")
            XCTAssertEqual(train.captureFrameCount, single.leadInFrames + 3 * period, "\(rate)")
            XCTAssertEqual(train.excitation, single.sweepSamples, "\(rate)")
            for r in 0..<3 {
                XCTAssertEqual(Array(train.sweepSamples[(r * period)..<(r * period + sweep)]), single.sweepSamples, "\(rate) repeat \(r)")
            }
            XCTAssertTrue(train.sweepSamples[sweep..<period].allSatisfy { $0 == 0 }, "\(rate) silent tail")
            // N = 1 is today's program.
            XCTAssertEqual(single.repeatCount, 1)
            XCTAssertTrue(single.excitation.isEmpty)
            XCTAssertEqual(single.captureFrameCount, single.leadInFrames + sweep + single.tailFrames)
        }
    }

    func testSettingsWithoutRepeatCountDecodeAsOne() throws {
        let stored = RoomCorrectionSweepSettings(sampleRate: 48_000)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [String: Any]
        json.removeValue(forKey: "repeatCount")
        let decoded = try JSONDecoder().decode(
            RoomCorrectionSweepSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.repeatCount, 1)
        XCTAssertEqual(decoded, stored)
    }

    private func noisy(_ seed: UInt32, _ count: Int, amplitude: Float) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(state >> 8) / Float(1 << 24) * 2 - 1)
        }
    }

    private func trainCapture(_ program: RoomCorrectionSweepProgram, corrupt: [Int] = []) -> [Float] {
        var capture = makeCapture(program: program, gain: 0.5, delayFrames: 12, noiseAmplitude: 0.000_01)
        let period = program.repeatPeriodFrames
        for r in corrupt {
            let start = program.leadInFrames + r * period
            let burst = noisy(UInt32(7 + r), period, amplitude: 0.4)
            for k in 0..<period where start + k < capture.count { capture[start + k] = burst[k] }
        }
        return capture
    }

    func testRepeatsAverageToTheSingleSweepResultAndRejectABurstCorruptedRepeat() throws {
        let analyzer = RoomCorrectionMeasurementAnalyzer()
        let rate = 8_000.0
        let single = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: rate, repeats: 1))
        let clean = try analyzer.analyzeSingleChannel(
            rawCapture: makeCapture(program: single, gain: 0.5, delayFrames: 12, noiseAmplitude: 0.000_01), program: single)

        let train = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: rate, repeats: 4))
        let averaged = try analyzer.analyzeSingleChannel(rawCapture: trainCapture(train, corrupt: [2]), program: train)
        XCTAssertEqual(averaged.quality.repeatCount, 4)
        XCTAssertEqual(averaged.quality.rejectedRepeats, [2])
        XCTAssertEqual(averaged.quality.rejectedRepeatReasons?.count, 1)
        XCTAssertEqual(averaged.quality.repeatSummary?.hasPrefix("3 of 4 repeats kept; repeat 3 rejected"), true)
        XCTAssertEqual(averaged.quality.directArrivalSeconds ?? -1, clean.quality.directArrivalSeconds ?? -2, accuracy: 1e-9)
        let a = averaged.transferFunction!, c = clean.transferFunction!
        var checked = 0
        for (index, f) in c.frequenciesHz.enumerated() where f >= 300 && f <= 2_500 {
            XCTAssertEqual(a.magnitudeDB[index], c.magnitudeDB[index], accuracy: 0.2, "\(f) Hz")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
    }

    func testAllCleanRepeatsAreKeptAndASingleRepeatReportsNoSummary() throws {
        let analyzer = RoomCorrectionMeasurementAnalyzer()
        let train = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: 8_000, repeats: 3))
        let result = try analyzer.analyzeSingleChannel(rawCapture: trainCapture(train), program: train)
        XCTAssertEqual(result.quality.rejectedRepeats, [])
        XCTAssertEqual(result.quality.repeatSummary, "3 of 3 repeats kept")

        let single = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: 8_000, repeats: 1))
        let one = try analyzer.analyzeSingleChannel(rawCapture: makeCapture(program: single), program: single)
        XCTAssertNil(one.quality.repeatCount)
        XCTAssertNil(one.quality.repeatSummary)
    }

    func testTooManyRejectedRepeatsFailsWithAMeasureAgainMessage() throws {
        let analyzer = RoomCorrectionMeasurementAnalyzer()
        let train = try RoomCorrectionSweepGenerator().makeProgram(settings: repeatSettings(rate: 8_000, repeats: 3))
        XCTAssertThrowsError(try analyzer.analyzeSingleChannel(rawCapture: trainCapture(train, corrupt: [0, 1, 2]), program: train)) {
            guard case .tooMuchNoise(_, let total)? = $0 as? RoomCorrectionMeasurementAnalysisError else {
                return XCTFail("unexpected error \($0)")
            }
            XCTAssertEqual(total, 3)
            XCTAssertTrue($0.localizedDescription.contains("measure again"))
        }
    }
}
