import XCTest
@testable import NotchSixty

/// E15 S2: default-output events through `OutputFollowEventDriver` with a fake event source, fake engine and a manual
/// clock. No Core Audio, no hardware.
@MainActor
final class OutputFollowEventDriverTests: XCTestCase {
    private final class FakeSource: FollowOutputEventSource {
        var onDefaultOutputChanged: ((OutputFollowTarget?) -> Void)?
        var onDataSourceChanged: ((OutputFollowTarget) -> Void)?
        var onDeviceListChanged: (() -> Void)?
        var onWillSleep: (() -> Void)?
        var onDidWake: (() -> Void)?
        var startCount = 0
        var stopCount = 0
        var monitored: String?
        var available: Set<String> = []
        var defaultTarget: OutputFollowTarget?
        var dataSources: [String: UInt32] = [:]
        func start() throws { startCount += 1 }
        func stop() { stopCount += 1 }
        func monitorDataSource(ofDeviceUID uid: String?) { monitored = uid }
        func currentDefaultTarget() -> OutputFollowTarget? { defaultTarget }
        func dataSourceID(forDeviceUID uid: String) -> UInt32? { dataSources[uid] }
        func availableOutputUIDs() -> Set<String> { available }
        func ownDeviceUIDs() -> Set<String> { ["com.dhdook.NotchSixty.aggregate.1"] }
    }

    @MainActor private final class FakeEngine: OutputFollowEngineControlling {
        var selectedOutputUID: String?
        var rates: [String: Double] = [:]
        var switches: [(uid: String, resume: Bool)] = []
        var runningRate: Double?
        func switchFollowedOutput(to uid: String, resume: Bool) throws {
            switches.append((uid, resume))
            selectedOutputUID = uid
            runningRate = resume ? rates[uid] : nil
        }
    }

    private final class FakeClock: FollowScheduling, @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 5_000)
        private var tasks: [(due: Date, token: FollowTimerToken, block: @MainActor () -> Void, live: Box)] = []
        final class Box { var live = true }
        func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> FollowTimerToken {
            let box = Box()
            let token = FollowTimerToken { box.live = false }
            tasks.append((now.addingTimeInterval(delay), token, block, box))
            return token
        }
        @MainActor func advance(_ seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = tasks.filter({ $0.live.live && $0.due <= target }).min(by: { $0.due < $1.due }) {
                now = max(now, next.due)
                next.live.live = false
                next.block()
            }
            now = target
        }
    }

    private let usb = OutputKey(deviceUID: "usb")
    private let builtIn = OutputKey(deviceUID: "builtin", dataSourceID: 1)
    private let jack = OutputKey(deviceUID: "builtin", dataSourceID: 2)
    private let profileUSB = UUID()
    private let profileBuiltIn = UUID()
    private let profileJack = UUID()

    private var keepAlive: [OutputFollowEventDriver] = []

    private func rig(mode: OutputSelectionMode = .followSystem, selected: String? = "builtin", blocks: Set<OutputFollowBlock> = []) -> (
        OutputFollowEventDriver, FakeSource, FakeEngine, FakeClock, () -> [OutputFollowOutcome]
    ) {
        let source = FakeSource()
        source.available = ["usb", "builtin"]
        source.dataSources = ["builtin": 1]
        let engine = FakeEngine()
        engine.selectedOutputUID = selected
        let clock = FakeClock()
        var bindings = OutputProfileBindings()
        bindings.bind(usb, to: profileUSB)
        bindings.bind(builtIn, to: profileBuiltIn)
        bindings.bind(jack, to: profileJack)
        let state = OutputFollowState(
            mode: mode, bindings: bindings, existingProfileIDs: [profileUSB, profileBuiltIn, profileJack],
            blocks: blocks)
        let policy = OutputFollowPolicy(now: { clock.now })
        let driver = OutputFollowEventDriver(
            source: source, engine: engine, scheduler: clock, policy: policy, stateProvider: { state })
        final class Outcomes { var list: [OutputFollowOutcome] = [] }
        let outcomes = Outcomes()
        driver.onOutcome = { outcomes.list.append($0) }
        driver.reconcile()
        keepAlive.append(driver)
        return (driver, source, engine, clock, { outcomes.list })
    }

    func testFixedModeNeverInstallsListenerAndIgnoresDefaultChanges() {
        let (driver, source, engine, clock, outcomes) = rig(mode: .fixed)
        XCTAssertFalse(driver.isListening)
        XCTAssertEqual(source.startCount, 0)
        source.onDefaultOutputChanged?(OutputFollowTarget(key: usb))
        clock.advance(2)
        XCTAssertTrue(engine.switches.isEmpty)
        XCTAssertTrue(outcomes().isEmpty)
    }

    func testFollowModeSwitchesOnlyAfterSettleWindow() {
        let (_, source, engine, clock, outcomes) = rig()
        XCTAssertEqual(source.startCount, 1)
        source.onDefaultOutputChanged?(OutputFollowTarget(key: usb))
        clock.advance(0.3)
        XCTAssertTrue(engine.switches.isEmpty)
        clock.advance(0.3)
        XCTAssertEqual(engine.switches.map(\.uid), ["usb"])
        XCTAssertEqual(engine.switches.first?.resume, true)
        XCTAssertEqual(outcomes(), [.switched(OutputFollowTarget(key: usb), profileID: profileUSB)])
        XCTAssertEqual(source.monitored, "usb")
    }

    func testRapidChangesCoalesceToTheFinalDevice() {
        let (_, source, engine, clock, _) = rig(selected: "other")
        source.onDefaultOutputChanged?(OutputFollowTarget(key: usb))
        clock.advance(0.3)
        source.onDefaultOutputChanged?(OutputFollowTarget(key: builtIn))
        clock.advance(0.3)
        XCTAssertTrue(engine.switches.isEmpty)
        clock.advance(0.3)
        XCTAssertEqual(engine.switches.map(\.uid), ["builtin"])
    }

    func testSameDeviceNotificationDoesNothing() {
        let (_, source, engine, clock, outcomes) = rig()
        source.onDefaultOutputChanged?(OutputFollowTarget(key: builtIn))
        clock.advance(1)
        XCTAssertTrue(engine.switches.isEmpty)
        XCTAssertTrue(outcomes().isEmpty)
    }

    func testDataSourceChangeOnCurrentDeviceSwitchesToBoundProfile() {
        let (_, source, engine, clock, outcomes) = rig()
        source.onDataSourceChanged?(OutputFollowTarget(key: jack))
        clock.advance(0.6)
        XCTAssertEqual(engine.switches.map(\.uid), ["builtin"])
        XCTAssertEqual(outcomes(), [.switched(OutputFollowTarget(key: jack), profileID: profileJack)])
    }

    func testUnboundDevicePausesProcessingOnThatOutput() {
        let (_, source, engine, clock, outcomes) = rig()
        let airpods = OutputKey(deviceUID: "airpods")
        source.available.insert("airpods")
        source.onDefaultOutputChanged?(OutputFollowTarget(key: airpods))
        clock.advance(0.6)
        XCTAssertEqual(engine.switches.map(\.uid), ["airpods"])
        XCTAssertEqual(engine.switches.first?.resume, false)
        XCTAssertEqual(outcomes(), [.paused(OutputFollowTarget(key: airpods), .noBinding)])
    }

    func testOwnPrivateDeviceIsNeverATarget() {
        let (_, source, engine, clock, _) = rig()
        source.onDefaultOutputChanged?(OutputFollowTarget(key: OutputKey(deviceUID: "com.dhdook.NotchSixty.aggregate.1")))
        clock.advance(1)
        XCTAssertTrue(engine.switches.isEmpty)
    }

    func testUnplugFollowsTheNewDefault() {
        let (_, source, engine, clock, _) = rig(selected: "usb")
        source.available = ["builtin"]
        source.onDeviceListChanged?()
        source.onDefaultOutputChanged?(OutputFollowTarget(key: builtIn))
        clock.advance(0.6)
        XCTAssertEqual(engine.switches.map(\.uid), ["builtin"])
    }

    func testWakeWaitsForPreSleepDeviceThenFollowsAnotherDefault() {
        let (_, source, engine, clock, _) = rig(selected: "usb")
        source.available = ["builtin"]
        source.defaultTarget = OutputFollowTarget(key: builtIn)
        source.onWillSleep?()
        clock.advance(10)
        source.onDidWake?()
        clock.advance(2.5)
        XCTAssertTrue(engine.switches.isEmpty, "pre-sleep device may still re-enumerate")
        clock.advance(0.6)
        XCTAssertEqual(engine.switches.map(\.uid), ["builtin"])
    }

    func testWakeWithLateDeviceReturningDoesNotFlapProfile() {
        let (_, source, engine, clock, _) = rig(selected: "usb")
        source.available = ["builtin"]
        source.defaultTarget = OutputFollowTarget(key: builtIn)
        source.onWillSleep?()
        source.onDidWake?()
        clock.advance(1)
        source.available = ["builtin", "usb"]
        source.defaultTarget = OutputFollowTarget(key: usb)
        source.onDeviceListChanged?()
        clock.advance(4)
        XCTAssertTrue(engine.switches.isEmpty)
    }

    func testBlockedStateHoldsPendingDefaultUntilResumed() {
        var blocks: Set<OutputFollowBlock> = [.measurementCapture]
        let source = FakeSource()
        source.available = ["usb", "builtin"]
        let engine = FakeEngine()
        engine.selectedOutputUID = "builtin"
        let clock = FakeClock()
        var bindings = OutputProfileBindings()
        bindings.bind(usb, to: profileUSB)
        let driver = OutputFollowEventDriver(
            source: source, engine: engine, scheduler: clock, policy: OutputFollowPolicy(now: { clock.now }),
            stateProvider: {
                OutputFollowState(mode: .followSystem, bindings: bindings, existingProfileIDs: [self.profileUSB], blocks: blocks)
            })
        driver.reconcile()
        source.onDefaultOutputChanged?(OutputFollowTarget(key: usb))
        clock.advance(5)
        XCTAssertTrue(engine.switches.isEmpty)
        blocks = []
        driver.resumePending()
        XCTAssertEqual(engine.switches.map(\.uid), ["usb"])
    }

    func testSwitchingAcrossEveryRatePairFollowsEachDeviceAtItsOwnRate() {
        let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        let (_, source, engine, clock, _) = rig(selected: "dev0")
        var bindings = OutputProfileBindings()
        var ids: [UUID] = []
        for index in rates.indices {
            engine.rates["dev\(index)"] = rates[index]
            source.available.insert("dev\(index)")
            let id = UUID()
            ids.append(id)
            bindings.bind(OutputKey(deviceUID: "dev\(index)"), to: id)
        }
        let driver = OutputFollowEventDriver(
            source: source, engine: engine, scheduler: clock, policy: OutputFollowPolicy(now: { clock.now }),
            stateProvider: { OutputFollowState(mode: .followSystem, bindings: bindings, existingProfileIDs: Set(ids)) })
        driver.reconcile()
        var covered = 0
        for from in rates.indices {
            for to in rates.indices where to != from {
                engine.selectedOutputUID = "dev\(from)"
                source.onDefaultOutputChanged?(OutputFollowTarget(key: OutputKey(deviceUID: "dev\(to)")))
                clock.advance(0.6)
                XCTAssertEqual(engine.selectedOutputUID, "dev\(to)")
                XCTAssertEqual(engine.runningRate, rates[to])
                covered += 1
            }
        }
        XCTAssertEqual(covered, rates.count * (rates.count - 1))
    }

    func testTurningFollowOffRemovesListeners() {
        let (driver, source, engine, clock, _) = rig()
        driver.stop()
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(source.onDefaultOutputChanged)
        XCTAssertFalse(driver.isListening)
        clock.advance(1)
        XCTAssertTrue(engine.switches.isEmpty)
    }
}
