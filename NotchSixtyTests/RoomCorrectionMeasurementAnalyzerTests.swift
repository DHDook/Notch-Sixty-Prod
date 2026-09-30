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
}
