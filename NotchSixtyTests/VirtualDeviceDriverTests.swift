import CoreAudio
import XCTest
@testable import NotchSixty

/// E36 S2: driver protocol, discovery, version gate, lease writer and status model, against a fake plug-in.
final class VirtualDeviceDriverTests: XCTestCase {
    final class FakePlugIn: DriverPluginAccess {
        var installed = true
        var version: UInt32 = N60_VD_PROTOCOL_VERSION
        var versionReadStatus: OSStatus = noErr
        var leaseWriteStatus: OSStatus = noErr
        var leases: [N60VDLease] = []
        var otherWrites = 0
        var threadsSeen: [Bool] = []

        func pluginObject(forBundleID bundleID: String) -> AudioObjectID? {
            installed && bundleID == N60_VD_PLUGIN_BUNDLE_ID ? 77 : nil
        }
        func readUInt32(object: AudioObjectID, selector: UInt32) -> (status: OSStatus, value: UInt32) {
            selector == N60_VD_PROP_PROTOCOL_VERSION ? (versionReadStatus, version) : (kAudioHardwareUnknownPropertyError, 0)
        }
        func writeData(object: AudioObjectID, selector: UInt32, data: Data) -> OSStatus {
            threadsSeen.append(Thread.isMainThread)
            guard selector == N60_VD_PROP_LEASE, object == 77 else { otherWrites += 1; return kAudioHardwareUnknownPropertyError }
            if leaseWriteStatus == noErr {
                leases.append(data.withUnsafeBytes { $0.loadUnaligned(as: N60VDLease.self) })
            }
            return leaseWriteStatus
        }
    }

    final class ManualScheduler: LeaseScheduler {
        final class Handle: LeaseTimer {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        var intervals: [UInt32] = []
        var handles: [Handle] = []
        func schedule(everyMs interval: UInt32, _ handler: @escaping @Sendable () -> Void) -> any LeaseTimer {
            intervals.append(interval)
            let handle = Handle()
            handles.append(handle)
            return handle
        }
    }

    private func makeModel(_ plugIn: FakePlugIn, _ scheduler: ManualScheduler = ManualScheduler())
        -> (DriverStatusModel, DriverLeaseWriter) {
        let lease = DriverLeaseWriter(access: plugIn, scheduler: scheduler, sessionToken: 9)
        return (DriverStatusModel(discovery: DriverDiscovery(access: plugIn), lease: lease), lease)
    }

    func testProtocolConstantsMatchTheHeader() {
        XCTAssertEqual(VirtualDeviceProtocol.currentVersion, N60_VD_PROTOCOL_VERSION)
        XCTAssertTrue(VirtualDeviceProtocol.acceptedVersions.contains(N60_VD_PROTOCOL_VERSION))
        XCTAssertEqual(VirtualDeviceProtocol.leaseRenewMs, N60_VD_LEASE_RENEW_MS)
        XCTAssertLessThan(N60_VD_LEASE_RENEW_MS * 4, N60_VD_LEASE_EXPIRY_MS, "several missed renewals before expiry")
        XCTAssertEqual(MemoryLayout<N60VDLease>.size, 24)
        let selectors = [N60_VD_PROP_PROTOCOL_VERSION, N60_VD_PROP_LEASE, N60_VD_PROP_CLOCK_SCALAR,
                         N60_VD_PROP_DAC_RATES, N60_VD_PROP_LAYOUT, N60_VD_PROP_LATENCY]
        XCTAssertEqual(Set(selectors).count, selectors.count)
    }

    func testStatusForEveryCase() {
        let plugIn = FakePlugIn()
        let (model, _) = makeModel(plugIn)
        plugIn.installed = false
        XCTAssertEqual(model.refresh(), .notInstalled)
        plugIn.installed = true
        XCTAssertEqual(model.refresh(), .installed(version: N60_VD_PROTOCOL_VERSION))
        plugIn.version = N60_VD_PROTOCOL_VERSION + 1
        XCTAssertEqual(model.refresh(), .unknownVersion(N60_VD_PROTOCOL_VERSION + 1))
        plugIn.version = N60_VD_PROTOCOL_VERSION - 1
        XCTAssertEqual(model.refresh(), .needsUpdate(version: N60_VD_PROTOCOL_VERSION - 1))
        plugIn.version = N60_VD_PROTOCOL_VERSION
        plugIn.versionReadStatus = kAudioHardwareUnspecifiedError
        XCTAssertEqual(model.refresh(), .unknownVersion(0))
        plugIn.versionReadStatus = noErr
        XCTAssertEqual(model.acquireLease(), .inUse(version: N60_VD_PROTOCOL_VERSION))
        model.releaseLease()
        XCTAssertEqual(model.status, .installed(version: N60_VD_PROTOCOL_VERSION))
    }

    func testGateAcceptsOnlyListedVersions() {
        let gate = DriverVersionGate(accepted: [2, 3], minimum: 2)
        XCTAssertEqual(gate.status(forDriverVersion: 1, leaseHeld: false), .needsUpdate(version: 1))
        XCTAssertEqual(gate.status(forDriverVersion: 2, leaseHeld: false), .installed(version: 2))
        XCTAssertEqual(gate.status(forDriverVersion: 3, leaseHeld: true), .inUse(version: 3))
        XCTAssertEqual(gate.status(forDriverVersion: 4, leaseHeld: false), .unknownVersion(4))
    }

    func testUnusableStatusesNeverTakeALease() {
        for version in [N60_VD_PROTOCOL_VERSION + 1, N60_VD_PROTOCOL_VERSION - 1] {
            let plugIn = FakePlugIn()
            plugIn.version = version
            let scheduler = ManualScheduler()
            let (model, lease) = makeModel(plugIn, scheduler)
            XCTAssertFalse(model.acquireLease().isUsable)
            XCTAssertFalse(lease.isActive)
            XCTAssertTrue(plugIn.leases.isEmpty)
            XCTAssertTrue(scheduler.handles.isEmpty)
        }
        let missing = FakePlugIn()
        missing.installed = false
        let (model, _) = makeModel(missing)
        XCTAssertEqual(model.acquireLease(), .notInstalled)
        XCTAssertTrue(missing.leases.isEmpty)
    }

    func testLeaseCadenceAndSequence() throws {
        let plugIn = FakePlugIn()
        let scheduler = ManualScheduler()
        let (model, lease) = makeModel(plugIn, scheduler)
        XCTAssertEqual(model.acquireLease(), .inUse(version: N60_VD_PROTOCOL_VERSION))
        XCTAssertEqual(scheduler.intervals, [N60_VD_LEASE_RENEW_MS])
        XCTAssertEqual(plugIn.leases.count, 1)
        for _ in 0..<4 { lease.renew() }
        XCTAssertEqual(plugIn.leases.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertTrue(plugIn.leases.allSatisfy {
            $0.validMs == N60_VD_LEASE_EXPIRY_MS && $0.sessionToken == 9
                && $0.protocolVersion == N60_VD_PROTOCOL_VERSION && $0.reserved == 0
        })
        // A second acquire neither restarts the timer nor writes another first lease.
        _ = model.acquireLease()
        XCTAssertEqual(scheduler.handles.count, 1)
    }

    func testReleaseOnQuitWritesZeroAndStopsRenewing() {
        let plugIn = FakePlugIn()
        let scheduler = ManualScheduler()
        let (model, lease) = makeModel(plugIn, scheduler)
        _ = model.acquireLease()
        model.releaseLease()
        XCTAssertTrue(scheduler.handles[0].cancelled)
        XCTAssertEqual(plugIn.leases.last?.validMs, 0)
        let count = plugIn.leases.count
        lease.renew()
        model.releaseLease()
        XCTAssertEqual(plugIn.leases.count, count, "no write after release, and release twice is harmless")
        XCTAssertFalse(lease.isActive)
    }

    func testRefusedFirstLeaseStartsNoTimerAndIsReported() {
        let plugIn = FakePlugIn()
        plugIn.leaseWriteStatus = kAudioHardwareUnspecifiedError
        let scheduler = ManualScheduler()
        let (model, lease) = makeModel(plugIn, scheduler)
        XCTAssertEqual(model.acquireLease(), .leaseRefused(kAudioHardwareUnspecifiedError))
        XCTAssertFalse(lease.isActive)
        XCTAssertTrue(scheduler.handles.isEmpty)
    }

    func testRenewalFailureIsRecordedAndClears() {
        let plugIn = FakePlugIn()
        let (model, lease) = makeModel(plugIn)
        _ = model.acquireLease()
        plugIn.leaseWriteStatus = kAudioHardwareUnspecifiedError
        lease.renew()
        XCTAssertEqual(lease.lastFailure, kAudioHardwareUnspecifiedError)
        plugIn.leaseWriteStatus = noErr
        lease.renew()
        XCTAssertNil(lease.lastFailure)
    }

    func testWriterTouchesOnlyTheLeasePropertyAndNeverTheAudioPath() {
        let plugIn = FakePlugIn()
        let (model, lease) = makeModel(plugIn)
        _ = model.acquireLease()
        lease.renew()
        model.releaseLease()
        XCTAssertEqual(plugIn.otherWrites, 0)
        // The real timer runs on its own utility queue, never the main thread or an audio thread.
        let fired = expectation(description: "dispatch timer fires off the main thread")
        fired.assertForOverFulfill = false  // the 10 ms timer can fire again before cancel()
        let scheduler = DispatchLeaseScheduler()
        let timer = scheduler.schedule(everyMs: 10) {
            if !Thread.isMainThread { fired.fulfill() }
        }
        wait(for: [fired], timeout: 2)
        timer.cancel()
    }
}
