import Foundation
import XCTest
@testable import NotchSixty

/// E11 S1: the portable measurement core behind the Swift analyser. The C++ maths is covered by
/// core/tests/test_measure*.cpp; these tests cover the Swift seam and flag-on/flag-off parity.
final class MeasurementCoreTests: XCTestCase {
    private func makePlan() throws -> RoomCorrectionMeasurementPlan {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: 48_000,
            startFrequencyHz: 20,
            endFrequencyHz: 20_000,
            durationSeconds: 0.5,
            levelDBFS: -12,
            leadInSeconds: 0.05,
            tailSeconds: 0.3,
            fadeSeconds: 0.01
        )
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        return try RoomCorrectionMeasurementPlan(program: program, settlingSeconds: 0.02)
    }

    private func makeCapture(program: RoomCorrectionSweepProgram, gain: Float, delayFrames: Int) -> [Float] {
        var result = [Float](repeating: 0, count: program.captureFrameCount)
        for index in program.sweepSamples.indices {
            let destination = program.leadInFrames + delayFrames + index
            guard destination < result.count else { break }
            result[destination] += gain * program.sweepSamples[index]
        }
        // Deterministic low-level noise so regularisation is exercised.
        var state: UInt32 = 0x1234_5678
        for index in result.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            result[index] += (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.000_02
        }
        return result
    }

    func testABIVersionAndFlagRegistration() {
        XCTAssertEqual(MeasurementCore.abiVersion, 2)
        XCTAssertTrue(FeatureFlag.all.contains(.measurementSuite))
        XCTAssertFalse(FeatureFlag.measurementSuite.defaultEnabled)
    }

    func testSynchronisedSweepHasIntegerCyclesAtStartFrequency() throws {
        let sweep = try MeasurementCore.makeSweep(
            sampleRate: 48_000, startFrequencyHz: 20, endFrequencyHz: 20_000,
            durationSeconds: 2, levelDBFS: -12, fadeSeconds: 0.01, synchronised: true
        )
        let cycles = 20.0 * sweep.info.sweepRateSeconds
        XCTAssertEqual(cycles, cycles.rounded(), accuracy: 1e-9)
        XCTAssertEqual(sweep.samples.count, sweep.info.frameCount)
        XCTAssertEqual(sweep.info.harmonicLeadSeconds(2), sweep.info.sweepRateSeconds * log(2.0), accuracy: 1e-12)
    }

    func testCoreRejectsAllZeroExcitation() {
        XCTAssertThrowsError(
            try MeasurementCore.deconvolve(
                excitation: [Float](repeating: 0, count: 64),
                observed: [Float](repeating: 0.1, count: 64),
                regularizationRatio: 1e-6
            )
        ) { error in
            XCTAssertEqual(error as? RoomCorrectionMeasurementAnalysisError, .unusableExcitation)
        }
    }

    func testCoreAndSwiftAnalysersAgreeWithinHundredthOfADecibel() throws {
        let plan = try makePlan()
        let raw = makeCapture(program: plan.program, gain: 0.5, delayFrames: 120)
        let capture = RoomCorrectionCalibrationCapture(left: raw, right: raw)
        let reference = try RoomCorrectionMeasurementAnalyzer().analyze(capture: capture, plan: plan)
        let core = try RoomCorrectionMeasurementAnalyzer(usesMeasurementCore: true)
            .analyze(capture: capture, plan: plan)

        let a = try XCTUnwrap(reference.left.transferFunction)
        let b = try XCTUnwrap(core.left.transferFunction)
        XCTAssertEqual(a.frequenciesHz, b.frequenciesHz)
        var checked = 0
        for index in a.frequenciesHz.indices where a.frequenciesHz[index] >= 20 && a.frequenciesHz[index] <= 20_000 {
            XCTAssertEqual(a.magnitudeDB[index], b.magnitudeDB[index], accuracy: 0.01,
                           "at \(a.frequenciesHz[index]) Hz")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(
            reference.left.quality.directArrivalSeconds ?? -1,
            core.left.quality.directArrivalSeconds ?? -2,
            accuracy: 1.0 / 48_000.0
        )
    }

    // MARK: - E11 S2 timing and averaging

    func testFindArrivalLocatesDelayedChirpToASubSample() throws {
        let rate = 48_000.0
        let chirp = try MeasurementCore.makeReferenceChirp(sampleRate: rate)
        var capture = [Float](repeating: 0, count: chirp.count + 6_000)
        let delay = 1_234
        for (i, v) in chirp.enumerated() { capture[delay + i] = 0.3 * v }
        let arrival = try MeasurementCore.findArrival(template: chirp, in: capture, sampleRate: rate)
        XCTAssertEqual(arrival.frames, Double(delay), accuracy: 0.01)
    }

    func testFindArrivalRejectsAWeakReference() throws {
        let chirp = try MeasurementCore.makeReferenceChirp(sampleRate: 48_000)
        let silence = [Float](repeating: 0, count: chirp.count + 2_000)
        XCTAssertThrowsError(try MeasurementCore.findArrival(template: chirp, in: silence, sampleRate: 48_000)) {
            XCTAssertEqual($0 as? MeasurementTimingError, .weakReference)
        }
    }

    func testAverageRepeatsAlignsAndRejectsAnOutlier() throws {
        let rate = 48_000.0
        let chirp = try MeasurementCore.makeReferenceChirp(sampleRate: rate)
        let length = chirp.count + 4_000
        var repeats: [[Float]] = []
        var arrivals: [Double] = []
        for (r, delay) in [300, 307, 292, 301].enumerated() {
            var pass = [Float](repeating: 0, count: length)
            let gain: Float = r == 3 ? 4.0 : 1.0 // repeat 3 is far louder: a level outlier
            for (i, v) in chirp.enumerated() { pass[delay + i] = gain * v }
            repeats.append(pass)
            arrivals.append(Double(delay))
        }
        let result = try MeasurementCore.averageRepeats(
            repeats, arrivals: arrivals, sampleRate: rate, repeatPeriodFrames: length
        )
        XCTAssertEqual(result.rejectedRepeats, [3])
        XCTAssertEqual(result.acceptedCount, 3)
        XCTAssertEqual(result.samples.count, length)
        // Aligned to repeat 0: the chirp starts at frame 300 with unit gain.
        XCTAssertEqual(result.samples[300 + 100], chirp[100], accuracy: 1e-3)
    }

    func testAverageRepeatsRejectsMismatchedInput() {
        XCTAssertThrowsError(try MeasurementCore.averageRepeats(
            [[0, 1], [0, 1, 2]], arrivals: [0, 0], sampleRate: 48_000, repeatPeriodFrames: 2
        )) { XCTAssertEqual($0 as? MeasurementTimingError, .invalidArguments) }
    }

    func testAverageRepeatsReportsDriftAcrossRepeats() throws {
        let rate = 48_000.0
        let chirp = try MeasurementCore.makeReferenceChirp(sampleRate: rate)
        let length = chirp.count + 4_000
        for ppm in [50.0, -50.0] {
            var repeats: [[Float]] = []
            var arrivals: [Double] = []
            for r in 0..<4 {
                // Whole-sample positions cannot carry a few ppm exactly, so scale the period instead:
                // arrival r sits r * period * ppm * 1e-6 frames from repeat 0 (rounded to a sample).
                let shift = Int((Double(r) * Double(length) * ppm * 1e-6).rounded())
                var pass = [Float](repeating: 0, count: length)
                for (i, v) in chirp.enumerated() { pass[300 + shift + i] = v }
                repeats.append(pass)
                arrivals.append(Double(300 + shift))
            }
            let result = try MeasurementCore.averageRepeats(
                repeats, arrivals: arrivals, sampleRate: rate, repeatPeriodFrames: length
            )
            XCTAssertTrue(result.driftWarning, "\(ppm) ppm should warn")
            XCTAssertEqual(result.driftPPM, ppm, accuracy: 10, "reported drift for \(ppm) ppm")
            XCTAssertEqual(result.acceptedCount, 4)
            let found = try MeasurementCore.findArrival(template: chirp, in: result.samples, sampleRate: rate)
            XCTAssertEqual(found.frames, 300, accuracy: 0.05, "aligned to repeat 0 at \(ppm) ppm")
        }
    }

    func testDecayAnalysisRecoversReferenceRoomRT60() throws {
        var room = n60_measure_room_params()
        n60_measure_room_defaults(48_000, &room)
        room.ir_seconds = 1.2
        var length: UInt64 = 0
        XCTAssertEqual(n60_measure_room_ir_length(&room, &length), N60_MEASURE_OK)
        var ir = [Float](repeating: 0, count: Int(length))
        XCTAssertEqual(n60_measure_room_ir(&room, &ir, length, &length), N60_MEASURE_OK)
        let bands = try MeasurementCore.analyzeDecay(
            impulseResponse: ir, sampleRate: 48_000, bandsPerOctave: 1, minCentreHz: 250, maxCentreHz: 4_000)
        XCTAssertEqual(bands.count, 5)
        let mid = try XCTUnwrap(bands.first { abs($0.centreHz - 1_000) < 1 })
        let expected = withUnsafeBytes(of: room.rt60_seconds) { Array($0.bindMemory(to: Double.self))[3] }
        XCTAssertEqual(mid.rt60Seconds, expected, accuracy: expected * 0.1)
        XCTAssertEqual(mid.flags, 0)
    }

    func testDecayAnalysisRejectsBadArguments() {
        XCTAssertThrowsError(try MeasurementCore.analyzeDecay(impulseResponse: [], sampleRate: 48_000))
        XCTAssertThrowsError(try MeasurementCore.analyzeDistortion(
            response: [], sampleRate: 48_000,
            sweep: .init(frameCount: 0, sweepRateSeconds: 1, durationSeconds: 1),
            startFrequencyHz: 20, endFrequencyHz: 20_000))
    }
}
