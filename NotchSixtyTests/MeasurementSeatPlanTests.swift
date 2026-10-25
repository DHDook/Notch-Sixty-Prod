import XCTest
@testable import NotchSixty

/// E11 S9b: seat plan rules and the multi-mic runner around a fake K-input transport.
final class MeasurementSeatPlanTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func device(_ id: UInt32, _ name: String) -> AudioInputDevice {
        AudioInputDevice(
            deviceID: id, uid: "uid-\(id)", name: name, nominalSampleRate: 48_000, availableSampleRateRanges: []
        )
    }

    private final class FakeTransport: MultichannelCalibrationTransporting {
        var capture: MultichannelCalibrationCapture
        var completes: Bool
        private(set) var started = false
        private(set) var cancelled = false
        init(capture: MultichannelCalibrationCapture, completes: Bool = true) {
            self.capture = capture
            self.completes = completes
        }
        func start() throws { started = true }
        func snapshot() -> N60TargetedRoomMeasurementBridgeSnapshot? {
            var s = N60TargetedRoomMeasurementBridgeSnapshot()
            s.complete = completes
            return s
        }
        func finishAndMaterialize() throws -> MultichannelCalibrationCapture { capture }
        func cancel() { cancelled = true }
    }

    func testPlanRulesAndMode() throws {
        let usb1 = device(1, "USB A"), usb2 = device(2, "USB B")
        var plan = MeasurementSeatPlan()
        XCTAssertTrue(plan.isEmpty)
        try plan.add(MeasurementSeat(device: usb1, channelIndex: 0))
        try plan.add(MeasurementSeat(device: usb1, channelIndex: 1))
        XCTAssertEqual(plan.mode, .sharedClock)
        XCTAssertFalse(plan.requiresTimingChirp)
        XCTAssertThrowsError(try plan.add(MeasurementSeat(device: usb1, channelIndex: 1))) {
            XCTAssertEqual($0 as? MeasurementSeatPlanError, .duplicateSeat)
        }
        XCTAssertThrowsError(try plan.add(MeasurementSeat(device: usb1, channelIndex: -1)))
        try plan.add(MeasurementSeat(device: usb2, channelIndex: 0))
        XCTAssertEqual(plan.mode, .separateDevices)
        XCTAssertTrue(plan.requiresTimingChirp)
        XCTAssertTrue(plan.mode.isLessPrecise)
        XCTAssertEqual(plan.primary?.device.deviceID, 1)
        XCTAssertEqual(plan.additional.map(\.channelIndex), [1, 0])
        XCTAssertEqual(plan.multiMicSeats.map(\.id), [0, 1, 2])
        plan.remove(id: plan.seats[2].id)
        XCTAssertEqual(plan.mode, .sharedClock)
    }

    func testSixteenSeatsMaximum() throws {
        var plan = MeasurementSeatPlan()
        let d = device(1, "Interface")
        for ch in 0..<16 { try plan.add(MeasurementSeat(device: d, channelIndex: ch)) }
        XCTAssertThrowsError(try plan.add(MeasurementSeat(device: d, channelIndex: 16))) {
            XCTAssertEqual($0 as? MeasurementSeatPlanError, .tooManySeats)
        }
    }

    private func rig(rate: Double, delays: [Int]) throws -> (MultiMicPass, [[Float]]) {
        let sweep = try MeasurementCore.makeSweep(
            sampleRate: rate, startFrequencyHz: 100, endFrequencyHz: min(20_000, 0.4 * rate),
            durationSeconds: 0.3, levelDBFS: -12, fadeSeconds: 0.01, synchronised: true
        ).samples
        let start = Int(0.1 * rate)
        let total = start + sweep.count + Int(0.3 * rate)
        let captures = delays.map { delay -> [Float] in
            var c = [Float](repeating: 0, count: total)
            for (i, v) in sweep.enumerated() { c[start + delay + i] = v }
            return c
        }
        return (MultiMicPass(sweep: sweep, sweepStartFrame: start, referenceChirp: nil, chirpStartFrame: 0), captures)
    }

    func testRunnerGivesOneRecordPerSeatAtEveryRate() async throws {
        let delays = [2, 9, 21, 40]
        var plan = MeasurementSeatPlan()
        for ch in 0..<4 { try plan.add(MeasurementSeat(device: device(1, "Interface"), channelIndex: ch)) }
        for rate in Self.rates {
            let (pass, captures) = try rig(rate: rate, delays: delays)
            var delivered: (MultichannelSeatInput, [MultichannelSeatInput])?
            let fake = FakeTransport(capture: MultichannelCalibrationCapture(
                samples: captures[0], referenceSamples: nil, seatSamples: Array(captures.dropFirst())))
            let records = try await MultiMicMeasurementRunner.run(
                plan: plan, pass: pass, sampleRate: rate, timeoutSeconds: 2
            ) { primary, additional in
                delivered = (primary, additional)
                return fake
            }
            XCTAssertTrue(fake.started)
            XCTAssertEqual(delivered?.0.channelIndex, 0)
            XCTAssertEqual(delivered?.1.map(\.channelIndex), [1, 2, 3])
            XCTAssertEqual(records.count, 4)
            for (k, record) in records.enumerated() {
                let expected = Double(delays[k] - delays[0]) / rate
                XCTAssertEqual(record.delaySeconds, expected, accuracy: 10e-6, "seat \(k) at \(rate)")
                XCTAssertEqual(record.timingTier, .none)
            }
        }
    }

    func testMissingSeatFailsThePass() async throws {
        var plan = MeasurementSeatPlan()
        for ch in 0..<3 { try plan.add(MeasurementSeat(device: device(1, "Interface"), channelIndex: ch)) }
        let (pass, captures) = try rig(rate: 48_000, delays: [0, 5, 9])
        let fake = FakeTransport(capture: MultichannelCalibrationCapture(
            samples: captures[0], seatSamples: [captures[1]]))
        do {
            _ = try await MultiMicMeasurementRunner.run(plan: plan, pass: pass, sampleRate: 48_000, timeoutSeconds: 1) { _, _ in fake }
            XCTFail("expected a missing mic")
        } catch {
            XCTAssertEqual(error as? MultiMicError, .missingMic(seat: 2))
        }
        // A silent seat is also missing.
        let silent = FakeTransport(capture: MultichannelCalibrationCapture(
            samples: captures[0], seatSamples: [captures[1], [Float](repeating: 0, count: captures[1].count)]))
        do {
            _ = try await MultiMicMeasurementRunner.run(plan: plan, pass: pass, sampleRate: 48_000, timeoutSeconds: 1) { _, _ in silent }
            XCTFail("expected a missing mic")
        } catch {
            XCTAssertEqual(error as? MultiMicError, .missingMic(seat: 2))
        }
    }

    func testTimeoutAndEmptyPlanCancelOrRefuse() async throws {
        var plan = MeasurementSeatPlan()
        let (pass, captures) = try rig(rate: 48_000, delays: [0])
        do {
            _ = try await MultiMicMeasurementRunner.run(plan: plan, pass: pass, sampleRate: 48_000, timeoutSeconds: 1) { _, _ in
                FakeTransport(capture: MultichannelCalibrationCapture(samples: captures[0]))
            }
            XCTFail("empty plan")
        } catch { XCTAssertEqual(error as? MultiMicRunError, .emptyPlan) }
        try plan.add(MeasurementSeat(device: device(1, "Interface"), channelIndex: 0))
        let stuck = FakeTransport(capture: MultichannelCalibrationCapture(samples: captures[0]), completes: false)
        do {
            _ = try await MultiMicMeasurementRunner.run(
                plan: plan, pass: pass, sampleRate: 48_000, timeoutSeconds: 0.1, pollSeconds: 0.01
            ) { _, _ in stuck }
            XCTFail("timeout")
        } catch { XCTAssertEqual(error as? MultiMicRunError, .timedOut) }
        XCTAssertTrue(stuck.cancelled)
    }
}
