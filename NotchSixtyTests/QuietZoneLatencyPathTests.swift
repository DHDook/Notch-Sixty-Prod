import CoreAudio
import Foundation
import XCTest
@testable import NotchSixty

/// E4 S7: the lowest-latency output profile against a fake HAL, the measured
/// latency store and the supported-hardware lookup.
final class QuietZoneLatencyPathTests: XCTestCase {
    private final class FakeBufferSizes: OutputBufferSizeControlling {
        var ranges: [AudioDeviceID: ClosedRange<UInt32>] = [:]
        var frames: [AudioDeviceID: UInt32] = [:]
        var writes: [(AudioDeviceID, UInt32)] = []

        func bufferFrameSizeRange(deviceID: AudioDeviceID) throws -> ClosedRange<UInt32> {
            guard let range = ranges[deviceID] else { throw OutputBufferSizeError.invalidRange }
            return range
        }

        func bufferFrameSize(deviceID: AudioDeviceID) throws -> UInt32 {
            guard let value = frames[deviceID] else { throw OutputBufferSizeError.invalidRange }
            return value
        }

        func setBufferFrameSize(_ value: UInt32, deviceID: AudioDeviceID) throws {
            guard let range = ranges[deviceID], range.contains(value) else {
                throw OutputBufferSizeError.coreAudio(operation: "set", status: -50)
            }
            frames[deviceID] = value
            writes.append((deviceID, value))
        }
    }

    func testLowestFramesHonoursDeviceFloorAndRack() {
        typealias P = LowLatencyOutputBufferProfile
        XCTAssertEqual(P.lowestFrames(range: 14...4096, current: 512, sampleRate: 48_000, maximumFramesPerSlice: nil), 32,
                       "never below the 32-frame floor")
        XCTAssertEqual(P.lowestFrames(range: 64...4096, current: 512, sampleRate: 48_000, maximumFramesPerSlice: nil), 64)
        XCTAssertEqual(P.lowestFrames(range: 14...4096, current: 512, sampleRate: 48_000, maximumFramesPerSlice: 24), 24,
                       "clamped to the rack's maximum slice")
        XCTAssertEqual(P.lowestFrames(range: 14...4096, current: 16, sampleRate: 48_000, maximumFramesPerSlice: nil), 16,
                       "never larger than the size already in use")
        // The floor is at least 0.25 ms at every rate.
        let expected: [Double: UInt32] = [
            44_100: 32, 48_000: 32, 88_200: 32, 96_000: 32,
            176_400: 45, 192_000: 48, 352_800: 89, 384_000: 96,
        ]
        for (rate, floor) in expected {
            XCTAssertEqual(P.lowestFrames(range: 14...4096, current: 1024, sampleRate: rate, maximumFramesPerSlice: nil),
                           floor, "\(rate) Hz")
            XCTAssertGreaterThanOrEqual(Double(floor) / rate, 0.000_25 - 1e-12, "\(rate) Hz")
        }
    }

    func testProfileAppliesRecordsAndRestores() throws {
        let hal = FakeBufferSizes()
        hal.ranges = [10: 15...4096, 20: 64...2048]
        hal.frames = [10: 512, 20: 256]
        let profile = LowLatencyOutputBufferProfile(controller: hal)

        XCTAssertNil(try profile.apply(to: 10, uid: "a", sampleRate: 48_000), "inactive profile does nothing")
        XCTAssertTrue(hal.writes.isEmpty)

        profile.activate()
        XCTAssertEqual(try profile.apply(to: 10, uid: "a", sampleRate: 48_000), 32)
        XCTAssertEqual(hal.frames[10], 32)
        XCTAssertEqual(try profile.apply(to: 10, uid: "a", sampleRate: 48_000), 32, "re-applying keeps the original record")
        XCTAssertEqual(profile.originalFrames["a"], 512)

        // Device change while on: the new device gets the profile too.
        XCTAssertEqual(try profile.apply(to: 20, uid: "b", sampleRate: 48_000), 64)
        XCTAssertEqual(hal.frames[20], 64)

        // Off: the present device is restored; the absent one keeps its
        // record and is restored when it is back.
        let first = profile.deactivate { uid in uid == "a" ? 10 : nil }
        XCTAssertEqual(first.restored, ["a"])
        XCTAssertEqual(hal.frames[10], 512)
        XCTAssertFalse(profile.isActive)
        XCTAssertEqual(profile.originalFrames, ["b": 256])
        let second = profile.deactivate { uid in uid == "b" ? 20 : nil }
        XCTAssertEqual(second.restored, ["b"])
        XCTAssertEqual(hal.frames[20], 256)
        XCTAssertTrue(profile.originalFrames.isEmpty)
    }

    @MainActor
    func testEngineProfileTogglesWithoutTouchingAnIdleTransport() {
        let hal = FakeBufferSizes()
        let engine = AudioIOEngine(outputBufferSizeController: hal)
        engine.setLowLatencyOutputProfile(true)
        XCTAssertTrue(engine.lowLatencyOutputProfileActive)
        XCTAssertEqual(engine.lifecycleState, .idle)
        XCTAssertTrue(hal.writes.isEmpty, "applied when a transport is built, not while idle")
        engine.setLowLatencyOutputProfile(false)
        XCTAssertFalse(engine.lowLatencyOutputProfileActive)
        XCTAssertNil(engine.lowLatencyOutputBufferFrames)
    }

    private func entry(_ key: QuietZoneLatencyKey, ms: Double) -> QuietZoneMeasuredLatency {
        QuietZoneMeasuredLatency(
            key: key, roundTripSeconds: ms / 1000, upperBoundSeconds: ms / 1000 + 0.0005,
            measuredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testStorePersistsPerInterfaceRateAndBuffer() throws {
        let suite = "QuietZoneLatencyPathTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = QuietZoneLatencyKey(outputDeviceUID: "out", microphoneDeviceUID: "mic",
                                      sampleRate: 384_000.2, bufferFrames: 64)
        XCTAssertEqual(key.sampleRate, 384_000)
        let store = QuietZoneMeasuredLatencyStore(defaults: defaults)
        store.record(entry(key, ms: 4.2))
        store.record(entry(key, ms: 4.0))

        let reloaded = QuietZoneMeasuredLatencyStore(defaults: defaults)
        XCTAssertEqual(reloaded.all.count, 1, "newest replaces the older entry for a key")
        XCTAssertEqual(try XCTUnwrap(reloaded.latency(for: key)).roundTripSeconds, 0.004, accuracy: 1e-12)
        var otherBuffer = key
        otherBuffer.bufferFrames = 128
        XCTAssertNil(reloaded.latency(for: otherBuffer))
    }

    func testSupportedHardwareLookupFallsBackToNotYetMeasured() throws {
        let suite = "QuietZoneLatencyPathTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuietZoneMeasuredLatencyStore(defaults: defaults)
        let benchKey = QuietZoneLatencyKey(outputDeviceUID: "rme", microphoneDeviceUID: "mic",
                                           sampleRate: 48_000, bufferFrames: 32)
        let ownKey = QuietZoneLatencyKey(outputDeviceUID: "own", microphoneDeviceUID: "mic",
                                         sampleRate: 96_000, bufferFrames: 32)
        store.record(entry(ownKey, ms: 6))
        let table = [ANCSupportedHardware.Entry(name: "Bench rig", latency: entry(benchKey, ms: 3))]

        XCTAssertEqual(ANCSupportedHardware.latency(for: benchKey, table: table, store: store),
                       .benchMeasured(name: "Bench rig", roundTripSeconds: 0.003))
        if case .measuredHere(let seconds, _) = ANCSupportedHardware.latency(for: ownKey, table: table, store: store) {
            XCTAssertEqual(seconds, 0.006, accuracy: 1e-12)
        } else {
            XCTFail("own measurement not found")
        }
        var unknown = ownKey
        unknown.sampleRate = 44_100
        XCTAssertEqual(ANCSupportedHardware.latency(for: unknown, table: table, store: store), .notYetMeasured)
        XCTAssertTrue(ANCSupportedHardware.tested.isEmpty, "nothing bench-measured until S8")
        XCTAssertEqual(ANCSupportedHardware.LatencyStatus.notYetMeasured.displayText, "Not yet measured")
    }

    func testLatencyMeasurementRunAcceptsEveryStandardRate() throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let rig = QuietZoneHardwareCalibrationRig(
                projectID: UUID(), microphoneID: "mic", microphoneChannel: 0,
                outputDeviceID: "out", routeID: "route", sampleRate: rate,
                clockID: "clock", triggerID: "trigger"
            )
            XCTAssertNoThrow(try QuietZonePhysicalLatencyMeasurementRun(rig: rig), "\(rate) Hz")
        }
    }
}
