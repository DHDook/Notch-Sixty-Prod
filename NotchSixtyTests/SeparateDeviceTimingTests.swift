import XCTest
@testable import NotchSixty

/// E24 S5b2: microphones on different devices share a time base through the front-left speaker's timing chirp.
/// Seats 1 and 2 are channels of device A; seat 3 is on device B, whose clock starts late and drifts.
@MainActor
final class SeparateDeviceTimingTests: XCTestCase {
    static var rates: [Double] { SystemSetupEndToEndTests.rates }
    private let offsetFrames = 37
    /// Residual drift after the aggregate's own compensation; the sweep's smear grows with it (see the epic's note 10).
    private let driftPPM = 3.0

    private func makeRig(rate: Double, separate: Bool) throws -> OfflineSetupRig {
        let rig = try OfflineSetupRig(rate: rate, secondMicrophone: true)
        try rig.installTwoPointOneProfile()
        rig.calibration.prepareForUse()
        while rig.calibration.seats.count < 3 { try rig.calibration.addSeat() }
        guard separate else { return rig }
        try rig.calibration.setSeatMicrophoneMode(.perSeat)
        let uids = [OfflineSetupRig.inputUID, OfflineSetupRig.inputUID, OfflineSetupRig.secondInputUID]
        for (index, seat) in rig.calibration.seats.enumerated() {
            try rig.calibration.setSeatMicrophone(seat.id, MultichannelSeatMicrophone(
                deviceUID: uids[index], channelIndex: index == 2 ? 0 : index, calibration: nil))
        }
        rig.transports.seatOfInput = { $0.device.uid == OfflineSetupRig.secondInputUID ? 2 : $0.channelIndex }
        rig.transports.deviceClock = [OfflineSetupRig.secondInputUID: (offsetFrames, driftPPM)]
        return rig
    }

    private func measurer(_ rig: OfflineSetupRig) -> CalibrationSeatMeasurer {
        let transports = rig.transports
        return CalibrationSeatMeasurer(calibration: rig.calibration, pollSeconds: 0.005, transport: { pass in
            { primary, additional in
                try transports.makeMultiMic(
                    program: pass.program, outputChannel: pass.physicalOutputChannel, primary: primary, additional: additional,
                    outputSweepSamples: pass.outputSweepSamples, referenceProgram: pass.referenceProgram)
            }
        })
    }

    private func channel(_ rig: OfflineSetupRig, seat: Int, source: Int) throws -> RoomCorrectionChannelMeasurement {
        let seatID = rig.calibration.seats[seat].id
        let sourceValue = rig.calibration.sources[source]
        return try XCTUnwrap(rig.calibration.measurements.first { $0.seatID == seatID && $0.source == sourceValue }).channel
    }

    private func smoothed(_ channel: RoomCorrectionChannelMeasurement, highHz: Double) throws -> [Double] {
        let response = try XCTUnwrap(channel.transferFunction)
        var out: [Double] = []
        var f = 20.0
        while f <= highHz {
            let lo = f / pow(2, 1.0 / 12), hi = f * pow(2, 1.0 / 12)
            var sum = 0.0, n = 0.0
            for (hz, db) in zip(response.frequenciesHz, response.magnitudeDB) where hz >= lo && hz <= hi { sum += db; n += 1 }
            if n > 0 { out.append(sum / n) }
            f *= pow(2, 1.0 / 6)
        }
        return out
    }

    private func arrival(_ rig: OfflineSetupRig, seat: Int, source: Int) throws -> Double {
        try XCTUnwrap(channel(rig, seat: seat, source: source).quality.directArrivalSeconds)
    }

    // MARK: Pure alignment

    func testAlignmentPutsEverySeatOnThePrimaryClock() throws {
        let rate = 48_000.0
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 100, endFrequencyHz: 10_000, durationSeconds: 0.5,
            levelDBFS: -12, leadInSeconds: 0.05, tailSeconds: 0.2, fadeSeconds: 0.01))
        let timing = try SeparateDeviceTiming(program: program)
        func capture(delay: Int) -> [Float] {
            var out = [Float](repeating: 0, count: timing.extendedFrameCount(of: program))
            for (i, v) in timing.chirp.enumerated() { out[timing.chirpStartFrame + delay + i] += v }
            out[program.leadInFrames + timing.extraFrames + delay + 100] = 0.5  // a "sweep" marker, 100 frames in
            return out
        }
        let aligned = try timing.align([capture(delay: 10), capture(delay: 10 + 25), capture(delay: 10 - 7)])
        XCTAssertEqual(aligned.shifts.map { $0.rounded() }, [0, 25, -7])
        for seat in aligned.captures {
            XCTAssertEqual(seat.count, program.captureFrameCount)
            XCTAssertEqual(seat.firstIndex { $0 == 0.5 }, program.leadInFrames + 100 + 10)
        }
    }

    func testSilenceAtOneSeatIsAWeakReference() throws {
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: RoomCorrectionSweepSettings(
            sampleRate: 48_000, startFrequencyHz: 100, endFrequencyHz: 10_000, durationSeconds: 0.5,
            levelDBFS: -12, leadInSeconds: 0.05, tailSeconds: 0.2, fadeSeconds: 0.01))
        let timing = try SeparateDeviceTiming(program: program)
        var heard = [Float](repeating: 0, count: timing.extendedFrameCount(of: program))
        for (i, v) in timing.chirp.enumerated() { heard[timing.chirpStartFrame + i] = v }
        var noise = [Float](repeating: 0, count: heard.count)
        var state: UInt32 = 7
        for i in noise.indices { state = state &* 1_664_525 &+ 1_013_904_223; noise[i] = (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.001 }
        XCTAssertThrowsError(try timing.align([heard, noise])) { XCTAssertEqual($0 as? MultiMicError, .weakReference(seat: 1)) }
    }

    // MARK: One pass against three sequential passes

    func testOnePassAcrossDevicesMatchesThreeSequentialPassesAtEveryRate() async throws {
        for rate in Self.rates {
            let label = "\(rate) Hz"
            let moved = try makeRig(rate: rate, separate: false)
            defer { moved.tearDown() }
            _ = try await measurer(moved).measureSeats([0, 1, 2], sampleRate: rate)

            let split = try makeRig(rate: rate, separate: true)
            defer { split.tearDown() }
            XCTAssertEqual(split.calibration.seatClockMode, .separateDevices, label)
            let records = try await measurer(split).measureSeats([0, 1, 2], sampleRate: rate)
            XCTAssertEqual(records.count, 3, label)
            XCTAssertEqual(split.transports.passCount, 3, "\(label): one pass per source")
            XCTAssertTrue(split.transports.passSweeps.allSatisfy(\.chirp), "\(label): every pass carries the chirp")
            // The front-left speaker is source 0: its own output carries the chirp; the others use the reference channel.
            XCTAssertEqual(split.transports.passSweeps.map(\.selfChirp), [true, false, false], label)

            // The test clock's fractional-delay interpolation rolls off near Nyquist, so compare below 0.35 of the rate.
            let high = min(20_000, 0.35 * rate)
            let frame = 1 / rate
            for seat in 0..<3 {
                for source in 0..<3 {
                    let a = try smoothed(channel(moved, seat: seat, source: source), highHz: high)
                    let b = try smoothed(channel(split, seat: seat, source: source), highHz: high)
                    XCTAssertEqual(a.count, b.count, label)
                    // Up to 5 kHz every 1/6-octave point matches; above it a deep notch moves with a sub-sample timing
                    // difference, so the whole band is held to a mean difference instead.
                    let diffs = zip(a, b).map { abs($0 - $1) }
                    let low = diffs.indices.filter { 20 * pow(2, Double($0) / 6) <= 5_000 }.map { diffs[$0] }.max() ?? 0
                    XCTAssertLessThan(low, 0.5, "\(label) seat \(seat) source \(source) below 5 kHz")
                    XCTAssertLessThan(diffs.reduce(0, +) / Double(max(diffs.count, 1)), 0.5, "\(label) seat \(seat) source \(source) mean")
                    XCTAssertTrue(try channel(split, seat: seat, source: source).quality.warnings
                        .contains(MultiMicMode.separateDevices.timingWarning), label)
                }
                // Within a seat, source-to-source arrival differences are those of the sequential passes.
                for source in 1..<3 {
                    let sequential = try arrival(moved, seat: seat, source: source) - arrival(moved, seat: seat, source: 0)
                    let one = try arrival(split, seat: seat, source: source) - arrival(split, seat: seat, source: 0)
                    XCTAssertLessThanOrEqual(abs(sequential - one), 1.5 * frame, "\(label) seat \(seat) source \(source)")
                }
            }
            // Across seats the reference speaker's flight-time difference is lost: the room's seats differ by the same
            // distance for every speaker, so each source arrives at the same time at every seat.
            for source in 0..<3 {
                let base = try arrival(split, seat: 0, source: source)
                for seat in 1..<3 {
                    XCTAssertLessThanOrEqual(abs(try arrival(split, seat: seat, source: source) - base), max(2 * frame, 12e-6),
                                             "\(label) seat \(seat) source \(source) offset")
                }
            }
        }
    }

    func testRepeatsAcrossDevicesKeepWithinSeatTiming() async throws {
        for rate in [48_000.0, 384_000.0] {
            let label = "\(rate) Hz"
            let moved = try makeRig(rate: rate, separate: false)
            defer { moved.tearDown() }
            moved.microphone.sweepRepeatCount = 3
            _ = try await measurer(moved).measureSeats([0, 1, 2], sampleRate: rate)
            let split = try makeRig(rate: rate, separate: true)
            defer { split.tearDown() }
            split.microphone.sweepRepeatCount = 3
            _ = try await measurer(split).measureSeats([0, 1, 2], sampleRate: rate)
            for seat in 0..<3 {
                for source in 1..<3 {
                    let sequential = try arrival(moved, seat: seat, source: source) - arrival(moved, seat: seat, source: 0)
                    let one = try arrival(split, seat: seat, source: source) - arrival(split, seat: seat, source: 0)
                    XCTAssertLessThanOrEqual(abs(sequential - one), 1.5 / rate, "\(label) seat \(seat) source \(source)")
                }
            }
        }
    }

    // MARK: Failure

    func testWeakChirpAtOneSeatFailsThePassAndStoresNothing() async throws {
        let rig = try makeRig(rate: 48_000, separate: true)
        defer { rig.tearDown() }
        rig.transports.configure = { $0.referenceGains = [1, 1, 0] }
        let name = rig.calibration.seats[2].name
        do {
            _ = try await measurer(rig).measureSeats([0, 1, 2], sampleRate: 48_000)
            XCTFail("expected a failure")
        } catch let error as SeatMeasurerError {
            XCTAssertEqual(error, .weakReference(name))
            XCTAssertTrue((error.errorDescription ?? "").contains(name))
        }
        // The front-left pass carries its chirp in its own output and was kept; the failed pass stored nothing.
        for seat in rig.calibration.seats { XCTAssertEqual(rig.calibration.missingSources(for: seat.id).count, 2) }
        XCTAssertFalse(rig.calibration.externalPassActive)
    }

    func testSameDeviceSeatsNeverPlayTheChirp() async throws {
        let rig = try makeRig(rate: 48_000, separate: true)
        defer { rig.tearDown() }
        _ = try await measurer(rig).measureSeats([0, 1], sampleRate: 48_000)
        XCTAssertFalse(rig.transports.passSweeps.contains(where: \.chirp))
    }

    // MARK: Wizard

    func testWizardMeasuresAcrossDevicesAt48kHz() async throws {
        let rig = try makeRig(rate: 48_000, separate: true)
        defer { rig.tearDown() }
        let model = rig.model
        model.begin()
        model.chooseOutput(uid: OfflineSetupRig.outputUID)
        model.next()
        model.chooseTopology(.twoPointOne)
        model.next()
        model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        model.acceptSweepLevel(measuredSPLdBC: 75)
        model.next()
        model.next()
        XCTAssertEqual(model.step, .measure, model.message ?? "")
        model.prepareMeasure()
        XCTAssertTrue(rig.calibration.readiness.isReady)
        await model.measureAll()
        XCTAssertNil(model.message)
        XCTAssertEqual(rig.transports.passCount, 3)
        XCTAssertEqual(model.choices.measurementIDs.count, 3)
        model.next()
        XCTAssertEqual(model.step, .alignment, model.message ?? "")
        await model.computeAlignment()
        XCTAssertNotNil(model.alignment, model.message ?? "")
    }
}
