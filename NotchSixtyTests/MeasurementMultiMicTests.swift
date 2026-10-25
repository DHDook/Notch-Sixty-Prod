import Foundation
import XCTest
@testable import NotchSixty

/// E11 S9: simultaneous multi-microphone capture, at every standard rate. Mics are simulated
/// with the reference room: each has its own latency (device clock offset) and flight time.
final class MeasurementMultiMicTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private struct Rig {
        var pass: MultiMicPass
        var captures: [[Float]?]
        var seats: [MultiMicSeat]
        var offsets: [Double]
        var flights: [Double]
        var referenceFlights: [Double]
    }

    private func simulate(
        _ excitation: [Float], rate: Double, latency: Double, flight: Double, noiseSeed: UInt32
    ) -> [Float] {
        var room = n60_measure_room_params()
        n60_measure_room_defaults(rate, &room)
        room.direct_delay_seconds = flight
        room.latency_seconds = latency
        room.noise_dbfs = -90
        room.noise_seed = noiseSeed
        room.ir_seconds = 0.2
        room.mode_frequencies_hz = (0, 0, 0, 0)
        room.diffuse_level_db = -50 // a clear direct impulse, as in a near-field seat
        room.rt60_seconds = (0.08, 0.08, 0.08, 0.08, 0.08, 0.08, 0.08)
        var frames: UInt64 = 0
        XCTAssertEqual(n60_measure_room_capture_length(&room, UInt64(excitation.count), &frames), N60_MEASURE_OK)
        var out = [Float](repeating: 0, count: Int(frames))
        var produced: UInt64 = 0
        XCTAssertEqual(n60_measure_room_capture(&room, excitation, UInt64(excitation.count), &out, frames, &produced),
                       N60_MEASURE_OK)
        return out
    }

    private func makeRig(rate: Double, mics: Int, latencies: [Double], flights: [Double]) throws -> Rig {
        let sweep = try MeasurementCore.makeSweep(
            sampleRate: rate, startFrequencyHz: 100, endFrequencyHz: 0.4 * rate.rounded(.down) > 20_000 ? 20_000 : 0.4 * rate,
            durationSeconds: 0.5, levelDBFS: -12, fadeSeconds: 0.01, synchronised: true
        ).samples
        let chirp = try MeasurementCore.makeReferenceChirp(sampleRate: rate)
        let chirpStart = 0
        let sweepStart = Int(0.6 * rate)
        let referenceFlights = [Double](repeating: (0.004 * rate).rounded() / rate, count: mics)
        let flights = flights.map { ($0 * rate).rounded() / rate }
        var captures: [[Float]?] = []
        let total = sweepStart + Int(Double(sweep.count) + 0.4 * rate)
        for k in 0..<mics {
            let s = simulate(sweep, rate: rate, latency: latencies[k], flight: flights[k], noiseSeed: UInt32(k + 1))
            let c = simulate(chirp, rate: rate, latency: latencies[k], flight: referenceFlights[k], noiseSeed: UInt32(k + 11))
            var capture = [Float](repeating: 0, count: total)
            for (i, v) in c.enumerated() where i < sweepStart { capture[chirpStart + i] += v }
            for (i, v) in s.enumerated() where sweepStart + i < total { capture[sweepStart + i] += v }
            XCTAssertTrue(capture.contains { $0 != 0 }, "mic \(k) silent: sim \(s.count) \(c.count) peak \(s.map { abs($0) }.max() ?? -1)")
            captures.append(capture)
        }
        let seats = (0..<mics).map { MultiMicSeat(id: $0, label: "Seat \($0 + 1)") }
        return Rig(
            pass: MultiMicPass(sweep: sweep, sweepStartFrame: sweepStart, referenceChirp: chirp, chirpStartFrame: chirpStart),
            captures: captures, seats: seats, offsets: latencies, flights: flights, referenceFlights: referenceFlights
        )
    }

    func testSeparateMicsRecoverFlightTimeIndependentOfDeviceLatency() throws {
        for rate in Self.rates {
            let rig = try makeRig(rate: rate, mics: 4, latencies: [0.005, 0.011, 0.017, 0.023],
                                  flights: [0.003, 0.0045, 0.006, 0.0075])
            let records = try MeasurementCore.processMultiMic(
                captures: rig.captures, seats: rig.seats, mode: .separateDevices, pass: rig.pass, sampleRate: rate
            )
            XCTAssertEqual(records.count, 4)
            for (k, record) in records.enumerated() {
                let expected = rig.flights[k] - rig.referenceFlights[k]
                XCTAssertEqual(record.delaySeconds, expected, accuracy: 10e-6, "seat \(k) at \(rate)")
                XCTAssertEqual(record.timingTier, .acousticChirp)
            }
        }
    }

    func testSharedClockDelaysAreRelativeToSeatZeroAndMatchSingleMicRuns() throws {
        for rate in Self.rates {
            let rig = try makeRig(rate: rate, mics: 4, latencies: [0.006, 0.006, 0.006, 0.006],
                                  flights: [0.003, 0.0045, 0.006, 0.0075])
            let together = try MeasurementCore.processMultiMic(
                captures: rig.captures, seats: rig.seats, mode: .sharedClock, pass: rig.pass, sampleRate: rate
            )
            for k in 0..<4 {
                XCTAssertEqual(together[k].delaySeconds, rig.flights[k] - rig.flights[0], accuracy: 10e-6, "seat \(k) at \(rate)")
                let alone = try MeasurementCore.processMultiMic(
                    captures: [rig.captures[k]], seats: [rig.seats[k]], mode: .sharedClock, pass: rig.pass, sampleRate: rate
                )
                XCTAssertEqual(alone[0].impulseResponse, together[k].impulseResponse)
            }
        }
    }

    func testMissingMicFailsTheWholeCapture() throws {
        let rate = 48_000.0
        var rig = try makeRig(rate: rate, mics: 3, latencies: [0.005, 0.006, 0.007], flights: [0.003, 0.004, 0.005])
        rig.captures[1] = nil
        XCTAssertThrowsError(try MeasurementCore.processMultiMic(
            captures: rig.captures, seats: rig.seats, mode: .sharedClock, pass: rig.pass, sampleRate: rate
        )) { XCTAssertEqual($0 as? MultiMicError, .missingMic(seat: 1)) }
        // A dead (all-zero) channel is also a missing mic.
        rig.captures[1] = [Float](repeating: 0, count: rig.captures[0]?.count ?? 0)
        XCTAssertThrowsError(try MeasurementCore.processMultiMic(
            captures: rig.captures, seats: rig.seats, mode: .separateDevices, pass: rig.pass, sampleRate: rate
        )) { XCTAssertEqual($0 as? MultiMicError, .missingMic(seat: 1)) }
    }

    func testSeparateMicsRequireAReference() throws {
        let rate = 48_000.0
        var rig = try makeRig(rate: rate, mics: 2, latencies: [0.005, 0.006], flights: [0.003, 0.004])
        rig.pass.referenceChirp = nil
        XCTAssertThrowsError(try MeasurementCore.processMultiMic(
            captures: rig.captures, seats: rig.seats, mode: .separateDevices, pass: rig.pass, sampleRate: rate
        )) { XCTAssertEqual($0 as? MultiMicError, .invalidArguments) }
    }
}
