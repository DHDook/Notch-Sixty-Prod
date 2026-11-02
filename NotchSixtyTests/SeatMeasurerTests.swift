import XCTest
@testable import NotchSixty

/// E24 S5b1: the K-microphone pass and the production seat measurer, against the synthetic 2.1 reference room.
@MainActor
final class SeatMeasurerTests: XCTestCase {
    static var rates: [Double] { SystemSetupEndToEndTests.rates }

    // MARK: Helpers

    private func inputDevice() -> AudioInputDevice {
        AudioInputDevice(
            deviceID: 9_002, uid: OfflineSetupRig.inputUID, name: "Reference Measurement Mic", nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
    }

    /// A rig with three seats, each with its own channel of the reference interface when `perSeat`.
    private func makeRig(rate: Double, perSeat: Bool, calibrations: [Int: RoomCorrectionMicrophoneCalibration] = [:]) throws -> OfflineSetupRig {
        let rig = try OfflineSetupRig(rate: rate)
        try rig.installTwoPointOneProfile()
        rig.calibration.prepareForUse()
        while rig.calibration.seats.count < 3 { try rig.calibration.addSeat() }
        if perSeat {
            try rig.calibration.setSeatMicrophoneMode(.perSeat)
            for (index, seat) in rig.calibration.seats.enumerated() {
                try rig.calibration.setSeatMicrophone(seat.id, MultichannelSeatMicrophone(
                    deviceUID: OfflineSetupRig.inputUID, channelIndex: index, calibration: calibrations[index]))
            }
        }
        return rig
    }

    private func measurer(_ rig: OfflineSetupRig) -> CalibrationSeatMeasurer {
        let transports = rig.transports
        return CalibrationSeatMeasurer(calibration: rig.calibration, pollSeconds: 0.005, transport: { pass in
            { primary, additional in
                try transports.makeMultiMic(
                    program: pass.program, outputChannel: pass.physicalOutputChannel, primary: primary, additional: additional)
            }
        })
    }

    private func channel(_ rig: OfflineSetupRig, seat: Int, source: Int) throws -> RoomCorrectionChannelMeasurement {
        let seatID = rig.calibration.seats[seat].id
        let sourceValue = rig.calibration.sources[source]
        return try XCTUnwrap(rig.calibration.measurements.first { $0.seatID == seatID && $0.source == sourceValue }).channel
    }

    /// 1/6-octave smoothed magnitude (dB) of a channel on a log grid from 20 Hz to `highHz`.
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

    // MARK: Shared clock

    func testOnePassMatchesThreeSequentialPassesAtEveryRate() async throws {
        for rate in Self.rates {
            let label = "\(rate) Hz"
            let moved = try makeRig(rate: rate, perSeat: false)
            defer { moved.tearDown() }
            _ = try await measurer(moved).measureSeats([0, 1, 2], sampleRate: rate)
            XCTAssertEqual(moved.transports.made, 9, label)

            let shared = try makeRig(rate: rate, perSeat: true)
            defer { shared.tearDown() }
            let records = try await measurer(shared).measureSeats([0, 1, 2], sampleRate: rate)
            XCTAssertEqual(records.count, 3, label)
            XCTAssertEqual(shared.transports.passCount, 3, "\(label): one pass per source")
            XCTAssertEqual(shared.transports.passes.first?.additional.count, 2, label)

            let high = min(20_000, 0.45 * rate)
            for seat in 0..<3 {
                for source in 0..<3 {
                    let a = try channel(moved, seat: seat, source: source)
                    let b = try channel(shared, seat: seat, source: source)
                    let sa = try smoothed(a, highHz: high), sb = try smoothed(b, highHz: high)
                    XCTAssertEqual(sa.count, sb.count, label)
                    let worst = zip(sa, sb).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThan(worst, 0.5, "\(label) seat \(seat) source \(source)")
                    let da = try XCTUnwrap(a.quality.directArrivalSeconds), db = try XCTUnwrap(b.quality.directArrivalSeconds)
                    XCTAssertLessThanOrEqual(abs(da - db), 1 / rate + 1e-9, "\(label) seat \(seat) source \(source) arrival")
                }
            }
        }
    }

    func testBurstInOneRepeatAtOneSeatRejectsOnlyThere() async throws {
        for rate in [48_000.0, 384_000.0] {
            let label = "\(rate) Hz"
            let rig = try makeRig(rate: rate, perSeat: true)
            defer { rig.tearDown() }
            rig.microphone.sweepRepeatCount = 3
            // The middle third of the capture is the second repeat; corrupt part of it at seat 2 (index 1) only.
            rig.transports.configure = { transport in
                let total = Int(rate * (0.05 + 1.5 + 0.25) * 3)
                transport.bursts = [(seat: 1, frames: (total / 2 - 4_000)..<(total / 2 + 4_000), amplitude: 0.5)]
            }
            _ = try await measurer(rig).measureSeats([0, 1, 2], sampleRate: rate)
            for source in 0..<3 {
                let kept = try (0..<3).map { try channel(rig, seat: $0, source: source).quality.rejectedRepeats?.count ?? 0 }
                XCTAssertEqual(kept[1], 1, "\(label) source \(source): seat 2 loses one of three")
                XCTAssertEqual(kept[0], 0, label)
                XCTAssertEqual(kept[2], 0, label)
                let arrivals = try (0..<3).map { try XCTUnwrap(channel(rig, seat: $0, source: source).quality.directArrivalSeconds) }
                let reference = SyntheticReferenceRoom(rate: rate, seatCount: 3, sourcesPerSeat: 3)
                _ = reference
                XCTAssertTrue(arrivals.allSatisfy { $0 > 0 }, label)
            }
        }
    }

    // MARK: Failure and cancellation

    func testSilentSeatFailsTheWholePassNamesTheSeatAndStoresNothing() async throws {
        let rig = try makeRig(rate: 48_000, perSeat: true)
        defer { rig.tearDown() }
        rig.transports.configure = { $0.silentSeats = [1] }
        let name = rig.calibration.seats[1].name
        do {
            _ = try await measurer(rig).measureSeats([0, 1, 2], sampleRate: 48_000)
            XCTFail("expected a failure")
        } catch let error as SeatMeasurerError {
            XCTAssertEqual(error, .silentSeat(name))
            XCTAssertTrue((error.errorDescription ?? "").contains(name))
        }
        XCTAssertTrue(rig.calibration.measurements.isEmpty)
        XCTAssertFalse(rig.calibration.externalPassActive)
    }

    func testCancellingStoresNothingAndRestoresState() async throws {
        let rig = try makeRig(rate: 48_000, perSeat: true)
        defer { rig.tearDown() }
        let m = measurer(rig)
        let task = Task { @MainActor in try await m.measureSeats([0, 1, 2], sampleRate: 48_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(rig.calibration.measurements.isEmpty)
        XCTAssertFalse(rig.calibration.externalPassActive)
        XCTAssertTrue(rig.calibration.canMeasure)
    }

    // MARK: Per-seat calibration and a single seat

    func testCalibrationOnOneSeatChangesOnlyThatSeat() async throws {
        let rate = 48_000.0
        let flat = RoomCorrectionMicrophoneCalibration(
            sourceName: "flat", points: [.init(frequencyHz: 20, gainDB: 6), .init(frequencyHz: 20_000, gainDB: 6)])
        let plain = try makeRig(rate: rate, perSeat: true)
        defer { plain.tearDown() }
        _ = try await measurer(plain).measureSeats([0, 1, 2], sampleRate: rate)
        let calibrated = try makeRig(rate: rate, perSeat: true, calibrations: [1: flat])
        defer { calibrated.tearDown() }
        _ = try await measurer(calibrated).measureSeats([0, 1, 2], sampleRate: rate)
        for seat in 0..<3 {
            let a = try smoothed(channel(plain, seat: seat, source: 0), highHz: 10_000)
            let b = try smoothed(channel(calibrated, seat: seat, source: 0), highHz: 10_000)
            let delta = zip(a, b).map { $1 - $0 }
            let mean = delta.reduce(0, +) / Double(delta.count)
            if seat == 1 { XCTAssertEqual(abs(mean), 6, accuracy: 0.5) } else { XCTAssertEqual(mean, 0, accuracy: 0.05) }
        }
    }

    func testMeasuringOneSeatRunsOneMicrophone() async throws {
        let rig = try makeRig(rate: 48_000, perSeat: true)
        defer { rig.tearDown() }
        let records = try await measurer(rig).measureSeats([1], sampleRate: 48_000)
        XCTAssertEqual(records.map(\.seatIndex), [1])
        XCTAssertEqual(rig.transports.passCount, 3)
        XCTAssertTrue(rig.transports.passes.allSatisfy { $0.additional.isEmpty && $0.primary.channelIndex == 1 })
        XCTAssertEqual(rig.calibration.measurements.count, 3)
    }

    // MARK: Readiness

    func testEachReadinessReasonAppearsWhenItsConditionHolds() {
        let device = inputDevice()
        func seat(_ name: String, _ mic: MultichannelSeatMicrophone?) -> MultichannelCalibrationSeat {
            MultichannelCalibrationSeat(name: name, microphone: mic)
        }
        func mic(_ channel: Int, uid: String = "e24-reference-mic") -> MultichannelSeatMicrophone {
            MultichannelSeatMicrophone(deviceUID: uid, channelIndex: channel, calibration: nil)
        }
        let blocker = MeasurementReadiness.perSeatBlocker
        XCTAssertNil(blocker([seat("A", mic(0)), seat("B", mic(1))], [device]))
        XCTAssertTrue(blocker([seat("A", mic(0)), seat("B", nil)], [device])?.reason.contains("B has no microphone") == true)
        XCTAssertTrue(blocker([seat("A", mic(0, uid: "gone"))], [device])?.reason.contains("not connected") == true)
        XCTAssertTrue(blocker([seat("A", mic(0)), seat("B", mic(0))], [device])?.reason.contains("same microphone channel") == true)
        let other = AudioInputDevice(
            deviceID: 9_003, uid: "other", name: "Other", nominalSampleRate: 48_000,
            availableSampleRateRanges: device.availableSampleRateRanges)
        XCTAssertTrue(blocker([seat("A", mic(0)), seat("B", mic(0, uid: "other"))], [device, other])?.reason.contains("different devices") == true)
        let many = (0..<(MeasurementSeatPlan.maxSeats + 1)).map { seat("S\($0)", mic($0)) }
        XCTAssertTrue(blocker(many, [device])?.reason.contains("at most") == true)
    }

    // MARK: Persistence

    func testSeatMicrophonesRoundTripAndOldArchivesDecodeWithNil() throws {
        let calibration = RoomCorrectionMicrophoneCalibration(sourceName: "umik", points: [.init(frequencyHz: 100, gainDB: 1)])
        let seat = MultichannelCalibrationSeat(
            name: "Sofa", microphone: MultichannelSeatMicrophone(deviceUID: "uid", channelIndex: 3, calibration: calibration))
        let decoded = try JSONDecoder().decode(MultichannelCalibrationSeat.self, from: JSONEncoder().encode(seat))
        XCTAssertEqual(decoded, seat)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(seat)) as? [String: Any])
        object.removeValue(forKey: "microphone")
        let old = try JSONDecoder().decode(MultichannelCalibrationSeat.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.microphone)
    }

    func testModeAndMicrophonesSurviveReload() throws {
        let rig = try makeRig(rate: 48_000, perSeat: true)
        defer { rig.tearDown() }
        let again = MultichannelCalibrationController(
            engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone,
            store: MultichannelCalibrationCampaignStore(rootDirectory: rig.root.appendingPathComponent("campaigns")),
            transportFactory: { _, _, _, _, _, _ in throw MultichannelCalibrationTransportError.incompleteCapture })
        again.prepareForUse()
        XCTAssertEqual(again.seatMicrophoneMode, .perSeat)
        XCTAssertEqual(again.seats.map { $0.microphone?.channelIndex }, [0, 1, 2])
    }

    // MARK: Wizard, per-seat mode

    /// The production setup model, three seats on three channels of one interface, measured in one pass per source and
    /// carried through alignment. 48 and 384 kHz in `pr.yml`; all eight rates in `macos-full.yml` (`N60_E24_RATES`).
    func testWizardMeasuresThreeSeatsInOnePassPerSourceAtEveryRate() async throws {
        for rate in Self.rates {
            let label = "\(rate) Hz"
            let rig = try makeRig(rate: rate, perSeat: true)
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
            XCTAssertEqual(model.step, .measure, "\(label): \(model.message ?? "")")
            model.prepareMeasure()
            XCTAssertEqual(rig.calibration.seats.count, 3, label)
            await model.measureAll()
            XCTAssertNil(model.message, label)
            XCTAssertEqual(rig.transports.passCount, 3, label)
            XCTAssertEqual(rig.transports.made, 0, "\(label): no sequential pass was needed")
            XCTAssertEqual(model.choices.measurementIDs.count, 3, label)
            model.next()
            XCTAssertEqual(model.step, .alignment, "\(label): \(model.message ?? "")")
            await model.computeAlignment()
            XCTAssertNotNil(model.alignment, "\(label): \(model.message ?? "")")
        }
    }
}
