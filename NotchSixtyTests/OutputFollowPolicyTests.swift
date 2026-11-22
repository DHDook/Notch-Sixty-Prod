import XCTest
@testable import NotchSixty

/// E15 S1: the decision table behind Follow macOS output, with an injected clock. No Core Audio.
final class OutputFollowPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let profileA = UUID()
    private let profileB = UUID()
    private let usb = OutputKey(deviceUID: "usb-dac")
    private let builtIn = OutputKey(deviceUID: "builtin", dataSourceID: 0x7370_6b72)
    private let jack = OutputKey(deviceUID: "builtin", dataSourceID: 0x6864_706e)

    private func policy(at offset: TimeInterval) -> OutputFollowPolicy {
        let now = t0.addingTimeInterval(offset)
        return OutputFollowPolicy(now: { now })
    }

    private func state(selected: OutputKey? = nil) -> OutputFollowState {
        var bindings = OutputProfileBindings()
        bindings.bind(usb, to: profileA)
        bindings.bind(builtIn, to: profileB)
        return OutputFollowState(
            mode: .followSystem, selectedKey: selected, bindings: bindings,
            existingProfileIDs: [profileA, profileB], availableOutputUIDs: ["usb-dac", "builtin"])
    }

    private func change(_ key: OutputKey?, at offset: TimeInterval = 0) -> OutputFollowEvent {
        .defaultOutputChanged(key.map { OutputFollowTarget(key: $0) }, receivedAt: t0.addingTimeInterval(offset))
    }

    func testSwitchesToBoundProfileAfterSettleWindow() {
        let action = policy(at: 0.6).decide(event: change(usb), state: state(selected: builtIn))
        XCTAssertEqual(action, .switchTo(uid: "usb-dac", key: usb, profileID: profileA))
    }

    func testSettleWindowDefersThenResolves() {
        let early = policy(at: 0.2).decide(event: change(usb), state: state(selected: builtIn))
        XCTAssertEqual(early, .defer(.settling(until: t0.addingTimeInterval(0.5))))
        // A newer notification restarts the window.
        let restarted = policy(at: 0.6).decide(event: change(usb, at: 0.4), state: state(selected: builtIn))
        XCTAssertEqual(restarted, .defer(.settling(until: t0.addingTimeInterval(0.9))))
    }

    func testSameKeyDoesNothing() {
        XCTAssertEqual(policy(at: 1).decide(event: change(usb), state: state(selected: usb)), .none)
    }

    func testNoDefaultOutputDoesNothing() {
        XCTAssertEqual(policy(at: 1).decide(event: change(nil), state: state(selected: usb)), .none)
    }

    func testUnboundDevicePauses() {
        let other = OutputKey(deviceUID: "airplay")
        XCTAssertEqual(
            policy(at: 1).decide(event: change(other), state: state(selected: usb)),
            .pause(uid: "airplay", key: other, reason: .noBinding))
    }

    func testBindingToDeletedProfilePauses() {
        var s = state(selected: builtIn)
        s.existingProfileIDs = [profileB]
        XCTAssertEqual(
            policy(at: 1).decide(event: change(usb), state: s), .pause(uid: "usb-dac", key: usb, reason: .noBinding))
    }

    func testNeedsMappingProfilePauses() {
        var s = state(selected: builtIn)
        s.needsMappingProfileIDs = [profileA]
        XCTAssertEqual(
            policy(at: 1).decide(event: change(usb), state: s),
            .pause(uid: "usb-dac", key: usb, reason: .needsMapping(profileA)))
    }

    func testOwnAggregateIsNeverATarget() {
        var s = state(selected: usb)
        s.ownDeviceUIDs = ["builtin"]
        XCTAssertEqual(policy(at: 1).decide(event: change(builtIn), state: s), .none)
    }

    func testExcludedStatesHoldThePendingDefault() {
        for block in [OutputFollowBlock.safeLaunch, .hardwareAcceptance, .measurementCapture, .engineFailed] {
            var s = state(selected: builtIn)
            s.blocks = [block]
            XCTAssertEqual(policy(at: 1).decide(event: change(usb), state: s), .defer(.blocked(block)))
            s.blocks = []
            XCTAssertEqual(
                policy(at: 1).decide(event: change(usb), state: s),
                .switchTo(uid: "usb-dac", key: usb, profileID: profileA), "applied once \(block) ends")
        }
    }

    func testDataSourceChangeOnCurrentDeviceSwitchesProfile() {
        let event = OutputFollowEvent.dataSourceChanged(OutputFollowTarget(key: jack), receivedAt: t0)
        var s = state(selected: builtIn)
        s.bindings.bind(jack, to: profileA)
        XCTAssertEqual(
            policy(at: 1).decide(event: event, state: s), .switchTo(uid: "builtin", key: jack, profileID: profileA))
    }

    func testDataSourceWithoutOwnBindingFallsBackToDeviceBinding() {
        var s = state(selected: builtIn)
        s.bindings.bind(OutputKey(deviceUID: "builtin"), to: profileA)
        let event = OutputFollowEvent.dataSourceChanged(OutputFollowTarget(key: jack), receivedAt: t0)
        XCTAssertEqual(
            policy(at: 1).decide(event: event, state: s), .switchTo(uid: "builtin", key: jack, profileID: profileA))
    }

    func testDataSourceEventForAnotherDeviceIsIgnored() {
        let event = OutputFollowEvent.dataSourceChanged(OutputFollowTarget(key: jack), receivedAt: t0)
        XCTAssertEqual(policy(at: 1).decide(event: event, state: state(selected: usb)), .none)
    }

    func testWakeWaitsForPreSleepDeviceThenFollowsDefault() {
        var s = state(selected: usb)
        s.availableOutputUIDs = ["builtin"]
        s.wake = OutputFollowWake(preSleepUID: "usb-dac", until: t0.addingTimeInterval(3))
        XCTAssertEqual(
            policy(at: 1).decide(event: change(builtIn), state: s),
            .defer(.wakeWindow(until: t0.addingTimeInterval(3))))
        XCTAssertEqual(
            policy(at: 3.1).decide(event: change(builtIn), state: s),
            .switchTo(uid: "builtin", key: builtIn, profileID: profileB))
    }

    func testWakeWindowDoesNotDelayThePreSleepDeviceItself() {
        var s = state(selected: builtIn)
        s.wake = OutputFollowWake(preSleepUID: "usb-dac", until: t0.addingTimeInterval(3))
        XCTAssertEqual(
            policy(at: 1).decide(event: change(usb), state: s),
            .switchTo(uid: "usb-dac", key: usb, profileID: profileA))
    }

    func testWakeWindowDoesNotApplyWhenPreSleepDeviceIsPresent() {
        var s = state(selected: usb)
        s.wake = OutputFollowWake(preSleepUID: "usb-dac", until: t0.addingTimeInterval(3))
        XCTAssertEqual(
            policy(at: 1).decide(event: change(builtIn), state: s),
            .switchTo(uid: "builtin", key: builtIn, profileID: profileB))
    }

    func testFixedModeNeverFollows() {
        var s = state(selected: builtIn)
        s.mode = .fixed
        XCTAssertEqual(policy(at: 1).decide(event: change(usb), state: s), .none)
    }

    func testFlagOffForcesFixedWhateverIsStored() {
        XCTAssertEqual(OutputSelectionMode.effective(stored: .followSystem, flagEnabled: false), .fixed)
        XCTAssertEqual(OutputSelectionMode.effective(stored: .followSystem, flagEnabled: true), .followSystem)
        XCTAssertEqual(OutputSelectionMode.effective(stored: .fixed, flagEnabled: true), .fixed)
    }

    func testModePersistsAndDefaultsToFixed() {
        let suite = "OutputFollowPolicyTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(OutputSelectionMode.stored(in: defaults), .fixed)
        OutputSelectionMode.store(.followSystem, in: defaults)
        XCTAssertEqual(OutputSelectionMode.stored(in: defaults), .followSystem)
    }

    func testFlagIsRegisteredAndOffByDefault() {
        XCTAssertTrue(FeatureFlag.all.contains(.followOutput))
        XCTAssertEqual(FeatureFlag.followOutput.id, "e15.follow-output")
        XCTAssertFalse(FeatureFlag.followOutput.resolvedDefault)
    }
}
