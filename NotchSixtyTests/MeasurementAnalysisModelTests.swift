import XCTest
@testable import NotchSixty

/// E24 S4b: the Analysis tab's model at the eight standard rates, against the C reference room
/// (known harmonic levels and per-band RT60). No view snapshots.
final class MeasurementAnalysisModelTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private static let levels: [Double] = [-30, -45, -60, -70]

    private func room(rate: Double, harmonics: [Double], irSeconds: Double = 0.3) -> n60_measure_room_params {
        var room = n60_measure_room_params()
        n60_measure_room_defaults(rate, &room)
        room.ir_seconds = irSeconds
        room.diffuse_level_db = -200
        room.latency_seconds = 0.02
        room.mode_frequencies_hz = (0, 0, 0, 0)
        room.harmonic_db = (harmonics[0], harmonics[1], harmonics[2], harmonics[3])
        return room
    }

    /// A raw capture of the production room sweep through the reference room.
    private func rawCapture(rate: Double, settings: RoomCorrectionSweepSettings) throws -> [Float] {
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        var params = room(rate: rate, harmonics: Self.levels)
        var total: UInt64 = 0
        XCTAssertEqual(n60_measure_room_capture_length(&params, UInt64(program.sweepSamples.count), &total), N60_MEASURE_OK)
        var heard = [Float](repeating: 0, count: Int(total))
        XCTAssertEqual(n60_measure_room_capture(
            &params, program.sweepSamples, UInt64(program.sweepSamples.count), &heard, total, &total), N60_MEASURE_OK)
        var raw = [Float](repeating: 0, count: program.captureFrameCount)
        for index in 0..<min(Int(total), program.sweepSamples.count + program.tailFrames) {
            raw[program.leadInFrames + index] = heard[index]
        }
        return raw
    }

    private func settings(rate: Double) -> RoomCorrectionSweepSettings {
        var s = RoomCorrectionSweepSettings(sampleRate: rate)
        s.startFrequencyHz = 20
        s.endFrequencyHz = min(20_000, 0.45 * rate)
        s.durationSeconds = 5
        s.levelDBFS = -6
        s.tailSeconds = 1
        return s
    }

    func testDistortionRecoversKnownHarmonicsAtEveryRate() throws {
        for rate in Self.rates {
            let s = settings(rate: rate)
            let source = MeasurementAnalysisSource(
                id: "t", kind: .library, title: "t", sampleRate: rate, impulseResponse: [1], arrivalSeconds: nil,
                rawCapture: try rawCapture(rate: rate, settings: s), sweep: s)
            guard case .result(let result) = MeasurementAnalysisModel.distortion(of: source) else {
                return XCTFail("no distortion at \(rate)")
            }
            XCTAssertTrue(result.cleanSeparation, "rate \(rate)")
            for k in 0..<4 {
                var checked = 0, worst = 0.0
                for (i, f) in result.frequencyHz.enumerated() where f >= 40 {
                    let v = result.harmonicDB[k][i]
                    if v == MeasurementCore.DistortionResult.noDataDB { continue }
                    worst = max(worst, abs(v - Self.levels[k]))
                    checked += 1
                }
                XCTAssertGreaterThan(checked, 20, "rate \(rate) H\(k + 2)")
                XCTAssertLessThan(worst, 1.0, "rate \(rate) H\(k + 2) error \(worst) dB")
            }
        }
    }

    func testDistortionNeedsRawCaptureAndSweep() {
        var source = MeasurementAnalysisSource(
            id: "t", kind: .speakerLab, title: "t", sampleRate: 48_000, impulseResponse: [1, 0],
            arrivalSeconds: nil, rawCapture: [], sweep: nil)
        guard case .unavailable(let reason) = MeasurementAnalysisModel.distortion(of: source) else { return XCTFail() }
        XCTAssertTrue(reason.contains("raw capture"))
        source.rawCapture = [0, 0, 0]
        guard case .unavailable(let reason2) = MeasurementAnalysisModel.distortion(of: source) else { return XCTFail() }
        XCTAssertTrue(reason2.contains("sweep settings"))
        source.sweep = RoomCorrectionSweepSettings(sampleRate: 48_000)
        guard case .unavailable(let reason3) = MeasurementAnalysisModel.distortion(of: source) else { return XCTFail() }
        XCTAssertTrue(reason3.contains("does not match"))
    }

    func testDecayRecoversReferenceRoomRT60AtEveryRate() throws {
        for rate in Self.rates {
            var params = n60_measure_room_params()
            n60_measure_room_defaults(rate, &params)
            params.ir_seconds = 1.2
            var length: UInt64 = 0
            XCTAssertEqual(n60_measure_room_ir_length(&params, &length), N60_MEASURE_OK)
            var ir = [Float](repeating: 0, count: Int(length))
            XCTAssertEqual(n60_measure_room_ir(&params, &ir, length, &length), N60_MEASURE_OK)
            let expected = params.rt60_seconds.3
            let source = MeasurementAnalysisSource(
                id: "t", kind: .library, title: "t", sampleRate: rate, impulseResponse: ir, arrivalSeconds: nil,
                rawCapture: [], sweep: nil)
            guard case .result(let octave, let third) = MeasurementAnalysisModel.decay(of: source) else {
                return XCTFail("no decay at \(rate)")
            }
            XCTAssertGreaterThan(third.count, octave.count)
            let mid = try XCTUnwrap(octave.first { abs($0.centreHz - 1_000) < 1 })
            XCTAssertEqual(mid.rt60Seconds, expected, accuracy: expected * 0.1, "rate \(rate)")
        }
    }

    func testSourcesResolveFromEachOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeasurementLibrary(root: root)
        let s = RoomCorrectionSweepSettings(sampleRate: 48_000)
        var record = MeasurementRecord(name: "kept", createdAt: Date(), sampleRate: 48_000)
        record.sweep = s
        let withRaw = try library.save(record, impulseResponse: [1, 0.5], rawCapture: [0, 1, 0])
        record.name = "no raw"
        record.id = UUID()
        let without = try library.save(record, impulseResponse: [1, 0.5])
        let a = try MeasurementAnalysisSource.library(withRaw, from: library)
        XCTAssertEqual(a.rawCapture, [0, 1, 0])
        XCTAssertEqual(a.sweep, s)
        let b = try MeasurementAnalysisSource.library(without, from: library)
        XCTAssertTrue(b.rawCapture.isEmpty)
        XCTAssertNotNil(b.distortionUnavailableReason)
        let curveOnly = MeasurementRecord(name: "curve", createdAt: Date(), sampleRate: 48_000, hasImpulseResponse: false)
        XCTAssertThrowsError(try MeasurementAnalysisSource.library(curveOnly, from: library))
    }
}
