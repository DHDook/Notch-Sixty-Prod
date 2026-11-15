import Foundation
import XCTest
@testable import NotchSixty

/// E21 S5: the core maths (`n60/measure.h`) against the Swift and vDSP path it replaces, at the eight standard rates
/// (design note 9d: responses within -100 dB relative error).
final class CoreMeasurementParityTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func plan(sampleRate: Double) throws -> RoomCorrectionMeasurementPlan {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: sampleRate, startFrequencyHz: 40, endFrequencyHz: 18_000, durationSeconds: 0.4,
            levelDBFS: -12, leadInSeconds: 0.05, tailSeconds: 0.25, fadeSeconds: 0.01)
        return try RoomCorrectionMeasurementPlan(
            program: try RoomCorrectionSweepGenerator().makeProgram(settings: settings), settlingSeconds: 0.01)
    }

    /// Delayed, half-gain direct sound plus one later reflection and a deterministic noise floor.
    private func capture(_ program: RoomCorrectionSweepProgram) -> [Float] {
        var result = [Float](repeating: 0, count: program.captureFrameCount)
        var state: UInt32 = 0x1234_5678
        for index in result.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            result[index] = (Float(state >> 8) / Float(1 << 24) - 0.5) * 2e-5
        }
        let delay = Int(program.sampleRate * 0.0071)
        let echo = delay + Int(program.sampleRate * 0.0043)
        for index in program.sweepSamples.indices {
            let direct = program.leadInFrames + delay + index
            if direct < result.count { result[direct] += 0.5 * program.sweepSamples[index] }
            let reflected = program.leadInFrames + echo + index
            if reflected < result.count { result[reflected] += 0.2 * program.sweepSamples[index] }
        }
        return result
    }

    func testRoomResponseMatchesTheSwiftPathAtEveryStandardRate() throws {
        for rate in Self.rates {
            let plan = try plan(sampleRate: rate)
            let raw = capture(plan.program)
            var swiftPath = RoomCorrectionMeasurementAnalyzer()
            swiftPath.useCoreMaths = false
            var corePath = RoomCorrectionMeasurementAnalyzer()
            corePath.useCoreMaths = true
            let expected = try swiftPath.analyzeSingleChannel(rawCapture: raw, program: plan.program)
            let actual = try corePath.analyzeSingleChannel(rawCapture: raw, program: plan.program)

            XCTAssertEqual(actual.quality.directArrivalSeconds, expected.quality.directArrivalSeconds, "rate \(rate)")
            XCTAssertEqual(actual.impulseResponse, expected.impulseResponse, "rate \(rate)")
            let a = try XCTUnwrap(actual.transferFunction)
            let e = try XCTUnwrap(expected.transferFunction)
            XCTAssertEqual(a.frequenciesHz.count, e.frequenciesHz.count)
            let peak = e.magnitudeDB.map { pow(10, $0 / 20) }.max() ?? 1
            for index in e.frequenciesHz.indices {
                XCTAssertEqual(a.frequenciesHz[index], e.frequenciesHz[index], accuracy: 1e-9)
                let linearA = pow(10, a.magnitudeDB[index] / 20)
                let linearE = pow(10, e.magnitudeDB[index] / 20)
                XCTAssertLessThan(abs(linearA - linearE) / peak, 1e-5, "rate \(rate) point \(index) magnitude")
                if linearE > peak * 0.01 {
                    XCTAssertEqual(a.phaseRadians![index], e.phaseRadians![index], accuracy: 1e-3,
                                   "rate \(rate) point \(index) phase")
                }
            }
        }
    }

    func testCalibrationIsAppliedIdenticallyOnTheCorePath() throws {
        let plan = try plan(sampleRate: 48_000)
        let raw = capture(plan.program)
        let calibration = RoomCorrectionMicrophoneCalibration(
            sourceName: "parity",
            points: [
                RoomCorrectionCalibrationPoint(frequencyHz: 40, gainDB: -2),
                RoomCorrectionCalibrationPoint(frequencyHz: 1_000, gainDB: 3),
                RoomCorrectionCalibrationPoint(frequencyHz: 18_000, gainDB: 1),
            ])
        var swiftPath = RoomCorrectionMeasurementAnalyzer()
        swiftPath.useCoreMaths = false
        var corePath = RoomCorrectionMeasurementAnalyzer()
        corePath.useCoreMaths = true
        let e = try swiftPath.analyzeSingleChannel(rawCapture: raw, program: plan.program, microphoneCalibration: calibration)
        let a = try corePath.analyzeSingleChannel(rawCapture: raw, program: plan.program, microphoneCalibration: calibration)
        for index in e.transferFunction!.magnitudeDB.indices {
            XCTAssertEqual(a.transferFunction!.magnitudeDB[index], e.transferFunction!.magnitudeDB[index], accuracy: 0.01)
        }
    }

    func testSilentCaptureStillFailsOnTheCorePath() throws {
        let plan = try plan(sampleRate: 48_000)
        let raw = [Float](repeating: 0, count: plan.program.captureFrameCount)
        var corePath = RoomCorrectionMeasurementAnalyzer()
        corePath.useCoreMaths = true
        XCTAssertThrowsError(try corePath.analyzeSingleChannel(rawCapture: raw, program: plan.program))
    }

    func testProgramSpectrumBandsMatchTheVDSPPathAtEveryStandardRate() {
        for rate in Self.rates {
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            var inL = [Float](repeating: 0, count: size), inR = inL, outL = inL, outR = inL
            var state: UInt32 = 99
            for i in 0..<size {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.01
                let t = Double(i) / rate
                inL[i] = Float(0.4 * sin(2 * .pi * 997 * t)) + noise
                inR[i] = Float(0.2 * sin(2 * .pi * 4_001 * t)) - noise
                outL[i] = inL[i] * 0.5
                outR[i] = inR[i] * 0.25
            }
            let swiftPath = ProductionSpectrumAnalyzer()
            swiftPath.useCoreMaths = false
            let corePath = ProductionSpectrumAnalyzer()
            corePath.useCoreMaths = true
            let expected = swiftPath.analyze(inputLeft: inL, inputRight: inR, outputLeft: outL, outputRight: outR,
                                             count: size, sampleRate: rate)
            let actual = corePath.analyze(inputLeft: inL, inputRight: inR, outputLeft: outL, outputRight: outR,
                                          count: size, sampleRate: rate)
            XCTAssertEqual(actual.count, 288)
            XCTAssertEqual(actual.count, expected.count)
            for index in expected.indices {
                XCTAssertEqual(actual[index].frequencyHz, expected[index].frequencyHz, accuracy: 1e-6)
                XCTAssertEqual(actual[index].inputDB, expected[index].inputDB, accuracy: 0.02, "rate \(rate) band \(index)")
                XCTAssertEqual(actual[index].outputDB, expected[index].outputDB, accuracy: 0.02, "rate \(rate) band \(index)")
            }
        }
    }

    func testFlagIsOffByDefaultAndKnown() {
        XCTAssertTrue(FeatureFlag.all.contains(.coreDesigners))
        XCTAssertFalse(FeatureFlag.coreDesigners.resolvedDefault)
    }
}
