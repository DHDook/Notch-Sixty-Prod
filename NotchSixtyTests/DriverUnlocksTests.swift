import CoreAudio
import XCTest
@testable import NotchSixty

/// E36 S6a: the unlock registry drives every note, and the reported latency equals the added delay plus the device's.
/// Latency is carried in frames, so the eight-rate check converts a fixed delay in milliseconds at each rate.
@MainActor
final class DriverUnlocksTests: XCTestCase {
    typealias Plug = VirtualDeviceDriverTests.FakePlugIn

    func testRegistryListsEveryFeatureOnce() {
        XCTAssertEqual(DriverUnlockRegistry.all.count, 4)
        XCTAssertEqual(Set(DriverUnlockRegistry.all).count, DriverUnlockRegistry.all.count)
    }

    func testEveryFeatureHasANoteWithoutTheDriverAndNoneWithIt() {
        let statuses: [DriverStatus] = [.notInstalled, .installed(version: 1), .needsUpdate(version: 0),
                                        .unknownVersion(9), .leaseRefused(-1)]
        for status in statuses {
            for path in [AudioInputPath.processTap, .virtualDriver] {
                let rows = DriverUnlockRegistry.presentation(path: path, status: status)
                XCTAssertEqual(rows.map(\.unlock), DriverUnlockRegistry.all)
                for row in rows {
                    XCTAssertFalse(row.available)
                    XCTAssertTrue(row.note?.hasPrefix(DriverUnlock.needsDriverNote) == true, "\(status) \(path)")
                }
            }
        }
        for row in DriverUnlockRegistry.presentation(path: .virtualDriver, status: .inUse(version: 1)) {
            XCTAssertTrue(row.available)
            XCTAssertNil(row.note)
        }
        // In use but the tap path chosen is not available either.
        XCTAssertTrue(DriverUnlockRegistry.presentation(path: .processTap, status: .inUse(version: 1)).allSatisfy { !$0.available })
    }

    func testModelUnlocksComeFromTheRegistry() {
        let model = AudioInputPathModel(probe: { .notInstalled }, downloadURL: nil, openURL: { _ in })
        XCTAssertEqual(model.unlocks, DriverUnlockRegistry.presentation(path: .processTap, status: .notInstalled))
    }

    final class LatencyPlug: DriverPluginAccess {
        var latencies: [UInt32] = []
        var failWrites = false
        func pluginObject(forBundleID bundleID: String) -> AudioObjectID? { 77 }
        func readUInt32(object: AudioObjectID, selector: UInt32) -> (status: OSStatus, value: UInt32) { (noErr, N60_VD_PROTOCOL_VERSION) }
        func writeData(object: AudioObjectID, selector: UInt32, data: Data) -> OSStatus {
            if selector == N60_VD_PROP_LATENCY {
                if failWrites { return kAudioHardwareUnspecifiedError }
                latencies.append(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            }
            return noErr
        }
    }

    final class FakeOutput: SystemOutputControlling {
        var current: String? = "dac.uid"
        func defaultOutputUID() -> String? { current }
        func setDefaultOutput(uid: String) -> Bool { current = uid; return true }
    }

    final class FakeStore: PreviousOutputStoring { var previousOutputUID: String? }

    func testLatencyWrittenEqualsAddedPlusDeviceAndUpdatesOnChange() {
        let plug = LatencyPlug(), reporter = DriverLatencyReporter(access: plug)
        let sum = DriverLatencyInputs.self
        XCTAssertTrue(reporter.report(plugIn: 77, inputs: sum.init(addedDelayFrames: 1000, deviceLatencyFrames: 24)))
        XCTAssertFalse(reporter.report(plugIn: 77, inputs: sum.init(addedDelayFrames: 1000, deviceLatencyFrames: 24)))
        XCTAssertTrue(reporter.report(plugIn: 77, inputs: sum.init(addedDelayFrames: 2048, deviceLatencyFrames: 24)))
        XCTAssertEqual(plug.latencies, [1024, 2072])
        reporter.reset()
        XCTAssertTrue(reporter.report(plugIn: 77, inputs: sum.init(addedDelayFrames: 2048, deviceLatencyFrames: 24)))
        XCTAssertEqual(plug.latencies.count, 3)
    }

    func testLatencyAtTheEightStandardRates() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let added = UInt32((rate * 0.0425).rounded()), device = UInt32((rate * 0.001).rounded())
            let plug = LatencyPlug(), reporter = DriverLatencyReporter(access: plug)
            reporter.report(plugIn: 77, inputs: DriverLatencyInputs(addedDelayFrames: added, deviceLatencyFrames: device))
            XCTAssertEqual(plug.latencies, [added + device], "\(rate)")
        }
    }

    func testTotalSaturatesInsteadOfWrapping() {
        XCTAssertEqual(DriverLatencyInputs(addedDelayFrames: .max, deviceLatencyFrames: 5).totalFrames, .max)
    }

    func testFailedWriteRetriesNextTime() {
        let plug = LatencyPlug(), reporter = DriverLatencyReporter(access: plug)
        let inputs = DriverLatencyInputs(addedDelayFrames: 10, deviceLatencyFrames: 1)
        plug.failWrites = true
        XCTAssertFalse(reporter.report(plugIn: 77, inputs: inputs))
        plug.failWrites = false
        XCTAssertTrue(reporter.report(plugIn: 77, inputs: inputs))
    }

    func testCoordinatorPublishesOnEngageUpdatesOnPollAndNothingOnTap() {
        let plug = LatencyPlug(), reporter = DriverLatencyReporter(access: plug)
        let lease = DriverLeaseWriter(access: plug, scheduler: VirtualDeviceDriverTests.ManualScheduler(), sessionToken: 3)
        let driver = DriverStatusModel(discovery: DriverDiscovery(access: plug), lease: lease)
        var inputs: DriverLatencyInputs? = DriverLatencyInputs(addedDelayFrames: 500, deviceLatencyFrames: 12)
        let c = DriverInputCoordinator(
            driver: driver, output: FakeOutput(), store: FakeStore(), latency: reporter, latencySource: { inputs })
        c.publishLatency()
        XCTAssertTrue(plug.latencies.isEmpty, "tap path writes nothing")
        c.switchTo(.virtualDriver)
        XCTAssertEqual(plug.latencies, [512])
        inputs = DriverLatencyInputs(addedDelayFrames: 700, deviceLatencyFrames: 12)
        c.reconcile()
        XCTAssertEqual(plug.latencies, [512, 712])
        inputs = nil
        c.reconcile()
        XCTAssertEqual(plug.latencies.count, 2, "unknown source writes nothing")
        c.switchTo(.processTap)
        XCTAssertNil(reporter.lastWritten)
    }
}
