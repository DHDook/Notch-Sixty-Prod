import CoreAudio
import XCTest
@testable import NotchSixty

/// E36 S5: the switch, default-output takeover and restore, crash recovery and the no-fallback rule, on fakes.
/// The control plane has no sample-rate dependence (rates are S3), so these run once, not per rate.
@MainActor
final class DriverInputCoordinatorTests: XCTestCase {
    typealias Plug = VirtualDeviceDriverTests.FakePlugIn

    final class FakeOutput: SystemOutputControlling {
        var current: String? = "dac.uid"
        var log: [String] = []
        var refuseSet = false
        var absent: Set<String> = []
        func defaultOutputUID() -> String? { current }
        func setDefaultOutput(uid: String) -> Bool {
            log.append("set:\(uid)")
            guard !refuseSet, !absent.contains(uid) else { return false }
            current = uid
            return true
        }
    }

    final class FakeStore: PreviousOutputStoring { var previousOutputUID: String? }

    private func make(_ plug: Plug, _ output: FakeOutput, _ store: FakeStore, log: LogBox)
        -> (DriverInputCoordinator, DriverLeaseWriter) {
        let lease = DriverLeaseWriter(access: plug, scheduler: VirtualDeviceDriverTests.ManualScheduler(), sessionToken: 3)
        let driver = DriverStatusModel(discovery: DriverDiscovery(access: plug), lease: lease)
        let hooks = InputSwitchHooks(
            fadeOut: { log.events.append("fadeOut") },
            applySource: { log.events.append("source:\($0.rawValue)") },
            fadeIn: { log.events.append("fadeIn") })
        return (DriverInputCoordinator(driver: driver, output: output, store: store, hooks: hooks), lease)
    }

    final class LogBox { var events: [String] = [] }

    func testSwitchToDriverFadesOutThenTakesOverThenChangesSource() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        let (c, lease) = make(plug, output, store, log: log)
        XCTAssertEqual(c.switchTo(.virtualDriver), .virtualDriver)
        XCTAssertEqual(log.events, ["fadeOut", "source:virtualDriver", "fadeIn"])
        XCTAssertEqual(output.current, N60_VD_DEVICE_UID)
        XCTAssertEqual(store.previousOutputUID, "dac.uid")
        XCTAssertTrue(lease.isActive)
        XCTAssertEqual(c.lifecycle.state, .running)
    }

    func testSwitchAwayRestoresOutputBeforeReleasingLease() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        let (c, lease) = make(plug, output, store, log: log)
        c.switchTo(.virtualDriver)
        log.events.removeAll()
        let leasesBefore = plug.leases.count
        XCTAssertEqual(c.switchTo(.processTap), .processTap)
        XCTAssertEqual(output.current, "dac.uid")
        XCTAssertNil(store.previousOutputUID)
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(plug.leases.count, leasesBefore + 1)
        XCTAssertEqual(plug.leases.last?.validMs, 0, "lease released")
        XCTAssertEqual(log.events, ["fadeOut", "source:processTap", "fadeIn"])
        XCTAssertEqual(output.log.last, "set:dac.uid")
    }

    func testQuitRestoresOutputThenReleasesLease() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        let (c, lease) = make(plug, output, store, log: log)
        c.switchTo(.virtualDriver)
        c.shutdownForTermination()
        XCTAssertEqual(output.current, "dac.uid")
        XCTAssertNil(store.previousOutputUID)
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(plug.leases.last?.validMs, 0)
    }

    func testNextLaunchAfterCrashRestoresPreviousOutput() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        store.previousOutputUID = "dac.uid"
        output.current = N60_VD_DEVICE_UID
        let (c, _) = make(plug, output, store, log: log)
        c.recoverAfterCrash()
        XCTAssertEqual(output.current, "dac.uid")
        XCTAssertNil(store.previousOutputUID)
    }

    func testCrashRecoveryKeepsARealOutputMacOSAlreadyChose() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        store.previousOutputUID = "dac.uid"
        output.current = "builtin.uid"
        let (c, _) = make(plug, output, store, log: log)
        c.recoverAfterCrash()
        XCTAssertEqual(output.current, "builtin.uid")
        XCTAssertNil(store.previousOutputUID)
        XCTAssertTrue(output.log.isEmpty)
    }

    func testMissingDriverWaitsAndNeverFallsBackOrTouchesOutput() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        plug.installed = false
        let (c, _) = make(plug, output, store, log: log)
        XCTAssertEqual(c.switchTo(.virtualDriver), .virtualDriver, "the choice stands; no tap fallback")
        XCTAssertEqual(c.lifecycle.state, .waitingForInputDevice)
        XCTAssertFalse(log.events.contains("source:processTap"))
        XCTAssertFalse(log.events.contains("source:virtualDriver"))
        XCTAssertTrue(output.log.isEmpty)
        XCTAssertNotNil(c.statusMessage)
    }

    func testUnknownVersionAndRefusedLeaseNeverFallBack() {
        for configure in [{ (p: Plug) in p.version = 99 }, { (p: Plug) in p.leaseWriteStatus = -1 }] {
            let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
            configure(plug)
            let (c, lease) = make(plug, output, store, log: log)
            c.switchTo(.virtualDriver)
            XCTAssertEqual(c.lifecycle.state, .waitingForInputDevice)
            XCTAssertEqual(c.path, .virtualDriver)
            XCTAssertFalse(lease.isActive)
            XCTAssertEqual(output.current, "dac.uid")
        }
    }

    func testDriverVanishingWaitsThenReturnsAndReengages() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        let (c, _) = make(plug, output, store, log: log)
        c.switchTo(.virtualDriver)
        plug.installed = false
        c.reconcile()
        XCTAssertEqual(c.lifecycle.state, .waitingForInputDevice)
        XCTAssertFalse(log.events.suffix(1).contains("source:processTap"))
        plug.installed = true
        c.reconcile()
        XCTAssertEqual(c.lifecycle.state, .running)
        XCTAssertEqual(c.path, .virtualDriver)
    }

    func testRefusedTakeoverReleasesLeaseAndWaits() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        output.refuseSet = true
        let (c, lease) = make(plug, output, store, log: log)
        c.switchTo(.virtualDriver)
        XCTAssertEqual(c.lifecycle.state, .waitingForInputDevice)
        XCTAssertFalse(lease.isActive)
        XCTAssertEqual(output.current, "dac.uid")
    }

    func testTapPathIsUntouchedByPollingAndDefaultStaysTap() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        let (c, lease) = make(plug, output, store, log: log)
        c.reconcile()
        XCTAssertEqual(c.path, .processTap)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(plug.leases.isEmpty)
        XCTAssertFalse(lease.isActive)
    }

    func testModelSwitchGoesThroughCoordinatorAndKeepsWaitingChoice() {
        let plug = Plug(), output = FakeOutput(), store = FakeStore(), log = LogBox()
        let (c, _) = make(plug, output, store, log: log)
        let model = AudioInputPathModel(probe: { c.status }, downloadURL: nil, openURL: { _ in }, coordinator: c)
        model.select(.virtualDriver)
        XCTAssertEqual(model.selectedPath, .virtualDriver)
        XCTAssertEqual(output.current, N60_VD_DEVICE_UID)
        plug.installed = false
        model.refresh()
        XCTAssertEqual(model.selectedPath, .virtualDriver, "waiting, not the tap")
        XCTAssertNotNil(model.waitingMessage)
        model.select(.processTap)
        XCTAssertEqual(model.selectedPath, .processTap)
        XCTAssertEqual(output.current, "dac.uid")
        XCTAssertNil(model.waitingMessage)
    }
}
