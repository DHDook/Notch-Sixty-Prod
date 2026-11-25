import XCTest
@testable import NotchSixty

/// E15 S3: the follow transaction through the production coordinator and driver with fake hardware events, a fake
/// engine that records its call order, the real arm switch and the real Playback System store.
@MainActor
final class OutputFollowCoordinatorTests: XCTestCase {
    private final class Log { var lines: [String] = [] }

    private final class FakeSource: FollowOutputEventSource {
        var onDefaultOutputChanged: ((OutputFollowTarget?) -> Void)?
        var onDataSourceChanged: ((OutputFollowTarget) -> Void)?
        var onDeviceListChanged: (() -> Void)?
        var onWillSleep: (() -> Void)?
        var onDidWake: (() -> Void)?
        var defaultTarget: OutputFollowTarget?
        var startCount = 0
        func start() throws { startCount += 1 }
        func stop() {}
        func monitorDataSource(ofDeviceUID uid: String?) {}
        func currentDefaultTarget() -> OutputFollowTarget? { defaultTarget }
        func dataSourceID(forDeviceUID uid: String) -> UInt32? { nil }
        func availableOutputUIDs() -> Set<String> { ["a", "b", "c"] }
        func ownDeviceUIDs() -> Set<String> { [] }
    }

    @MainActor private final class FakeEngine: OutputFollowSwitching {
        var selectedOutputUID: String? = "a"
        var isFailed = false
        var rates: [String: Double] = [:]
        var runningRate: Double?
        var failApply = false
        let log: Log
        init(log: Log) { self.log = log }
        func start() throws { log.lines.append("start-only") }
        func switchFollowedOutput(to uid: String, resume: Bool, prepare: () throws -> Void) throws {
            log.lines.append("stop")
            selectedOutputUID = uid
            runningRate = nil
            log.lines.append("select \(uid)")
            try prepare()
            if resume {
                runningRate = rates[uid]
                log.lines.append("start \(uid) @\(Int(rates[uid] ?? 0))")
            }
        }
    }

    @MainActor private final class FakeProfiles: OutputFollowProfiles {
        var outputBindings = OutputProfileBindings()
        var systemProfileIDs: Set<UUID> = []
        var systemProfileIDsNeedingMapping: Set<UUID> = []
        var names: [UUID: String] = [:]
        var failing: Set<UUID> = []
        var applied: [UUID] = []
        let log: Log
        init(log: Log) { self.log = log }
        func systemProfileName(for id: UUID) -> String? { names[id] }
        func applyBoundSystem(_ id: UUID) throws {
            log.lines.append("apply \(names[id] ?? "?")")
            if failing.contains(id) { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "5.1 on stereo"]) }
            applied.append(id)
        }
        func seedOutputBindingsFromAssociations() -> [String] { log.lines.append("seed"); return ["dup"] }
        func useSelectedSystem(for key: OutputKey) { outputBindings.bind(key, to: systemProfileIDs.first!) }
        func unbindOutput(_ key: OutputKey) { outputBindings.unbind(key) }
        var systemProfileChoices: [OutputFollowSystemChoice] { names.map { OutputFollowSystemChoice(id: $0.key, name: $0.value) } }
        func useSystem(_ id: UUID, for key: OutputKey) { outputBindings.bind(key, to: id) }
    }

    @MainActor private final class FakeDisarmer: OutputFollowTreatmentDisarming {
        let quietZone: LiveTreatmentArm
        var feedForwardOn = false
        var mimoArmed = false
        let log: Log
        init(arm: LiveTreatmentArm, log: Log) { quietZone = arm; self.log = log }
        func disarmAllForOutputFollow() -> [String] {
            var names: [String] = []
            if quietZone.isArmed { names.append("Quiet Zone"); quietZone.disarm(.outputFollowed) }
            if feedForwardOn { names.append("Feed-forward"); feedForwardOn = false }
            if mimoArmed { names.append("Room Treatment"); mimoArmed = false }
            log.lines.append("disarm \(names.joined(separator: "+"))")
            return names
        }
    }

    private final class Clock: FollowScheduling, @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 9_000)
        private var tasks: [(due: Date, block: @MainActor () -> Void, live: Flag)] = []
        final class Flag { var on = true }
        func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> FollowTimerToken {
            let flag = Flag()
            tasks.append((now.addingTimeInterval(delay), block, flag))
            return FollowTimerToken { flag.on = false }
        }
        @MainActor func advance(_ seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = tasks.filter({ $0.live.on && $0.due <= target }).min(by: { $0.due < $1.due }) {
                now = max(now, next.due)
                next.live.on = false
                next.block()
            }
            now = target
        }
    }

    private struct Rig {
        let coordinator: OutputFollowCoordinator
        let source: FakeSource
        let engine: FakeEngine
        let profiles: FakeProfiles
        let disarmer: FakeDisarmer
        let arm: LiveTreatmentArm
        let clock: Clock
        let log: Log
        let defaults: UserDefaults
        let idB = UUID()
        let idC = UUID()
    }

    private var suites: [String] = []

    private func rig(flag: Bool = true, blocks: @escaping () -> Set<OutputFollowBlock> = { [] }) -> Rig {
        let log = Log()
        let suite = "e15.s3.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let source = FakeSource()
        let engine = FakeEngine(log: log)
        let profiles = FakeProfiles(log: log)
        let arm = LiveTreatmentArm(feature: .quietZone)
        let disarmer = FakeDisarmer(arm: arm, log: log)
        let clock = Clock()
        let coordinator = OutputFollowCoordinator(
            engine: engine, profiles: profiles, treatments: disarmer, source: source, scheduler: clock,
            policy: OutputFollowPolicy(now: { clock.now }), defaults: defaults, flagEnabled: { flag },
            externalBlocks: blocks, displayName: { "Device \($0)" })
        let rig = Rig(
            coordinator: coordinator, source: source, engine: engine, profiles: profiles, disarmer: disarmer,
            arm: arm, clock: clock, log: log, defaults: defaults)
        profiles.systemProfileIDs = [rig.idB, rig.idC]
        profiles.names = [rig.idB: "Desk", rig.idC: "Headphones"]
        profiles.outputBindings.bind(OutputKey(deviceUID: "b"), to: rig.idB)
        profiles.outputBindings.bind(OutputKey(deviceUID: "c"), to: rig.idC)
        return rig
    }

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private func armQuietZone(_ arm: LiveTreatmentArm) throws {
        try arm.arm(environment: LiveTreatmentEnvironment(
            outputDeviceUID: "a", sampleRate: 48_000, engineRunning: true, inputAvailable: true))
    }

    private func change(_ rig: Rig, to uid: String) {
        rig.source.onDefaultOutputChanged?(OutputFollowTarget(key: OutputKey(deviceUID: uid), displayName: "Device \(uid)"))
        rig.clock.advance(1)
    }

    func testFlagOffForcesFixedAndNeverInstallsTheListener() {
        let r = rig(flag: false)
        r.coordinator.setFollowing(true)
        r.coordinator.reconcile()
        XCTAssertEqual(r.coordinator.effectiveMode, .fixed)
        XCTAssertEqual(r.source.startCount, 0)
        change(r, to: "b")
        XCTAssertTrue(r.log.lines.isEmpty)
    }

    func testEnablingSeedsBindingsAndListsAmbiguousUIDs() {
        let r = rig()
        r.coordinator.setFollowing(true)
        XCTAssertEqual(r.log.lines, ["seed"])
        XCTAssertEqual(r.coordinator.ambiguousUIDs, ["dup"])
        XCTAssertEqual(r.source.startCount, 1)
        XCTAssertEqual(OutputSelectionMode.stored(in: r.defaults), .followSystem)
        r.coordinator.setFollowing(false)
        XCTAssertFalse(r.coordinator.isFollowing)
    }

    func testEnablingFollowsTheCurrentDefaultAtOnce() {
        let r = rig()
        r.source.defaultTarget = OutputFollowTarget(key: OutputKey(deviceUID: "b"), displayName: "Device b")
        r.coordinator.setFollowing(true)
        XCTAssertEqual(r.engine.selectedOutputUID, "b")
    }

    func testArmedTreatmentsDisarmBeforeTeardownAndStayDisarmed() throws {
        let r = rig()
        r.engine.rates = ["b": 96_000]
        r.coordinator.setFollowing(true)
        r.log.lines.removeAll()
        try armQuietZone(r.arm)
        r.disarmer.feedForwardOn = true
        r.disarmer.mimoArmed = true
        change(r, to: "b")
        XCTAssertEqual(r.log.lines, ["disarm Quiet Zone+Feed-forward+Room Treatment", "stop", "select b", "apply Desk", "start b @96000"])
        XCTAssertFalse(r.arm.isArmed, "nothing re-arms after the switch")
        XCTAssertEqual(r.arm.lastDisarmReason, .outputFollowed)
        let note = r.coordinator.announcement
        XCTAssertEqual(note?.title, "Now on Device b with Desk")
        XCTAssertEqual(note?.disarmLine, "Quiet Zone and Feed-forward and Room Treatment disarmed: output changed")
    }

    func testBoundProfileAppliesOnEachOfTheEightRates() {
        let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        let r = rig()
        r.coordinator.setFollowing(true)
        var current = "a"
        for (index, rate) in rates.enumerated() {
            let uid = index.isMultiple(of: 2) ? "b" : "c"
            if uid == current { r.engine.selectedOutputUID = "a" }
            r.engine.rates[uid] = rate
            r.log.lines.removeAll()
            change(r, to: uid)
            current = uid
            XCTAssertEqual(r.engine.runningRate, rate, "the new device's own rate at \(rate)")
            XCTAssertEqual(r.log.lines.last, "start \(uid) @\(Int(rate))")
            XCTAssertTrue(r.log.lines.contains("apply \(uid == "b" ? "Desk" : "Headphones")"))
        }
    }

    func testUnboundOutputPausesWithoutApplyingAnyProfile() {
        let r = rig()
        r.coordinator.setFollowing(true)
        r.log.lines.removeAll()
        change(r, to: "unbound")
        XCTAssertEqual(r.log.lines, ["disarm ", "stop", "select unbound"])
        XCTAssertTrue(r.profiles.applied.isEmpty)
        XCTAssertNil(r.engine.runningRate)
        XCTAssertEqual(r.engine.selectedOutputUID, "unbound", "the UI stays truthful")
        let note = r.coordinator.announcement
        XCTAssertEqual(note?.title, "No Playback System for Device unbound")
        XCTAssertEqual(note?.isPause, true)
        XCTAssertEqual(r.coordinator.pausedKey?.key.deviceUID, "unbound")
    }

    func testNeedsMappingProfilePausesAndIsNeverApplied() {
        let r = rig()
        r.profiles.systemProfileIDsNeedingMapping = [r.idB]
        r.coordinator.setFollowing(true)
        change(r, to: "b")
        XCTAssertTrue(r.profiles.applied.isEmpty)
        XCTAssertEqual(r.coordinator.announcement?.kind, .paused(.needsMapping(r.idB)))
        XCTAssertNil(r.engine.runningRate)
    }

    func testFailingProfilePausesAndDoesNotStart() {
        let r = rig()
        r.profiles.failing = [r.idB]
        r.engine.rates = ["b": 48_000]
        r.coordinator.setFollowing(true)
        r.log.lines.removeAll()
        change(r, to: "b")
        XCTAssertEqual(r.log.lines, ["disarm ", "stop", "select b", "apply Desk"])
        XCTAssertNil(r.engine.runningRate)
        XCTAssertEqual(r.coordinator.announcement?.kind, .paused(.applyFailed(r.idB, message: "5.1 on stereo")))
        XCTAssertEqual(r.coordinator.announcement?.isPause, true)
    }

    func testUseCurrentForThisDeviceBindsAndClearsThePause() {
        let r = rig()
        r.coordinator.setFollowing(true)
        change(r, to: "unbound")
        r.coordinator.useSelectedSystemForCurrentOutput()
        XCTAssertNotNil(r.profiles.outputBindings.profileID(for: OutputKey(deviceUID: "unbound")))
        XCTAssertNil(r.coordinator.announcement)
        r.coordinator.removeBindingForCurrentOutput()
    }

    func testBlockedStateHoldsTheSwitchUntilItEnds() {
        var blocked = true
        let r = rig(blocks: { blocked ? [.safeLaunch] : [] })
        r.coordinator.setFollowing(true)
        r.log.lines.removeAll()
        change(r, to: "b")
        XCTAssertTrue(r.log.lines.isEmpty)
        blocked = false
        r.coordinator.exclusionEnded()
        XCTAssertEqual(r.engine.selectedOutputUID, "b")
    }

    func testFailedEngineBlocksUntilItLeavesFailed() {
        let r = rig()
        r.engine.isFailed = true
        r.coordinator.setFollowing(true)
        change(r, to: "b")
        XCTAssertEqual(r.engine.selectedOutputUID, "a")
        r.engine.isFailed = false
        r.coordinator.exclusionEnded()
        XCTAssertEqual(r.engine.selectedOutputUID, "b")
    }

    func testManualSystemPickWhileFollowingDoesNotChangeTheOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("p.json"))
        let id = profiles.saveCurrentSystemProfile(named: "Desk")
        profiles.useSelectedSystem(for: OutputKey(deviceUID: "elsewhere"))
        let before = engine.routeConfiguration.selectedOutputUID
        profiles.ignoresAssociatedOutput = { true }
        profiles.selectSystemProfile(id)
        XCTAssertNil(profiles.lastErrorDescription)
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, before)
        try profiles.applyBoundSystem(id)
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, before, "a bound apply never moves the output")
    }

    func testApplyBoundSystemRefusesMissingProfile() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ProductProfileController(engine: AudioIOEngine(), storageURL: root.appendingPathComponent("p.json"))
        XCTAssertThrowsError(try profiles.applyBoundSystem(UUID()))
    }

    func testPolicyCopyIsQualified() {
        XCTAssertTrue(OutputFollowCopy.recoveryPolicy(following: false).contains("Unless Follow macOS output is on"))
        XCTAssertTrue(OutputFollowCopy.recoveryPolicy(following: true).contains("never changes the macOS default"))
    }

    func testAnnouncementTextCoversEachCase() {
        let note = OutputFollowAnnouncement(device: "DAC", kind: .paused(.noBinding), disarmed: ["Quiet Zone"])
        XCTAssertEqual(note.title, "No Playback System for DAC")
        XCTAssertTrue(note.detail?.contains("Quiet Zone disarmed: output changed") == true)
        XCTAssertEqual(OutputFollowAnnouncement(device: "DAC", kind: .failed("x"), disarmed: []).title, "Could not move to DAC")
    }

    // MARK: E15 S4 ship scenarios (flag graduation): the coordinator, driver and real arm switch with fake hardware

    func testUnplugAndReplugFollowsToBuiltInAndBackWithEachBoundSystem() {
        let r = rig()
        r.engine.rates = ["b": 96_000, "c": 48_000]
        r.coordinator.setFollowing(true)
        r.log.lines.removeAll()
        change(r, to: "b")
        change(r, to: "c")
        change(r, to: "b")
        XCTAssertEqual(r.log.lines.filter { $0.hasPrefix("apply") }, ["apply Desk", "apply Headphones", "apply Desk"])
        XCTAssertEqual(r.engine.selectedOutputUID, "b")
        XCTAssertEqual(r.engine.runningRate, 96_000)
    }

    func testSleepAndWakeWithThePreSleepDevicePresentStillFollowsTheDefault() {
        let r = rig()
        r.engine.rates = ["b": 48_000]
        r.coordinator.setFollowing(true)
        r.source.onWillSleep?()
        r.source.onDidWake?()
        r.source.onDefaultOutputChanged?(OutputFollowTarget(key: OutputKey(deviceUID: "b"), displayName: "Device b"))
        r.clock.advance(1)
        XCTAssertEqual(r.engine.selectedOutputUID, "b", "the pre-sleep output is present, so no wake hold applies")
        XCTAssertEqual(r.profiles.applied, [r.idB])
    }

    func testHardwareAcceptanceRunHoldsTheSwitchUntilItEnds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let acceptance = HardwareAcceptanceController(store: HardwareAcceptanceCampaignStore(rootDirectory: root))
        XCTAssertFalse(acceptance.isRunInProgress, "no campaign, no run")
        let r = rig(blocks: { acceptance.isRunInProgress ? [.hardwareAcceptance] : [] })
        r.coordinator.setFollowing(true)
        acceptance.setPageOpen(true)
        XCTAssertFalse(acceptance.isRunInProgress, "the page open without a campaign is not a run")
        try acceptance.createCampaign(
            identity: HardwareAcceptanceCampaignIdentity(
                commitSHA: "f8ef81a80d1aac262ec21da23abef5ed29825506", branch: "main", appVersion: "1.0",
                appBuild: "1", playbackSystemID: UUID()),
            scopeDecisions: [
                .protectedSplitDriverMeasurement: .excluded(reason: "No split-driver topology in this campaign."),
                .coherentIndependentSubAlignment: .excluded(reason: "No independently addressable Sub route."),
                .liveFeedForwardANC: .excluded(reason: "Live feed-forward ANC is disabled in this scope."),
            ])
        XCTAssertTrue(acceptance.isRunInProgress)
        r.log.lines.removeAll()
        change(r, to: "b")
        XCTAssertTrue(r.log.lines.isEmpty, "the run holds the switch")
        acceptance.setPageOpen(false)
        r.coordinator.exclusionEnded()
        XCTAssertEqual(r.engine.selectedOutputUID, "b")
    }

    func testModeToggledWhileRunningStopsFollowingAndKeepsTheOutput() {
        let r = rig()
        r.engine.rates = ["b": 96_000]
        r.coordinator.setFollowing(true)
        change(r, to: "b")
        r.coordinator.setFollowing(false)
        r.log.lines.removeAll()
        change(r, to: "c")
        XCTAssertTrue(r.log.lines.isEmpty, "fixed mode never follows a later default change")
        XCTAssertEqual(r.engine.selectedOutputUID, "b")
        r.coordinator.setFollowing(true)
        XCTAssertTrue(r.coordinator.isFollowing)
    }

    func testChoosingASystemOnThePauseSheetBindsAppliesAndStartsProcessing() {
        let r = rig()
        r.coordinator.setFollowing(true)
        change(r, to: "unbound")
        XCTAssertEqual(Set(r.coordinator.systemChoices.map(\.name)), ["Desk", "Headphones"])
        r.log.lines.removeAll()
        r.coordinator.chooseSystemForCurrentOutput(r.idC)
        XCTAssertEqual(r.profiles.outputBindings.profileID(for: OutputKey(deviceUID: "unbound")), r.idC)
        XCTAssertEqual(r.log.lines, ["apply Headphones", "start-only"])
        XCTAssertNil(r.coordinator.announcement)
    }

    func testUseCurrentForThisDeviceStartsProcessingAfterAPause() {
        let r = rig()
        r.coordinator.setFollowing(true)
        change(r, to: "unbound")
        r.log.lines.removeAll()
        r.coordinator.useSelectedSystemForCurrentOutput()
        XCTAssertEqual(r.log.lines, ["start-only"])
    }

    func testUseForDeviceWithoutAPauseDoesNotStartAnything() {
        let r = rig()
        r.coordinator.setFollowing(true)
        r.log.lines.removeAll()
        r.coordinator.useSelectedSystemForCurrentOutput()
        XCTAssertTrue(r.log.lines.isEmpty)
    }
}
