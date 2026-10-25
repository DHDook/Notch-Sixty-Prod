import CoreAudio
import Foundation
import XCTest
@testable import NotchSixty

/// E11 S8: the Swift seam over the core's monitor ring, SPL meter and RTA, the IOProc that feeds the ring, and
/// the CSV logger. The weighting, time-constant, band and ring maths are covered by core/tests/test_measure_monitor.cpp.
final class MeasurementLiveAnalysisTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func sine(rate: Double, hz: Double, peak: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(peak * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    func testPipelineCalibratesMeterAndSpectrumTogether() throws {
        for rate in Self.rates {
            let ring = try MonitorSampleRing(capacityFrames: 1 << 20)
            let pipeline = try MeasurementMonitorPipeline(
                ring: ring, sampleRate: rate, weighting: .a, rta: RTASettings(bandsPerOctave: 3, averaging: .infinite), calibrationOffsetDB: 0)
            let tone = sine(rate: rate, hz: 1000, peak: 0.1 * 2.0.squareRoot(), seconds: 1.5)
            XCTAssertEqual(ring.push(tone), tone.count)
            XCTAssertEqual(pipeline.drain(), tone.count)
            XCTAssertEqual(try XCTUnwrap(pipeline.calibrate(toReferenceSPL: 94)), 94 + 20, accuracy: 0.1, "rate \(rate)")
            let reading = pipeline.meter.read()
            XCTAssertEqual(reading.leqDB, 94, accuracy: 1e-6)
            // The 1 kHz third-octave band holds the tone, so the calibrated RTA agrees with the meter.
            let spectrum = pipeline.rta.read()
            let index = try XCTUnwrap(spectrum.centresHz.firstIndex { abs($0 - 1000) < 20 })
            XCTAssertEqual(spectrum.levelsDB[index], 94, accuracy: 0.5, "rate \(rate)")
        }
    }

    func testRingOverrunIsCountedAndNeverBlocks() throws {
        let ring = try MonitorSampleRing(capacityFrames: 1 << 12)
        XCTAssertEqual(ring.push([Float](repeating: 0.1, count: 5000)), 4096)
        XCTAssertEqual(ring.overrunFrames, 904)
        XCTAssertEqual(ring.pop(maximum: 10_000).count, 4096)
        ring.reset()
        XCTAssertEqual(ring.overrunFrames, 0)
    }

    func testWeightingResponseIsZeroAtOneKilohertz() throws {
        for rate in Self.rates {
            for w in [SPLWeighting.a, .c] {
                let db = try XCTUnwrap(SPLMeterCore.weightingResponseDB(sampleRate: rate, weighting: w, frequencyHz: 1000))
                XCTAssertEqual(db, 0, accuracy: 1e-6)
            }
            let a100 = try XCTUnwrap(SPLMeterCore.weightingResponseDB(sampleRate: rate, weighting: .a, frequencyHz: 100))
            XCTAssertEqual(a100, -19.1, accuracy: 0.3, "A at 100 Hz, rate \(rate)")
        }
    }

    func testIOProcCopiesTheChosenChannelWithoutBlocking() throws {
        let ring = try MonitorSampleRing(capacityFrames: 1 << 12)
        let context = try XCTUnwrap(N60MeasurementMonitorContextCreate(ring.handle, 1))
        defer { N60MeasurementMonitorContextDestroy(context) }
        // Two interleaved channels: left counts up, right is the microphone and carries a ramp.
        var frames = [Float](repeating: 0, count: 2 * 480)
        var stamp = AudioTimeStamp()
        var out = AudioBufferList()
        for i in 0..<480 { frames[2 * i] = 9; frames[2 * i + 1] = Float(i) / 480 }
        frames.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            let status = N60MeasurementMonitorIOProc(0, &stamp, &list, &stamp, &out, &stamp, UnsafeMutableRawPointer(context))
            XCTAssertEqual(status, noErr)
        }
        let got = ring.pop(maximum: 1000)
        XCTAssertEqual(got.count, 480)
        XCTAssertEqual(got[100], 100.0 / 480, accuracy: 1e-7)
        // A channel the device does not have is counted, not copied.
        let missing = try XCTUnwrap(N60MeasurementMonitorContextCreate(ring.handle, 5))
        defer { N60MeasurementMonitorContextDestroy(missing) }
        frames.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            _ = N60MeasurementMonitorIOProc(0, &stamp, &list, &stamp, &out, &stamp, UnsafeMutableRawPointer(missing))
        }
        var callbacks: UInt64 = 0, unsupported: UInt64 = 0
        N60MeasurementMonitorContextCounters(missing, &callbacks, &unsupported)
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(unsupported, 1)
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testLevelLogLabelsUncalibratedReadingsAsRelative() throws {
        var log = MeasurementLevelLog(calibrated: false, weighting: .a)
        log.append(seconds: 1, reading: SPLReading(fastDB: -20.04, slowDB: -20.5, leqDB: -21, cPeakDB: -10, elapsedSeconds: 1))
        let lines = log.csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("dB (relative)"))
        XCTAssertFalse(lines[0].contains("SPL"))
        XCTAssertEqual(lines[1], "1.000,-20.04,-20.50,-21.00,-10.00")

        var calibrated = MeasurementLevelLog(calibrated: true, weighting: .c)
        calibrated.append(seconds: 2, reading: SPLReading(fastDB: 70, slowDB: 70, leqDB: 70, cPeakDB: 80, elapsedSeconds: 2))
        XCTAssertTrue(calibrated.csv.contains("LCF (dB SPL)"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n60-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try calibrated.write(named: "a/b", in: dir)
        XCTAssertEqual(url.lastPathComponent, "a-b.csv")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), calibrated.csv)
    }

    func testMonitorRingSizeFollowsSampleRate() {
        XCTAssertEqual(MeasurementInputMonitor.ringFrames(sampleRate: 48_000), 1 << 17)
        XCTAssertEqual(MeasurementInputMonitor.ringFrames(sampleRate: 384_000), 1 << 20)
    }
}
